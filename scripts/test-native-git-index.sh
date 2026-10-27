#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd -P)
scratch=$(mktemp -d "${TMPDIR:-/tmp}/supacode-native-index.XXXXXXXX")
scratch=$(cd "$scratch" && pwd -P)
trap 'rm -rf "$scratch"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
cat > "$scratch/probe.swift" <<'SWIFT'
import Foundation
@main enum IndexProbe {
  static func main() {
    do {
      let root = URL(fileURLWithPath: CommandLine.arguments[2])
      switch CommandLine.arguments[1] {
      case "stage": try NativeGitRepository.stage(CommandLine.arguments[3], at: root)
      case "discard": try NativeGitRepository.discardTracked(CommandLine.arguments[3], at: root)
      default: try NativeGitRepository.unstage(CommandLine.arguments[3], at: root)
      }
    } catch {
      FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
      exit(1)
    }
  }
}
SWIFT
xcrun swiftc -parse-as-library -target arm64-apple-macosx26.0 \
  -module-cache-path "$root/.build/native-wt/module-cache" \
  -I "$root/.build/libgit2/install/include" -L "$root/.build/libgit2/install/lib" \
  -lgit2 -lz -liconv -framework Security -framework CoreFoundation \
  "$root/SupacodeSettingsShared/Clients/Git/NativeGitRepository.swift" \
  "$root/SupacodeSettingsShared/Clients/Git/GitFilterProcess.swift" \
  "$root/SupacodeSettingsShared/Clients/Git/NativeGitFilters.swift" \
  "$root/SupacodeSettingsShared/Clients/Git/NativeGitIndex.swift" \
  "$scratch/probe.swift" -o "$scratch/probe"
mkdir "$scratch/no-git"
printf '#!/bin/sh\necho unexpected-git >&2\nexit 99\n' > "$scratch/no-git/git"
chmod +x "$scratch/no-git/git"
repo="$scratch/repo"
git init -q -b main "$repo"
git -C "$repo" config user.name Test
git -C "$repo" config user.email test@example.com
printf old > "$repo/a*"
printf old > "$repo/abc"
printf old > "$repo/deleted"
ln -s original "$repo/link"
printf '*.ignored\n' > "$repo/.gitignore"
git -C "$repo" add .
git -C "$repo" commit -q -m initial
printf new > "$repo/a*"
printf new > "$repo/abc"
PATH="$scratch/no-git:$PATH" "$scratch/probe" stage "$repo" 'a*'
[ "$(git -C "$repo" diff --cached --name-only)" = 'a*' ]
PATH="$scratch/no-git:$PATH" "$scratch/probe" unstage "$repo" 'a*'
[ -z "$(git -C "$repo" diff --cached --name-only)" ]
PATH="$scratch/no-git:$PATH" "$scratch/probe" stage "$repo" 'a*'
printf later > "$repo/a*"
PATH="$scratch/no-git:$PATH" "$scratch/probe" discard "$repo" 'a*'
[ "$(cat "$repo/a*")" = old ]
[ "$(cat "$repo/abc")" = new ]
[ -z "$(git -C "$repo" diff --cached --name-only)" ]
rm "$repo/link"
ln -s changed "$repo/link"
PATH="$scratch/no-git:$PATH" "$scratch/probe" discard "$repo" link
[ "$(readlink "$repo/link")" = original ]
printf new > "$repo/new file"
PATH="$scratch/no-git:$PATH" "$scratch/probe" stage "$repo" 'new file'
[ "$(git -C "$repo" diff --cached --name-only)" = 'new file' ]
PATH="$scratch/no-git:$PATH" "$scratch/probe" unstage "$repo" 'new file'
[ -f "$repo/new file" ]
PATH="$scratch/no-git:$PATH" "$scratch/probe" stage "$repo" 'new file'
PATH="$scratch/no-git:$PATH" "$scratch/probe" discard "$repo" 'new file'
[ ! -e "$repo/new file" ]
[ -z "$(git -C "$repo" diff --cached --name-only)" ]
rm "$repo/deleted"
PATH="$scratch/no-git:$PATH" "$scratch/probe" stage "$repo" deleted
[ "$(git -C "$repo" diff --cached --name-only)" = deleted ]
PATH="$scratch/no-git:$PATH" "$scratch/probe" unstage "$repo" deleted
[ -z "$(git -C "$repo" diff --cached --name-only)" ]
[ ! -e "$repo/deleted" ]
PATH="$scratch/no-git:$PATH" "$scratch/probe" discard "$repo" deleted
[ "$(cat "$repo/deleted")" = old ]
printf keep > "$repo/.git/index.lock"
if PATH="$scratch/no-git:$PATH" "$scratch/probe" stage "$repo" abc; then
  echo 'index lock was ignored' >&2; exit 1
fi
grep -Fx keep "$repo/.git/index.lock" >/dev/null
if PATH="$scratch/no-git:$PATH" "$scratch/probe" discard "$repo" abc; then
  echo 'discard ignored index lock' >&2; exit 1
