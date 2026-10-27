#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd -P)
wt="${WT_CANDIDATE:-$root/.build/native-wt/wt}"
scratch=$(mktemp -d "${TMPDIR:-/tmp}/supacode-filter-process.XXXXXXXX")
scratch=$(cd "$scratch" && pwd -P)
trap 'rm -rf "$scratch"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 FILTER_TEST_LOG="$scratch/filter-starts"
python=$(command -v python3)
cat > "$scratch/filter.py" <<'PYTHON'
import os, sys
r, w = sys.stdin.buffer, sys.stdout.buffer
with open(os.environ['FILTER_TEST_LOG'], 'ab') as log: log.write(b'start\n')
def read_packet():
    h = r.read(4)
    if not h: return None
    if len(h) != 4: raise RuntimeError('short header')
    n = int(h, 16)
    if n == 0: return b''
    data = r.read(n - 4)
    if len(data) != n - 4: raise RuntimeError('short packet')
    return data
def read_list():
    values = []
    while True:
        data = read_packet()
        if data is None: return None
        if data == b'': return values
        values.append(data)
def send(data):
    w.write(('%04x' % (len(data) + 4)).encode() + data)
def flush():
    w.write(b'0000'); w.flush()
welcome = read_list()
assert welcome == [b'git-filter-client\n', b'version=2\n']
send(b'git-filter-server\n'); send(b'version=2\n'); flush()
capabilities = read_list()
assert b'capability=clean\n' in capabilities and b'capability=smudge\n' in capabilities
send(b'capability=clean\n'); send(b'capability=smudge\n'); flush()
while True:
    request = read_list()
    if request is None: break
    values = dict(line.rstrip(b'\n').split(b'=', 1) for line in request)
    chunks = read_list()
    if chunks is None: break
    data = b''.join(chunks)
    action = os.environ.get('FILTER_TEST_ACTION')
    if values[b'command'] == b'smudge' and values[b'pathname'] == b'first.asset' and action in ('error', 'abort'):
        send(('status=' + action + '\n').encode()); flush(); continue
    if values[b'command'] == b'clean':
        if not data.startswith(b'work:'): raise RuntimeError('unexpected clean input')
        data = data[5:]
    elif values[b'command'] == b'smudge': data = b'work:' + data
    else: raise RuntimeError('unexpected command')
    send(b'status=success\n'); flush()
    for offset in range(0, len(data), 65516): send(data[offset:offset + 65516])
    flush()
    if values[b'command'] == b'smudge' and values[b'pathname'] == b'first.asset' and action == 'trailer':
        send(b'status=error\n')
    flush()
