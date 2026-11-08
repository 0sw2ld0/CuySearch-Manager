import AppKit
import SwiftUI

struct MenuPanel: View {
    @ObservedObject var model: ServiceManager

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 34, height: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text("CuySearch")
                        .font(.headline)
                    Text("Servicio local para tus agentes")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            statusCard
            searxngCard
            logsView

            HStack {
                Button {
                    NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                } label: {
                    Label("Ajustes", systemImage: "gearshape")
                }
                .buttonStyle(.plain)
                Spacer()
                Button("Salir") { model.quit() }
                    .buttonStyle(.plain)
            }
            .font(.caption)
        }
        .padding(16)
        .frame(width: 390)
    }

    private var statusCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 9, height: 9)
                    Text(model.backendStatus.label)
                        .lineLimit(1)
                    Spacer()
                    Text(model.serviceURL)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }

                HStack {
                    if model.backendStatus.isRunning {
                        Button("Detener") { model.stopBackend() }
                            .disabled(!model.ownsBackendProcess)
                    } else {
                        Button("Iniciar") { model.startBackend() }
                            .buttonStyle(.borderedProminent)
                    }
                    Button("Copiar URL") { model.copyServiceURL() }
                    Button("Comprobar") { model.openHealthPage() }
                }
                .controlSize(.small)
            }
        } label: {
            Label("API CuySearch", systemImage: "bolt.horizontal.circle")
        }
    }

    private var searxngCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Circle()
                        .fill(model.searxngStatus == .available ? Color.green : Color.gray)
                        .frame(width: 9, height: 9)
                    Text(model.searxngStatus.label)
                        .lineLimit(2)
                    Spacer()
                }
                Text(model.searxngURL)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)

                if model.useBundledSearXNG {
                    HStack {
                        Button("Iniciar nativo") { model.startSearXNG() }
                        Button("Detener SearXNG") { model.stopSearXNG() }
                    }
                    .controlSize(.small)
                } else {
                    Text("SearXNG integrado desactivado; se usará la URL configurada.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } label: {
            Label("Proveedor SearXNG", systemImage: "network")
        }
    }

    private var logsView: some View {
        GroupBox("Actividad") {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(model.logs.enumerated()), id: \.offset) { index, line in
                            Text(line)
                                .font(.system(size: 10, design: .monospaced))
                                .textSelection(.enabled)
                                .id(index)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 105)
                .onChange(of: model.logs.count) { newCount in
                    if newCount > 0 { proxy.scrollTo(newCount - 1, anchor: .bottom) }
                }
            }
        }
    }

    private var statusColor: Color {
        switch model.backendStatus {
        case .runningManaged, .runningExternal: .green
        case .starting: .orange
        case .failed: .red
        case .stopped: .gray
        }
    }
}

struct SettingsView: View {
    @ObservedObject var model: ServiceManager

    var body: some View {
        Form {
            Section("CuySearch") {
                HStack {
                    TextField("Carpeta del proyecto", text: $model.projectPath)
                    Button("Elegir…") { model.chooseProjectFolder() }
                }
                TextField("Puerto", value: $model.port, format: .number.grouping(.never))
                    .frame(width: 110)
                SecureField("API key opcional (se carga desde .env)", text: $model.apiKey)
                Toggle("Iniciar CuySearch al abrir la app", isOn: $model.autoStart)
                Toggle(
                    "Abrir CuySearch Manager al iniciar sesión",
                    isOn: Binding(
                        get: { model.launchAtLogin },
                        set: { model.setLaunchAtLogin($0) }
                    )
                )
            }

            Section("Búsqueda web") {
                TextField("URL de SearXNG", text: $model.searxngURL)
                Toggle("Usar SearXNG integrado", isOn: $model.useBundledSearXNG)
                Text("Funciona como proceso nativo, sin Docker, Colima ni Valkey. Desactívalo si usas un SearXNG remoto.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Si SearXNG no responde, CuySearch busca en DuckDuckGo, Bing, Brave, Mojeek y Wikipedia desde tu conexión.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(width: 540, height: 410)
    }
}
