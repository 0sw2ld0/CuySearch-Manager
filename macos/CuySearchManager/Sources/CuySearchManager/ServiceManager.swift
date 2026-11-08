import AppKit
import Foundation
import OSLog
import ServiceManagement

enum BackendStatus: Equatable {
    case stopped
    case starting
    case runningManaged
    case runningExternal
    case failed(String)

    var isRunning: Bool { self == .runningManaged || self == .runningExternal }

    var label: String {
        switch self {
        case .stopped: "Detenido"
        case .starting: "Iniciando…"
        case .runningManaged: "Activo"
        case .runningExternal: "Activo (externo)"
        case .failed(let message): "Error: \(message)"
        }
    }
}

enum SearXNGStatus: Equatable {
    case unknown
    case checking
    case available
    case unavailable
    case starting
    case failed(String)

    var label: String {
        switch self {
        case .unknown: "Sin comprobar"
        case .checking: "Comprobando…"
        case .available: "Disponible"
        case .unavailable: "No disponible"
        case .starting: "Iniciando…"
        case .failed(let message): "Error: \(message)"
        }
    }
}

@MainActor
final class ServiceManager: ObservableObject {
    @Published private(set) var backendStatus: BackendStatus = .stopped
    @Published private(set) var searxngStatus: SearXNGStatus = .unknown
    @Published private(set) var logs: [String] = []

    @Published var projectPath: String {
        didSet { defaults.set(projectPath, forKey: Keys.projectPath) }
    }
    @Published var port: Int {
        didSet { defaults.set(port, forKey: Keys.port) }
    }
    @Published var searxngURL: String {
        didSet { defaults.set(searxngURL, forKey: Keys.searxngURL) }
    }
    @Published var apiKey: String
    @Published var autoStart: Bool {
        didSet { defaults.set(autoStart, forKey: Keys.autoStart) }
    }
    @Published var useBundledSearXNG: Bool {
        didSet { defaults.set(useBundledSearXNG, forKey: Keys.useBundledSearXNG) }
    }
    @Published private(set) var launchAtLogin: Bool

    private let defaults = UserDefaults.standard
    private let systemLogger = Logger(
        subsystem: "com.cuycoders.CuySearchManager",
        category: "services"
    )
    private var backendProcess: Process?
    private var searxngProcess: Process?
    private var monitoringTask: Task<Void, Never>?
    private var terminationObserver: NSObjectProtocol?
    private var hasActivated = false

    private enum Keys {
        static let projectPath = "projectPath"
        static let port = "port"
        static let searxngURL = "searxngURL"
        static let autoStart = "autoStart"
        static let useBundledSearXNG = "useBundledSearXNG"
        static let searxngSecret = "searxngSecret"
    }