fi
[ "$(cat "$repo/abc")" = new ]
rm "$repo/.git/index.lock"
printf ignored > "$repo/file.ignored"
if PATH="$scratch/no-git:$PATH" "$scratch/probe" stage "$repo" file.ignored; then
  echo 'ignored file was staged' >&2; exit 1
fi
[ -z "$(git -C "$repo" diff --cached --name-only)" ]
unborn="$scratch/unborn"
git init -q -b main "$unborn"
printf data > "$unborn/file"
PATH="$scratch/no-git:$PATH" "$scratch/probe" stage "$unborn" file
PATH="$scratch/no-git:$PATH" "$scratch/probe" unstage "$unborn" file
[ "$(git -C "$unborn" status --porcelain)" = '?? file' ]
# A failed required filter must leave the real index byte-for-byte intact.
git -C "$repo" config filter.fail.process /usr/bin/false
git -C "$repo" config filter.fail.required true
printf '*.asset filter=fail\n' > "$repo/.gitattributes"
printf content > "$repo/bad.asset"
cp "$repo/.git/index" "$scratch/before-index"
if PATH="$scratch/no-git:$PATH" "$scratch/probe" stage "$repo" bad.asset; then
  echo 'failed required filter was accepted' >&2; exit 1
fi
cmp "$scratch/before-index" "$repo/.git/index"
[ ! -e "$repo/.git/index.lock" ]
# A slow clean filter leaves the standard lock held while it runs, preventing
# another Git writer from committing against a stale index snapshot.
mkfifo "$scratch/ready" "$scratch/release"
cat > "$scratch/slow-filter.sh" <<SHELL
#!/bin/sh
printf 'ready\\n' > '$scratch/ready'
IFS= read -r signal < '$scratch/release'
cat
SHELL
chmod +x "$scratch/slow-filter.sh"
git -C "$repo" config filter.slow.clean "$scratch/slow-filter.sh"
git -C "$repo" config filter.slow.required true
printf '*.slow filter=slow\n' >> "$repo/.gitattributes"
printf slow > "$repo/file.slow"
PATH="$scratch/no-git:$PATH" "$scratch/probe" stage "$repo" file.slow &
staging=$!
IFS= read -r signal < "$scratch/ready"
[ "$signal" = ready ]
if git -C "$repo" add abc >/dev/null 2>&1; then
  echo 'concurrent Git writer acquired the locked index' >&2; exit 1
fi
printf 'continue\n' > "$scratch/release"
wait "$staging"
[ "$(git -C "$repo" diff --cached --name-only)" = file.slow ]
PATH="$scratch/no-git:$PATH" "$scratch/probe" unstage "$repo" file.slow

# Reset a conflicted file's index entry to HEAD, retaining the worktree file.
conflict="$scratch/conflict"
git init -q -b main "$conflict"
git -C "$conflict" config user.name Test
git -C "$conflict" config user.email test@example.com
printf 'base\n' > "$conflict/file"
git -C "$conflict" add file
git -C "$conflict" commit -q -m base
git -C "$conflict" checkout -q -b other
printf 'other\n' > "$conflict/file"
git -C "$conflict" commit -qam other
git -C "$conflict" checkout -q main
printf 'main\n' > "$conflict/file"
git -C "$conflict" commit -qam main
if git -C "$conflict" merge other >/dev/null 2>&1; then echo 'expected conflict' >&2; exit 1; fi
cp "$conflict/file" "$scratch/conflict-before"
PATH="$scratch/no-git:$PATH" "$scratch/probe" unstage "$conflict" file
[ -z "$(git -C "$conflict" ls-files -u)" ]
[ "$(git -C "$conflict" show :file)" = main ]
cmp "$scratch/conflict-before" "$conflict/file"

if git lfs version >/dev/null 2>&1; then
  lfs="$scratch/lfs"
  git init -q -b main "$lfs"
  git -C "$lfs" config user.name Test
  git -C "$lfs" config user.email test@example.com
  git -C "$lfs" lfs install --local >/dev/null
  git -C "$lfs" lfs track '*.asset' >/dev/null
  printf 'lfs data\n' > "$lfs/file.asset"
  "$scratch/probe" stage "$lfs" file.asset
  git -C "$lfs" show :file.asset | grep -Fx 'version https://git-lfs.github.com/spec/v1' >/dev/null
  git -C "$lfs" add .gitattributes
  git -C "$lfs" commit -q -m initial
  printf 'changed lfs\n' > "$lfs/file.asset"
  "$scratch/probe" stage "$lfs" file.asset
  printf 'later lfs\n' > "$lfs/file.asset"
  "$scratch/probe" discard "$lfs" file.asset
  [ "$(cat "$lfs/file.asset")" = 'lfs data' ]
  [ -z "$(git -C "$lfs" status --porcelain)" ]
fi
printf 'Native staging and unstaging preserve literal paths, locks, and filters.\n'
