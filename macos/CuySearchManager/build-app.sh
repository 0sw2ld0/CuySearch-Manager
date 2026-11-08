#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_ROOT="${SCRIPT_DIR:h:h}"
APP_DIR="$PROJECT_ROOT/dist/CuySearch Manager.app"
BUILD_CACHE="$PROJECT_ROOT/.build-cache"
UV_CACHE="$BUILD_CACHE/uv"

PYTHON_VERSION="3.13.5"
PYTHON_INSTALL_DIR="$BUILD_CACHE/embedded-python-bundle"
PYTHON_ROOT="$PYTHON_INSTALL_DIR/cpython-3.13.5-macos-aarch64-none"
PYTHON_BIN="$PYTHON_ROOT/bin/python3"
SITE_PACKAGES="$PYTHON_ROOT/lib/python3.13/site-packages"

SEARXNG_COMMIT="23e7e4da008fdc9ac5b27b2625faa9144d46f208"

# Librería y servicio CuySearch. Para probar una copia local:
#   CUYSEARCH_SPEC="cuysearch[servicio] @ file:///ruta/a/CuySearch" ./build-app.sh
CUYSEARCH_SPEC="${CUYSEARCH_SPEC:-cuysearch[servicio] @ git+https://github.com/0sw2ld0/CuySearch@v0.1.0}"
SEARXNG_SOURCE="$BUILD_CACHE/searxng-$SEARXNG_COMMIT"
RUNTIME_MARKER="$PYTHON_ROOT/.cuysearch-searxng-$SEARXNG_COMMIT"

export CLANG_MODULE_CACHE_PATH="$BUILD_CACHE/clang"
export SWIFTPM_MODULECACHE_OVERRIDE="$BUILD_CACHE/swiftpm-modules"
mkdir -p \
    "$BUILD_CACHE/clang" \
    "$BUILD_CACHE/swiftpm" \
    "$BUILD_CACHE/swiftpm-modules" \
    "$UV_CACHE"

if [[ ! -f "$SCRIPT_DIR/Assets/AppIcon.icns" ]] || \
   [[ "$SCRIPT_DIR/Assets/AppIconSource.png" -nt "$SCRIPT_DIR/Assets/AppIcon.icns" ]] || \
   [[ "$SCRIPT_DIR/Assets/MenuBarIconSource.png" -nt "$SCRIPT_DIR/Assets/AppIcon.icns" ]]; then
    "$SCRIPT_DIR/generate-icons.sh"
fi

if [[ ! -x "$PYTHON_BIN" ]]; then
    uv python install "$PYTHON_VERSION" \
        --install-dir "$PYTHON_INSTALL_DIR" \
        --cache-dir "$UV_CACHE" \
        --no-bin
fi

if [[ ! -d "$SEARXNG_SOURCE/.git" ]]; then
    mkdir -p "$SEARXNG_SOURCE"
    git -C "$SEARXNG_SOURCE" init
    git -C "$SEARXNG_SOURCE" remote add origin https://github.com/searxng/searxng.git
    git -C "$SEARXNG_SOURCE" fetch --depth 1 origin "$SEARXNG_COMMIT"
    git -C "$SEARXNG_SOURCE" checkout --detach FETCH_HEAD
fi

if [[ ! -f "$RUNTIME_MARKER" ]]; then
    uv pip install \
        --python "$PYTHON_BIN" \
        --target "$SITE_PACKAGES" \
        --cache-dir "$UV_CACHE" \
        --compile-bytecode \
        -r "$SEARXNG_SOURCE/requirements.txt" \
        setuptools wheel

    uv pip install \
        --python "$PYTHON_BIN" \
        --target "$SITE_PACKAGES" \
        --cache-dir "$UV_CACHE" \
        --no-deps \
        --no-build-isolation \
        --compile-bytecode \
        "$SEARXNG_SOURCE"

    install -m 644 \
        "$PROJECT_ROOT/runtime/searxng/version_frozen.py" \
        "$SITE_PACKAGES/searx/version_frozen.py"
    touch "$RUNTIME_MARKER"
fi

uv pip install \
    --python "$PYTHON_BIN" \
    --target "$SITE_PACKAGES" \
    --cache-dir "$UV_CACHE" \
    --compile-bytecode \
    --reinstall-package cuysearch \
    "$CUYSEARCH_SPEC" \
    "fastapi==0.141.1" \
    "httpx==0.28.1" \
    "pydantic-settings==2.15.0" \
    "uvicorn==0.52.4"

swift build \
    --package-path "$SCRIPT_DIR" \
    --cache-path "$BUILD_CACHE/swiftpm" \
    --configuration release
BIN_DIR="$(swift build \
    --package-path "$SCRIPT_DIR" \
    --cache-path "$BUILD_CACHE/swiftpm" \
    --configuration release \
    --show-bin-path)"

mkdir -p \
    "$APP_DIR/Contents/MacOS" \
    "$APP_DIR/Contents/Resources" \
    "$APP_DIR/Contents/Resources/Sources"
install -m 755 "$BIN_DIR/CuySearchManager" "$APP_DIR/Contents/MacOS/CuySearchManager"
install -m 644 "$SCRIPT_DIR/Info.plist" "$APP_DIR/Contents/Info.plist"
install -m 644 "$SCRIPT_DIR/Assets/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
install -m 644 \
    "$SCRIPT_DIR/Assets/MenuBarIconTemplate.png" \
    "$APP_DIR/Contents/Resources/MenuBarIconTemplate.png"
install -m 644 \
    "$PROJECT_ROOT/runtime/searxng/settings.yml" \
    "$APP_DIR/Contents/Resources/searxng-settings.yml"
install -m 644 \
    "$PROJECT_ROOT/runtime/searxng/limiter.toml" \
    "$APP_DIR/Contents/Resources/limiter.toml"

rm -rf "$APP_DIR/Contents/Resources/backend"
ditto "$PYTHON_ROOT" "$APP_DIR/Contents/Resources/runtime"
git -C "$SEARXNG_SOURCE" archive \
    --format=tar.gz \
    --output="$APP_DIR/Contents/Resources/Sources/searxng-$SEARXNG_COMMIT.tar.gz" \
    HEAD

codesign --force --deep --sign - "$APP_DIR"
touch "$APP_DIR"

echo "App autónoma creada en: $APP_DIR"