    init() {
        let inferredRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .path
        let resolvedProjectPath = defaults.string(forKey: Keys.projectPath) ?? inferredRoot
        let resolvedBundledSetting = defaults.object(forKey: Keys.useBundledSearXNG) as? Bool ?? true

        projectPath = resolvedProjectPath
        port = defaults.object(forKey: Keys.port) as? Int ?? 8090
        searxngURL = defaults.string(forKey: Keys.searxngURL)
            ?? (resolvedBundledSetting
                ? "http://127.0.0.1:8888"
                : Self.dotEnvValue("SEARXNG_BASE_URL", projectPath: resolvedProjectPath)
                    ?? "http://127.0.0.1:8888")
        apiKey = Self.dotEnvValue("CUYSEARCH_API_KEY", projectPath: resolvedProjectPath) ?? ""
        autoStart = defaults.object(forKey: Keys.autoStart) as? Bool ?? true
        useBundledSearXNG = resolvedBundledSetting
        launchAtLogin = SMAppService.mainApp.status == .enabled

        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.terminateManagedProcesses() }
        }

        Task { [weak self] in await self?.activate() }
    }

    deinit {
        monitoringTask?.cancel()
        if let terminationObserver {
            NotificationCenter.default.removeObserver(terminationObserver)
        }
    }

    var serviceURL: String { "http://127.0.0.1:\(port)" }
    var healthURL: String { "\(serviceURL)/healthz" }
    var ownsBackendProcess: Bool { backendProcess?.isRunning == true }
    var ownsSearXNGProcess: Bool { searxngProcess?.isRunning == true }
    var hasEmbeddedRuntime: Bool { embeddedPythonURL != nil }

    func activate() async {
        guard !hasActivated else { return }
        hasActivated = true
        appendLog("CuySearch Manager iniciado")
        appendLog(hasEmbeddedRuntime ? "Runtime autónomo disponible" : "Usando entorno de desarrollo")
        await refreshStatus()
        startMonitoring()

        if autoStart {
            if useBundledSearXNG && searxngStatus != .available { startSearXNG() }
            if !backendStatus.isRunning { startBackend() }
        }
    }

    func startAll() {
        if useBundledSearXNG && searxngStatus != .available { startSearXNG() }
        if !backendStatus.isRunning { startBackend() }
    }

    func stopAll() {
        stopBackend()
        stopSearXNG()
    }

    func startBackend() {
        guard !backendStatus.isRunning, backendProcess?.isRunning != true else { return }
        guard let pythonURL = runtimePythonURL else {
            backendStatus = .failed("No se encontró el runtime Python")
            appendLog("No existe el runtime incluido ni .venv/bin/python")
            return
        }

        let process = Process()
        let outputPipe = Pipe()
        process.executableURL = pythonURL
        process.arguments = ["-m", "cuysearch.servicio"]
        process.currentDirectoryURL = applicationSupportURL

        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONUNBUFFERED"] = "1"
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        environment["CUYSEARCH_HOST"] = "127.0.0.1"
        environment["CUYSEARCH_PORT"] = String(port)
        environment["SEARXNG_BASE_URL"] = searxngURL
        if apiKey.isEmpty {
            environment.removeValue(forKey: "CUYSEARCH_API_KEY")
        } else {
            environment["CUYSEARCH_API_KEY"] = apiKey
        }
        process.environment = environment
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor [weak self] in self?.appendOutput(text, prefix: "CuySearch") }
        }
        process.terminationHandler = { [weak self] terminated in
            outputPipe.fileHandleForReading.readabilityHandler = nil
            Task { @MainActor [weak self] in
                self?.appendLog("CuySearch terminó (código \(terminated.terminationStatus))")
                self?.backendProcess = nil
                await self?.refreshBackendStatus()
            }
        }

        do {
            try FileManager.default.createDirectory(
                at: applicationSupportURL,
                withIntermediateDirectories: true
            )
            backendStatus = .starting
            try process.run()
            backendProcess = process
            appendLog("Iniciando CuySearch en \(serviceURL)")
        } catch {
            backendStatus = .failed(error.localizedDescription)
            appendLog("No se pudo iniciar CuySearch: \(error.localizedDescription)")
        }
    }

    func stopBackend() {
        guard let process = backendProcess, process.isRunning else {
            if backendStatus.isRunning {
                appendLog("CuySearch es externo; la app no lo detendrá")
            }
            return
        }
        appendLog("Deteniendo CuySearch…")
        process.interrupt()
    }

    func startSearXNG() {
        guard useBundledSearXNG else {
            appendLog("SearXNG integrado está desactivado en Ajustes")
            return
        }
        guard searxngStatus != .available, searxngProcess?.isRunning != true else { return }
        guard let pythonURL = embeddedPythonURL,
              let settingsURL = Bundle.main.url(forResource: "searxng-settings", withExtension: "yml") else {
            searxngStatus = .failed("Runtime integrado incompleto")
            appendLog("La app no contiene el runtime nativo de SearXNG")
            return
        }
        guard let configuredURL = URL(string: searxngURL),
              ["localhost", "127.0.0.1"].contains(configuredURL.host?.lowercased() ?? "") else {
            searxngStatus = .failed("La URL integrada debe apuntar a localhost")
            return
        }

        let process = Process()
        let outputPipe = Pipe()
        let searxPort = configuredURL.port ?? 8888
        process.executableURL = pythonURL
        process.arguments = ["-m", "searx.webapp"]
        process.currentDirectoryURL = applicationSupportURL

        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONUNBUFFERED"] = "1"
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        environment["SEARXNG_SETTINGS_PATH"] = settingsURL.path
        environment["SEARXNG_SECRET"] = searxngSecret()
        environment["SEARXNG_BASE_URL"] = "http://127.0.0.1:\(searxPort)/"
        environment["SEARXNG_PORT"] = String(searxPort)
        environment["SEARXNG_BIND_ADDRESS"] = "127.0.0.1"
        environment["XDG_CACHE_HOME"] = cacheURL.path
        process.environment = environment
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor [weak self] in self?.appendOutput(text, prefix: "SearXNG") }
        }
        process.terminationHandler = { [weak self] terminated in
            outputPipe.fileHandleForReading.readabilityHandler = nil
            Task { @MainActor [weak self] in
                self?.appendLog("SearXNG terminó (código \(terminated.terminationStatus))")
                self?.searxngProcess = nil
                await self?.refreshSearXNGStatus()
            }
        }

        do {
            try FileManager.default.createDirectory(
                at: applicationSupportURL,
                withIntermediateDirectories: true
            )
            try FileManager.default.createDirectory(at: cacheURL, withIntermediateDirectories: true)
            searxngStatus = .starting
            try process.run()
            searxngProcess = process
            appendLog("Iniciando SearXNG nativo en \(searxngURL)")
        } catch {
            searxngStatus = .failed(error.localizedDescription)
            appendLog("No se pudo iniciar SearXNG: \(error.localizedDescription)")
        }
    }

    func stopSearXNG() {
        guard let process = searxngProcess, process.isRunning else {
            if searxngStatus == .available {
                appendLog("SearXNG es externo; la app no lo detendrá")
            }
            return
        }
        appendLog("Deteniendo SearXNG…")
        process.interrupt()
    }

    func refreshStatus() async {
        async let backend: Void = refreshBackendStatus()
        async let searxng: Void = refreshSearXNGStatus()
        _ = await (backend, searxng)
    }

    func refreshBackendStatus() async {
        if await urlResponds(healthURL) {
            backendStatus = ownsBackendProcess ? .runningManaged : .runningExternal
        } else if backendProcess?.isRunning == true {
            backendStatus = .starting
        } else if case .failed = backendStatus {
            return
        } else {
            backendStatus = .stopped
        }
    }

    func refreshSearXNGStatus() async {
        if await urlResponds(searxngURL) {
            searxngStatus = .available
        } else if searxngProcess?.isRunning == true {
            searxngStatus = .starting
        } else if case .failed = searxngStatus {
            return
        } else {
            searxngStatus = .unavailable
        }
    }

    func chooseProjectFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: projectPath)
        if panel.runModal() == .OK, let selected = panel.url { projectPath = selected.path }
    }

    func copyServiceURL() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(serviceURL, forType: .string)
        appendLog("URL copiada: \(serviceURL)")
    }

    func openHealthPage() {
        guard let url = URL(string: healthURL) else { return }
        NSWorkspace.shared.open(url)
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            launchAtLogin = SMAppService.mainApp.status == .enabled
        } catch {
            launchAtLogin = SMAppService.mainApp.status == .enabled
            appendLog("No se pudo cambiar el inicio de sesión: \(error.localizedDescription)")
        }
    }

    func quit() {
        terminateManagedProcesses()
        NSApplication.shared.terminate(nil)
    }

    private var applicationSupportURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CuySearchManager", isDirectory: true)
    }

    private var cacheURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CuySearchManager", isDirectory: true)
    }

    private var embeddedPythonURL: URL? {
        guard let candidate = Bundle.main.resourceURL?.appendingPathComponent("runtime/bin/python3"),
              FileManager.default.isExecutableFile(atPath: candidate.path) else { return nil }
        return candidate
    }

    private var runtimePythonURL: URL? {
        if let embeddedPythonURL { return embeddedPythonURL }
        let fallback = URL(fileURLWithPath: projectPath).appendingPathComponent(".venv/bin/python")
        return FileManager.default.isExecutableFile(atPath: fallback.path) ? fallback : nil
    }

    private func startMonitoring() {
        monitoringTask?.cancel()
        monitoringTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled else { return }
                await self?.refreshStatus()
            }
        }
    }

    private func terminateManagedProcesses() {
        if backendProcess?.isRunning == true { backendProcess?.interrupt() }
        if searxngProcess?.isRunning == true { searxngProcess?.interrupt() }
    }

    private func appendOutput(_ output: String, prefix: String) {
        output.split(whereSeparator: \.isNewline).forEach {
            appendLog("\(prefix): \($0)")
        }
    }

    private func appendLog(_ message: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        logs.append("[\(formatter.string(from: Date()))] \(message)")
        systemLogger.info("\(message, privacy: .public)")
        if logs.count > 150 { logs.removeFirst(logs.count - 150) }
    }

    private func urlResponds(_ rawURL: String) async -> Bool {
        guard let url = URL(string: rawURL) else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 1.5
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return false }
            return (200..<500).contains(http.statusCode)
        } catch {
            return false
        }
    }

    private func searxngSecret() -> String {
        if let existing = defaults.string(forKey: Keys.searxngSecret), !existing.isEmpty {
            return existing
        }
        let secret = UUID().uuidString.replacingOccurrences(of: "-", with: "")
            + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        defaults.set(secret, forKey: Keys.searxngSecret)
        return secret
    }

    private static func dotEnvValue(_ key: String, projectPath: String) -> String? {
        let fileURL = URL(fileURLWithPath: projectPath).appendingPathComponent(".env")
        guard let contents = try? String(contentsOf: fileURL, encoding: .utf8) else { return nil }
        let prefix = "\(key)="
        for rawLine in contents.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix(prefix) else { continue }
            var value = String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            if value.count >= 2,
               (value.hasPrefix("\"") && value.hasSuffix("\""))
                || (value.hasPrefix("'") && value.hasSuffix("'")) {
                value.removeFirst()
                value.removeLast()
            }
            return value
        }
        return nil
    }
}