with open(os.environ['FILTER_TEST_LOG'], 'ab') as log: log.write(b'done\n')
PYTHON
repo="$scratch/repository"
git init -q -b main "$repo"
git -C "$repo" config user.name Test
git -C "$repo" config user.email test@example.com
git -C "$repo" config filter.demo.process "$python '$scratch/filter.py'"
git -C "$repo" config filter.demo.clean 'exit 1'
git -C "$repo" config filter.demo.smudge 'exit 1'
git -C "$repo" config filter.demo.required true
printf '*.asset filter=demo\n' > "$repo/.gitattributes"
printf 'work:first\n' > "$repo/first.asset"
printf 'work:space\n' > "$repo/space name.asset"
python3 - "$repo/large.asset" <<'PYTHON'
import sys
with open(sys.argv[1], 'wb') as f: f.write(b'work:' + b'large-content-' * 16000)
PYTHON
git -C "$repo" add .gitattributes first.asset large.asset 'space name.asset' 
git -C "$repo" commit -q -m initial
: > "$FILTER_TEST_LOG"
mkdir "$scratch/no-git"
printf '#!/bin/sh\necho unexpected-git >&2\nexit 99\n' > "$scratch/no-git/git"
chmod +x "$scratch/no-git/git"
export WT_TEST_GIT=$(command -v git)
mkdir "$scratch/git-proxy"
printf '#!/bin/sh\nexec "$WT_TEST_GIT" "$@"\n' > "$scratch/git-proxy/git"
chmod +x "$scratch/git-proxy/git"
worktree=$(cd "$repo" && PATH="$scratch/git-proxy:$PATH" "$wt" switch process-filter --from main)
cmp "$repo/first.asset" "$worktree/first.asset"
cmp "$repo/large.asset" "$worktree/large.asset"
cmp "$repo/space name.asset" "$worktree/space name.asset"
[ "$(grep -c '^start$' "$FILTER_TEST_LOG")" = 1 ] || { echo 'filter was not reused for checkout' >&2; exit 1; }
grep -Fx done "$FILTER_TEST_LOG" >/dev/null || { echo 'filter shutdown did not finish' >&2; exit 1; }
# Status must apply the same process filter when an unchanged file's stat
# information changes. Keep Git off PATH and verify one process serves both.
cat > "$scratch/status-probe.swift" <<'SWIFT'
import Foundation
@main enum StatusProbe {
  static func main() throws {
    let root = URL(fileURLWithPath: CommandLine.arguments[1])
    if CommandLine.arguments.count > 2 {
      try NativeGitRepository.discardTracked(CommandLine.arguments[2], at: root)
      return
    }
    let entries = try NativeGitRepository.status(at: root)
    if entries.contains(where: { $0.path == "first.asset" || $0.path == "large.asset" || $0.path == "space name.asset" }) { exit(1) }
  }
}
SWIFT
xcrun swiftc -parse-as-library -target arm64-apple-macosx26.0 \
  -module-cache-path "$root/.build/native-wt/module-cache" \
  -I "$root/.build/libgit2/install/include" -L "$root/.build/libgit2/install/lib" \
  -lgit2 -lz -liconv -framework Security -framework CoreFoundation \
  "$root/SupacodeSettingsShared/Clients/Git/NativeGitRepository.swift" \
  "$root/SupacodeSettingsShared/Clients/Git/GitFetchCredentials.swift" \
  "$root/SupacodeSettingsShared/Clients/Git/GitNativeFetch.swift" \
  "$root/SupacodeSettingsShared/Clients/Git/GitFilterProcess.swift" \
  "$root/SupacodeSettingsShared/Clients/Git/NativeGitFilters.swift" \
  "$root/SupacodeSettingsShared/Clients/Git/NativeGitStatus.swift" \
  "$root/SupacodeSettingsShared/Clients/Git/NativeGitIndex.swift" \
  "$scratch/status-probe.swift" -o "$scratch/status-probe"
touch -t 202001010000 "$worktree/first.asset" "$worktree/large.asset" "$worktree/space name.asset"
: > "$FILTER_TEST_LOG"
PATH="$scratch/no-git:$PATH" "$scratch/status-probe" "$worktree"
[ "$(grep -c '^start$' "$FILTER_TEST_LOG")" = 1 ] || { echo 'filter was not reused for status' >&2; exit 1; }
printf 'work:changed\n' > "$worktree/first.asset"
git -C "$worktree" add first.asset
printf 'work:later\n' > "$worktree/first.asset"
PATH="$scratch/no-git:$PATH" "$scratch/status-probe" "$worktree" first.asset
cmp "$repo/first.asset" "$worktree/first.asset"
[ -z "$(git -C "$worktree" diff --cached --name-only)" ]

# `exec` must close filter processes before replacing wt with the command.
exec_path=$(cd "$repo" && PATH="$scratch/git-proxy:$PATH" "$wt" exec process-exec --from main -- /bin/pwd)
[ -d "$exec_path" ]
cmp "$repo/first.asset" "$exec_path/first.asset"

# A required process filter failure must not silently write unfiltered content.
git -C "$repo" config filter.demo.process /usr/bin/false
if (cd "$repo" && PATH="$scratch/git-proxy:$PATH" "$wt" switch rejected --from main); then
  echo 'required failed process filter was accepted' >&2
  exit 1
fi
git -C "$repo" config filter.demo.required false
optional=$(cd "$repo" && PATH="$scratch/git-proxy:$PATH" "$wt" switch optional --from main)
git -C "$repo" show main:first.asset > "$scratch/expected-raw"
cmp "$scratch/expected-raw" "$optional/first.asset"
git -C "$repo" config filter.demo.process "$python '$scratch/filter.py'"
for action in error trailer abort; do
  : > "$FILTER_TEST_LOG"
  filtered=$(cd "$repo" && FILTER_TEST_ACTION="$action" PATH="$scratch/git-proxy:$PATH" "$wt" switch "optional-$action" --from main)
  cmp "$scratch/expected-raw" "$filtered/first.asset"
  [ "$(grep -c '^start$' "$FILTER_TEST_LOG")" = 1 ] || { echo "filter restarted after $action" >&2; exit 1; }
  if [ "$action" != abort ]; then cmp "$repo/large.asset" "$filtered/large.asset"; fi
done
printf 'Process-only filter handshake, reuse, large packets, and failure passed.\n'
