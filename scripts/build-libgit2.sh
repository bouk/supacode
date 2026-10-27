#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
repo_root=$(cd "$script_dir/.." && pwd -P)
source_dir="$repo_root/ThirdParty/libgit2"
build_dir="$repo_root/.build/libgit2/build"
install_dir="$repo_root/.build/libgit2/install"

if [ ! -f "$source_dir/CMakeLists.txt" ]; then
  echo "error: libgit2 source is missing; run git submodule update --init ThirdParty/libgit2" >&2
  exit 1
fi
if ! command -v cmake >/dev/null; then
  echo "error: cmake is required to build libgit2" >&2
  exit 1
fi

# Build for Apple Silicon from the pinned source. The static
# library is intentionally an out-of-tree build, never a machine-local Nix or
# Homebrew dependency. libgit2's exec transport uses the user's SSH client.
export DEVELOPER_DIR="$("$script_dir/select-developer-dir.sh")"
cmake -S "$source_dir" -B "$build_dir" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="$install_dir" \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=26.0 \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DBUILD_SHARED_LIBS=OFF -DBUILD_TESTS=OFF -DBUILD_CLI=OFF \
  -DUSE_HTTPS=SecureTransport -DUSE_SSH=exec
cmake --build "$build_dir" --parallel
cmake --install "$build_dir"

# Swift's Clang importer needs a module map next to the public headers.
cat > "$install_dir/include/module.modulemap" <<'EOF'
module CLibgit2 {
  header "git2.h"
  header "git2/sys/filter.h"
  header "git2/sys/errors.h"
  header "git2/sys/repository.h"
  export *
}
EOF

# Use a static framework so its headers do not collide with other static
# XCFrameworks' shared include directory in Xcode's build products.
framework_dir="$repo_root/.build/libgit2/CLibgit2.xcframework"
temporary_framework="$repo_root/.build/libgit2/CLibgit2-new.xcframework"
staging="$repo_root/.build/libgit2/CLibgit2.framework"
rm -rf "$temporary_framework" "$staging"
mkdir -p "$staging/Headers" "$staging/Modules"
cp -R "$install_dir/include/git2" "$staging/Headers/"
cp "$install_dir/include/git2.h" "$staging/Headers/"
cp "$install_dir/lib/libgit2.a" "$staging/CLibgit2"
cat > "$staging/Modules/module.modulemap" <<'MAP'
framework module CLibgit2 {
  header "git2.h"
  header "git2/sys/filter.h"
  header "git2/sys/errors.h"
  header "git2/sys/repository.h"
  export *
}
MAP
cat > "$staging/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>CLibgit2</string>
  <key>CFBundleIdentifier</key><string>app.supabit.CLibgit2</string>
  <key>CFBundleName</key><string>CLibgit2</string>
  <key>CFBundlePackageType</key><string>FMWK</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleShortVersionString</key><string>1.9.7</string>
  <key>MinimumOSVersion</key><string>26.0</string>
</dict></plist>
PLIST
xcodebuild -create-xcframework -framework "$staging" -output "$temporary_framework"
rm -rf "$framework_dir"
mv "$temporary_framework" "$framework_dir"
