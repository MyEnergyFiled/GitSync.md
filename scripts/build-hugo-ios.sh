#!/usr/bin/env bash
set -euo pipefail

# Build the real Hugo engine as signed-in-app native code. This script must run
# on macOS with Xcode; it intentionally never builds or bundles the Hugo CLI.

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd)
BRIDGE_DIR="$REPO_ROOT/Native/HugoBridge"
OUTPUT_PATH=${1:-"$REPO_ROOT/HugoRuntime.xcframework"}
HUGO_VERSION_EXPECTED="0.134.3"
IOS_VERSION=${IOS_VERSION:-17.0}
GOMOBILE_VERSION=${GOMOBILE_VERSION:-latest}

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "error: Hugo iOS runtime must be built on macOS with Xcode" >&2
  exit 2
fi
command -v go >/dev/null || { echo "error: Go is required" >&2; exit 2; }
command -v xcodebuild >/dev/null || { echo "error: Xcode is required" >&2; exit 2; }

XCODE_VERSION=$(xcodebuild -version | head -n 1)
GO_VERSION=$(go version)
echo "Building Hugo runtime"
echo "  Hugo: $HUGO_VERSION_EXPECTED"
echo "  Go: $GO_VERSION"
echo "  Xcode: $XCODE_VERSION"
echo "  gomobile: $GOMOBILE_VERSION"

TOOL_DIR=${RUNNER_TEMP:-"$REPO_ROOT/.build"}/hugo-runtime-tools
mkdir -p "$TOOL_DIR/bin"
GOBIN="$TOOL_DIR/bin" go install "golang.org/x/mobile/cmd/gomobile@$GOMOBILE_VERSION"
export PATH="$TOOL_DIR/bin:$PATH"
gomobile version
gomobile init

pushd "$BRIDGE_DIR" >/dev/null
# gomobile bind requires golang.org/x/mobile to be present in the module graph.
go get "golang.org/x/mobile@$GOMOBILE_VERSION"
go mod tidy
go test ./...
popd >/dev/null

rm -rf "$OUTPUT_PATH"
mkdir -p "$(dirname -- "$OUTPUT_PATH")"
pushd "$BRIDGE_DIR" >/dev/null
CGO_ENABLED=1 gomobile bind \
  -target=ios \
  -iosversion="$IOS_VERSION" \
  -prefix=Hugo \
  -trimpath \
  -o "$OUTPUT_PATH" \
  .
popd >/dev/null

[[ -d "$OUTPUT_PATH" ]] || { echo "error: XCFramework was not produced" >&2; exit 1; }
find "$OUTPUT_PATH" -name '*.framework' -maxdepth 3 -print
du -sh "$OUTPUT_PATH"

# Keep a machine-readable dependency inventory next to the CI artifact. The
# app release must ship this inventory with the corresponding notices.
LICENSES_PATH="${OUTPUT_PATH%.*}.modules.txt"
pushd "$BRIDGE_DIR" >/dev/null
go list -m all | sort > "$LICENSES_PATH"
popd >/dev/null
echo "Dependency inventory: $LICENSES_PATH"
