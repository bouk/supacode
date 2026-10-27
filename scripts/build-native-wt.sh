#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
repo_root=$(cd "$script_dir/.." && pwd -P)
if [ "${SUPACODE_LIBGIT2_BUILT:-0}" != 1 ]; then
  "$script_dir/build-libgit2.sh"
fi
install_dir="$repo_root/.build/libgit2/install"
mkdir -p "$repo_root/.build/native-wt"
compat_dir=$(mktemp -d "$repo_root/.build/native-wt/compat.XXXXXXXX")
trap 'rm -rf "$compat_dir"' EXIT
cp "$repo_root/Resources/git-wt/wt" "$compat_dir/wt"
(cd "$compat_dir" && GIT_DIR=/dev/null git apply -p1 "$repo_root/patches/git-wt/git-wt-canonical-worktree-path.patch")
mv "$compat_dir/wt" "$repo_root/.build/native-wt/wt-compat"
chmod +x "$repo_root/.build/native-wt/wt-compat"
export DEVELOPER_DIR="$("$script_dir/select-developer-dir.sh")"
xcrun swiftc -parse-as-library -O -target arm64-apple-macosx26.0 \
  -module-cache-path "$repo_root/.build/native-wt/module-cache" \
  -I "$install_dir/include" -L "$install_dir/lib" \
  -lgit2 -lz -liconv -framework Security -framework CoreFoundation \
  "$repo_root"/NativeWT/*.swift -o "$repo_root/.build/native-wt/wt"
