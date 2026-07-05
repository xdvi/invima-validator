#!/usr/bin/env bash
set -euo pipefail

# Find project root without assuming we are executed from there.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT"

# Check if Zig is installed. If not, fail immediately.
if ! command -v zig &>/dev/null; then
    echo "Fatal: 'zig' compiler not found in PATH." >&2
    echo "Go get Zig 0.16.0 before trying to build. I am not your package manager." >&2
    exit 1
fi

OPTIMIZE="Debug"
USE_UPX=false

# Parse args. Keep it simple, no over-engineered getopt crap.
while [[ $# -gt 0 ]]; do
    case "$1" in
        --release)
            # ReleaseSmall: optimized for size, because bloat is a disease.
            OPTIMIZE="ReleaseSmall"
            shift
            ;;
        --upx)
            USE_UPX=true
            shift
            ;;
        *)
            echo "Usage: $0 [--release] [--upx]" >&2
            exit 1
            ;;
    esac
done

if [[ "$USE_UPX" == true ]]; then
    if ! command -v upx &>/dev/null; then
        echo "Error: --upx requested, but 'upx' command is not installed." >&2
        echo "Install it via pacman/yay or remove --upx." >&2
        exit 1
    fi
    if [[ "$OPTIMIZE" != "ReleaseSmall" ]]; then
        echo "Warning: Running UPX on a non-release build is silly. Forcing release mode..."
        OPTIMIZE="ReleaseSmall"
    fi
fi

echo "Starting build (Mode: ${OPTIMIZE})..."
zig build -Doptimize="${OPTIMIZE}"

if [[ "$USE_UPX" == true ]]; then
    echo "Compressing binaries using UPX..."
    if [[ -f "zig-out/lib/libinvima_ffi.so" ]]; then
        upx --best "zig-out/lib/libinvima_ffi.so"
    fi
    if [[ -f "zig-out/bin/demo" ]]; then
        upx --best "zig-out/bin/demo"
    fi
fi

echo "Build finished successfully. Output in 'zig-out/'."
