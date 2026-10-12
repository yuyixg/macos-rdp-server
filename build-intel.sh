#!/bin/bash
# Local x86_64 (Intel) build. Upstream releases are arm64-only.
# Mirrors .github/workflows/release.yml, with two local differences:
#   - FreeRDP is built with JSON + AAD disabled (Homebrew json-c otherwise leaks in)
#   - OpenSSL comes from Homebrew openssl@3 (static libs)
#
# Usage:
#   ./build-intel.sh            build only  -> build/macos-rdp-daemon
#   ./build-intel.sh --install  build, then deploy via scripts/install-user.sh
set -euo pipefail
cd "$(dirname "$0")"

ROOT="$PWD"
DEPS="$ROOT/.deps"
FRDP_SRC="$DEPS/freerdp-src"
FRDP_INSTALL="$DEPS/freerdp-install"
OSSL="$(brew --prefix openssl@3)"
JOBS="$(sysctl -n hw.logicalcpu)"

# 1. FreeRDP (static, server-only) — skipped if already installed
if [[ ! -f "$FRDP_INSTALL/lib/libfreerdp3.a" ]]; then
    if [[ ! -d "$FRDP_SRC" ]]; then
        git clone --depth 1 --branch "build/3.10.3-patched" \
            https://github.com/grioghar/FreeRDP.git "$FRDP_SRC"
    fi
    cmake -S "$FRDP_SRC" -B "$FRDP_SRC/build" -G Ninja \
        -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
        -DCMAKE_BUILD_TYPE=MinSizeRel \
        -DCMAKE_C_FLAGS="-Os" -DCMAKE_CXX_FLAGS="-Os" \
        -DCMAKE_INSTALL_PREFIX="$FRDP_INSTALL" \
        -DCMAKE_OSX_ARCHITECTURES="x86_64" \
        -DCMAKE_OSX_DEPLOYMENT_TARGET="14.0" \
        -DCMAKE_PREFIX_PATH="$OSSL" \
        -DBUILD_SHARED_LIBS=OFF \
        -DWITH_JSON_DISABLED=ON -DWITH_AAD=OFF -DWITH_VERBOSE_WINPR_ASSERT=OFF \
        -DWITH_SERVER=ON -DWITH_PLATFORM_SERVER=OFF \
        -DWITH_CLIENT=OFF -DWITH_CLIENT_COMMON=OFF -DWITH_PROXY=OFF \
        -DWITH_SHADOW=OFF -DWITH_SAMPLE=OFF -DWITH_WINPR_TOOLS=OFF \
        -DWITH_FFMPEG=OFF -DWITH_SWSCALE=OFF -DWITH_DSP_FFMPEG=OFF \
        -DWITH_CAIRO=OFF -DWITH_OPUS=OFF -DWITH_RDTK=OFF \
        -DWITH_WAYLAND=OFF -DWITH_X11=OFF -DWITH_CUPS=OFF -DWITH_PCSC=OFF \
        -DWITH_JPEG=OFF -DWITH_WEBP=OFF -DWITH_OSS=OFF -DWITH_ALSA=OFF -DWITH_PULSE=OFF \
        -DWITH_CHANNELS=ON -DWITH_RDPSND=ON -DWITH_CLIPRDR=ON -DWITH_RDPGFX=ON \
        -DWITH_RDPEI=OFF -DWITH_RDPDR=OFF -DWITH_PRINTER=OFF -DWITH_SMARTCARD=OFF \
        -DWITH_SERIAL=OFF -DWITH_PARALLEL=OFF -DWITH_URBDRC=OFF \
        -DWITH_VIDEO_ENCODER=OFF -DWITH_NEON=OFF -DBUILD_TESTING=OFF \
        -DOPENSSL_ROOT_DIR="$OSSL" -DOPENSSL_USE_STATIC_LIBS=TRUE
    cmake --build "$FRDP_SRC/build" --parallel "$JOBS"
    cmake --install "$FRDP_SRC/build"
fi

# 2. Daemon (static FreeRDP + OpenSSL -> no non-system dylibs)
cmake -S "$ROOT" -B "$ROOT/build" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_ARCHITECTURES="x86_64" \
    -DMACOS_RDP_STATIC=ON \
    -DFREERDP_STATIC_INSTALL="$FRDP_INSTALL" \
    -DCMAKE_PREFIX_PATH="$FRDP_INSTALL;$OSSL" \
    -DOPENSSL_ROOT_DIR="$OSSL" -DOPENSSL_USE_STATIC_LIBS=TRUE
# Homebrew's OpenSSL targets macOS 15 -> harmless "built for newer macOS" ld warnings.
cmake --build "$ROOT/build" --parallel "$JOBS" 2>&1 | grep -v 'ld: warning' || true
[[ -x "$ROOT/build/macos-rdp-daemon" ]] || { echo "build failed" >&2; exit 1; }

# 3. Sanity checks
BIN="$ROOT/build/macos-rdp-daemon"
lipo -archs "$BIN" | grep -q x86_64 || { echo "not x86_64" >&2; exit 1; }
if otool -L "$BIN" | tail -n +2 | awk '{print $1}' | grep -Ev '^(/usr/lib/|/System/)'; then
    echo "unexpected non-system dylib dependency (see above)" >&2; exit 1
fi
echo "OK: $BIN ($(lipo -archs "$BIN"), self-contained)"

# 4. Optional deploy. System LibreSSL first: OpenSSL 3's default PKCS#12
#    encryption can't be imported by `security import`.
if [[ "${1:-}" == "--install" ]]; then
    PATH="/usr/bin:/bin:/usr/sbin:/sbin:$PATH" bash scripts/install-user.sh "$BIN" || true
    # install-user.sh bootstraps right after an async bootout, which can fail
    # with "Bad request" while the old instance is still exiting. Retry.
    GUI="gui/$(id -u)"; LABEL="com.macosrdp.agent"
    for _ in 1 2 3 4 5; do
        launchctl print "$GUI/$LABEL" >/dev/null 2>&1 && break
        sleep 1
        launchctl bootstrap "$GUI" "$HOME/Library/LaunchAgents/$LABEL.plist" 2>/dev/null || true
    done
    launchctl print "$GUI/$LABEL" >/dev/null 2>&1 \
        && echo "agent running" || { echo "agent failed to load" >&2; exit 1; }
fi
