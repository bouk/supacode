#!/usr/bin/env bash
set -euo pipefail
project_root=$(cd "$(dirname "$0")/.." && pwd -P)
wt="$project_root/.build/native-wt/wt"
scratch=$(mktemp -d "${TMPDIR:-/tmp}/supacode-native-fetch.XXXXXXXX")
scratch=$(cd "$scratch" && pwd -P)
server_pid=''
trap 'if [ -n "$server_pid" ]; then kill "$server_pid" 2>/dev/null || true; fi; rm -rf "$scratch"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
backend="$(git --exec-path)/git-http-backend"
git init -q --bare "$scratch/remote.git"
git init -q -b main "$scratch/seed"
git -C "$scratch/seed" config user.name Test
git -C "$scratch/seed" config user.email test@example.com
printf 'one\n' > "$scratch/seed/file"
git -C "$scratch/seed" add file
git -C "$scratch/seed" commit -qm first
git -C "$scratch/seed" push -q "$scratch/remote.git" main
git clone -q -b main "$scratch/remote.git" "$scratch/client"
printf 'two\n' >> "$scratch/seed/file"
git -C "$scratch/seed" commit -qam second
git -C "$scratch/seed" push -q "$scratch/remote.git" main
cat > "$scratch/server.py" <<'PY'
import base64, http.server, os, subprocess, sys, urllib.parse
root, backend, portfile = sys.argv[1:]
class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def handle_request(self):
        if self.headers.get('Authorization') != 'Basic ' + base64.b64encode(b'user:secret').decode():
            self.send_response(401)
            self.send_header('WWW-Authenticate', 'Basic realm="test"')
            self.send_header('Content-Length', '0')
            self.end_headers()
            return
        parsed = urllib.parse.urlsplit(self.path)
        data = self.rfile.read(int(self.headers.get('Content-Length', '0')))
        env = os.environ.copy()
        env.update(GIT_PROJECT_ROOT=root, GIT_HTTP_EXPORT_ALL='1', PATH_INFO=parsed.path,
                   QUERY_STRING=parsed.query, REQUEST_METHOD=self.command,
                   CONTENT_TYPE=self.headers.get('Content-Type', ''), CONTENT_LENGTH=str(len(data)))
        result = subprocess.run([backend], input=data, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
        header, body = result.stdout.split(b'\r\n\r\n', 1)
        status = 200
        headers = []
        for line in header.decode('latin1').split('\r\n'):
            key, value = line.split(':', 1)
            if key.lower() == 'status': status = int(value.strip().split()[0])
            else: headers.append((key, value.strip()))
        self.send_response(status)
        for key, value in headers: self.send_header(key, value)
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    do_GET = handle_request
    do_POST = handle_request
server = http.server.HTTPServer(('127.0.0.1', 0), Handler)
with open(portfile, 'w') as f: f.write(str(server.server_port))
server.serve_forever()
PY
python3 "$scratch/server.py" "$scratch" "$backend" "$scratch/port" &
server_pid=$!
for _ in {1..100}; do [ -s "$scratch/port" ] && break; kill -0 "$server_pid"; sleep 0.05; done
port=$(cat "$scratch/port")
cat > "$scratch/helper" <<'SH'
#!/bin/sh
printf '%s\n' "$1" >> "$FETCH_HELPER_LOG"
cat >/dev/null
if [ "$1" = get ]; then printf 'username=user\npassword=%s\n' "$FETCH_HELPER_PASSWORD"; fi
SH
chmod +x "$scratch/helper"
git -C "$scratch/client" remote set-url origin "http://127.0.0.1:$port/remote.git"
git -C "$scratch/client" config credential.helper "!$scratch/helper"
export FETCH_HELPER_LOG="$scratch/helper.log" FETCH_HELPER_PASSWORD=secret
mkdir "$scratch/no-git"
printf '#!/bin/sh\nexit 99\n' > "$scratch/no-git/git"
chmod +x "$scratch/no-git/git"
export WT_TEST_GIT=$(command -v git)
mkdir "$scratch/git-proxy"
printf '#!/bin/sh\nexec "$WT_TEST_GIT" "$@"\n' > "$scratch/git-proxy/git"
chmod +x "$scratch/git-proxy/git"
(cd "$scratch/client" && PATH="$scratch/git-proxy:$PATH" "$wt" switch fetched --fetch --from origin/main --path "$scratch/fetched" >/dev/null)
test "$(git -C "$scratch/client" rev-parse refs/remotes/origin/main)" = "$(git -C "$scratch/seed" rev-parse HEAD)"
cmp "$scratch/fetched/file" "$scratch/seed/file"
grep -qx get "$scratch/helper.log"
grep -qx store "$scratch/helper.log"
: > "$scratch/helper.log"
export FETCH_HELPER_PASSWORD=wrong
if (cd "$scratch/client" && PATH="$scratch/git-proxy:$PATH" "$wt" switch rejected --fetch --from origin/main --path "$scratch/rejected" >/dev/null 2>&1); then
  echo 'Fetch unexpectedly accepted bad credentials' >&2
  exit 1
fi
grep -qx get "$scratch/helper.log"
grep -qx erase "$scratch/helper.log"
test ! -e "$scratch/rejected"
cat > "$scratch/clone.swift" <<'SWIFT'
import Foundation

@main enum CloneFixture {
  static func main() {
    do {
      try NativeGitRepository.clone(
        url: CommandLine.arguments[1], destination: URL(fileURLWithPath: CommandLine.arguments[2]),
        branch: "main", depth: CommandLine.arguments.count > 3 ? nil : 1,
        cancelled: { false }, progress: { _ in })
    } catch {
      FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
      exit(1)
    }
  }
}
SWIFT
install_dir="$project_root/.build/libgit2/install"
xcrun swiftc -parse-as-library -target arm64-apple-macosx26.0 \
  -I "$install_dir/include" -L "$install_dir/lib" -lgit2 -lz -liconv \
  -framework Security -framework CoreFoundation \
  "$project_root/SupacodeSettingsShared/Clients/Git/NativeGitRepository.swift" \
  "$project_root/SupacodeSettingsShared/Clients/Git/NativeGitClone.swift" \
  "$project_root/SupacodeSettingsShared/Clients/Git/NativeGitFilters.swift" \
  "$project_root/SupacodeSettingsShared/Clients/Git/GitFilterProcess.swift" \
  "$project_root/SupacodeSettingsShared/Clients/Git/GitFetchCredentials.swift" \
  "$project_root/SupacodeSettingsShared/Clients/Git/GitNativeFetch.swift" \
  "$scratch/clone.swift" -o "$scratch/clone"
printf '[credential]\n  helper = !%s\n' "$scratch/helper" > "$scratch/clone-config"
cp "$scratch/clone-config" "$scratch/clone-config-original"
export GIT_CONFIG_GLOBAL="$scratch/clone-config" FETCH_HELPER_PASSWORD=secret
: > "$scratch/helper.log"
if ! PATH="$scratch/no-git:$PATH" "$scratch/clone" "http://127.0.0.1:$port/remote.git" "$scratch/shallow"; then
  echo 'Authenticated clone failed; credential helper operations:' >&2
  cat "$scratch/helper.log" >&2
  exit 1
fi
cmp "$scratch/shallow/file" "$scratch/seed/file"
test -s "$scratch/shallow/.git/shallow"
grep -qx get "$scratch/helper.log"
grep -qx store "$scratch/helper.log"
if ! cmp -s "$scratch/clone-config" "$scratch/clone-config-original"; then
  echo 'Clone wrote repository settings into global configuration' >&2
  exit 1
fi
: > "$scratch/helper.log"
export FETCH_HELPER_PASSWORD=wrong
if PATH="$scratch/no-git:$PATH" "$scratch/clone" "http://127.0.0.1:$port/remote.git" "$scratch/clone-rejected" >/dev/null 2>&1; then
  echo 'Clone unexpectedly accepted bad credentials' >&2
  exit 1
fi
grep -qx get "$scratch/helper.log"
grep -qx erase "$scratch/helper.log"
test ! -e "$scratch/clone-rejected"
if command -v git-lfs >/dev/null 2>&1; then
  git init -q -b main "$scratch/lfs-source"
  git -C "$scratch/lfs-source" config user.name Test
  git -C "$scratch/lfs-source" config user.email test@example.com
  git -C "$scratch/lfs-source" lfs install --local >/dev/null
  git -C "$scratch/lfs-source" lfs track '*.asset' >/dev/null
  printf 'native clone lfs content\n' > "$scratch/lfs-source/test.asset"
  git -C "$scratch/lfs-source" add .gitattributes test.asset
  git -C "$scratch/lfs-source" commit -qm lfs
  git lfs install --file "$scratch/clone-config" >/dev/null
  "$scratch/clone" "file://$scratch/lfs-source" "$scratch/lfs-clone" full
  cmp "$scratch/lfs-source/test.asset" "$scratch/lfs-clone/test.asset"
fi
printf 'Authenticated native fetch, shallow clone, and credential helper lifecycle passed.\n'
