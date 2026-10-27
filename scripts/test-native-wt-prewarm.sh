#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd -P)
wt="${WT_CANDIDATE:-$root/.build/native-wt/wt}"
scratch=$(mktemp -d "${TMPDIR:-/tmp}/supacode-prewarm-test.XXXXXXXX")
scratch=$(cd "$scratch" && pwd -P)
trap 'rm -rf "$scratch"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
repo="$scratch/repository"
git init -q -b main "$repo"
git -C "$repo" config user.name Test
git -C "$repo" config user.email test@example.com
printf 'initial\n' > "$repo/tracked"
git -C "$repo" add tracked
git -C "$repo" commit -q -m initial
export WT_TEST_GIT=$(command -v git)
mkdir "$scratch/git-proxy"
printf '#!/bin/sh\nexec "$WT_TEST_GIT" "$@"\n' > "$scratch/git-proxy/git"
chmod +x "$scratch/git-proxy/git"
mkdir -p "$repo/.git/hooks"
printf '#!/bin/sh\ntouch "$PWD/hook-fired"\n' > "$repo/.git/hooks/post-checkout"
chmod +x "$repo/.git/hooks/post-checkout"
(cd "$repo" && PATH="$scratch/git-proxy:$PATH" "$wt" __prewarm --from main)
pool="$repo/.git/supacode-prewarm"
[ -f "$pool/owner.json" ]
(cd "$repo" && "$wt" ls --json) > "$scratch/wt-list.json"
(cd "$repo" && "$wt" __app-ls) > "$scratch/app-list.json"
python3 - "$scratch/wt-list.json" "$scratch/app-list.json" <<'PYTHON'
import json, sys
with open(sys.argv[1]) as f: ordinary = json.load(f)
with open(sys.argv[2]) as f: app = json.load(f)
assert len(ordinary) == 2 and len(app) == 1
PYTHON
cp "$pool/owner.json" "$scratch/original-marker"
python3 - "$pool/owner.json" <<'PYTHON'
import json, sys
path = sys.argv[1]
with open(path) as f: marker = json.load(f)
marker['owner'] = 'foreign'
with open(path, 'w') as f: json.dump(marker, f)
PYTHON
(cd "$repo" && "$wt" __app-ls) > "$scratch/foreign-list.json"
python3 - "$scratch/foreign-list.json" <<'PYTHON'
import json, sys
with open(sys.argv[1]) as f: assert len(json.load(f)) == 2
PYTHON
cp "$scratch/original-marker" "$pool/owner.json"
cmp "$repo/tracked" "$pool/worktree/tracked"
[ ! -e "$pool/worktree/hook-fired" ]
[ "$(git -C "$pool/worktree" symbolic-ref -q HEAD || :)" = '' ]
[ "$(git -C "$repo" branch --list 'supacode-prewarm/*')" = '' ]
printf 'user content\n' > "$pool/worktree/untracked"
(cd "$repo" && PATH="$scratch/git-proxy:$PATH" "$wt" __prewarm --from main)
grep -Fx 'user content' "$pool/worktree/untracked" >/dev/null
[ "$(git -C "$repo" worktree list --porcelain | grep -c '^worktree ')" = 2 ]
concurrent="$scratch/concurrent"
git init -q -b main "$concurrent"
git -C "$concurrent" config user.name Test
git -C "$concurrent" config user.email test@example.com
printf 'tracked\n' > "$concurrent/tracked"
git -C "$concurrent" add tracked
git -C "$concurrent" commit -q -m initial
(cd "$concurrent" && PATH="$scratch/git-proxy:$PATH" "$wt" __prewarm --from main) &
first=$!
(cd "$concurrent" && PATH="$scratch/git-proxy:$PATH" "$wt" __prewarm --from main) &
second=$!
wait "$first"
wait "$second"
[ "$(git -C "$concurrent" worktree list --porcelain | grep -c '^worktree ')" = 2 ]

# HEAD must be resolved in the source repository, not the detached pool checkout.
head_repo="$scratch/head-repo"
git init -q -b main "$head_repo"
git -C "$head_repo" config user.name Test
git -C "$head_repo" config user.email test@example.com
printf 'old\n' > "$head_repo/tracked"
git -C "$head_repo" add tracked
git -C "$head_repo" commit -qm initial
(cd "$head_repo" && PATH="$scratch/git-proxy:$PATH" "$wt" __prewarm)
printf 'new\n' > "$head_repo/tracked"
git -C "$head_repo" commit -qam latest
head_claim=$(cd "$head_repo" && SUPACODE_USE_PREWARM=1 PATH="$scratch/git-proxy:$PATH" "$wt" switch head-claim --from HEAD)
cmp "$head_repo/tracked" "$head_claim/tracked"

# Supacode's normal lock reconciler may lock the private worktree. Its own
# lock is releasable during a claim, unlike an unrelated user's lock.
grep -F '{"owner":"supacode"}' "$concurrent/.git/worktrees/worktree/locked" >/dev/null
printf 'latest\n' > "$concurrent/tracked"
git -C "$concurrent" add tracked
git -C "$concurrent" commit -q -m latest
printf '#!/bin/sh\ntouch "$PWD/hook-fired"\n' > "$concurrent/.git/hooks/post-checkout"
chmod +x "$concurrent/.git/hooks/post-checkout"
claimed=$(cd "$concurrent" && SUPACODE_USE_PREWARM=1 PATH="$scratch/git-proxy:$PATH" "$wt" switch claimed --from main)
[ "$claimed" = "$concurrent/.worktrees/claimed" ]
cmp "$concurrent/tracked" "$claimed/tracked"
[ -f "$claimed/hook-fired" ]
[ ! -e "$concurrent/.git/supacode-prewarm/worktree" ]
[ "$(git -C "$claimed" branch --show-current)" = claimed ]
[ "$(git -C "$claimed" rev-parse HEAD)" = "$(git -C "$concurrent" rev-parse main)" ]
[ "$(git -C "$concurrent" worktree list --porcelain | grep -c '^worktree ')" = 2 ]
# Ignored user files also make the pool ineligible.
printf 'secret.ignored\n' > "$concurrent/.gitignore"
git -C "$concurrent" add .gitignore
git -C "$concurrent" commit -q -m ignore
(cd "$concurrent" && PATH="$scratch/git-proxy:$PATH" "$wt" __prewarm --from main)
git -C "$concurrent" worktree unlock "$concurrent/.git/supacode-prewarm/worktree"
git -C "$concurrent" worktree lock --reason 'user lock' "$concurrent/.git/supacode-prewarm/worktree"
locked_fallback=$(cd "$concurrent" && SUPACODE_USE_PREWARM=1 PATH="$scratch/git-proxy:$PATH" "$wt" switch locked-fallback --from main)
[ -f "$locked_fallback/tracked" ]
[ -f "$concurrent/.git/supacode-prewarm/worktree/tracked" ]
git -C "$concurrent" worktree unlock "$concurrent/.git/supacode-prewarm/worktree"
printf 'private\n' > "$concurrent/.git/supacode-prewarm/worktree/secret.ignored"
ignored=$(cd "$concurrent" && SUPACODE_USE_PREWARM=1 PATH="$scratch/git-proxy:$PATH" "$wt" switch ignored-fallback --from main)
[ -e "$ignored/tracked" ]
grep -Fx private "$concurrent/.git/supacode-prewarm/worktree/secret.ignored" >/dev/null
rm "$concurrent/.git/supacode-prewarm/worktree/secret.ignored"
printf 'local edits\n' > "$concurrent/.git/supacode-prewarm/worktree/tracked"
modified=$(cd "$concurrent" && SUPACODE_USE_PREWARM=1 PATH="$scratch/git-proxy:$PATH" "$wt" switch modified-fallback --from main)
cmp "$concurrent/tracked" "$modified/tracked"
grep -Fx 'local edits' "$concurrent/.git/supacode-prewarm/worktree/tracked" >/dev/null
# An occupied destination is never overwritten.
mkdir "$scratch/existing"
printf 'do not overwrite\n' > "$scratch/existing/sentinel"
if (cd "$concurrent" && SUPACODE_USE_PREWARM=1 PATH="$scratch/git-proxy:$PATH" "$wt" switch occupied --from main --path "$scratch/existing"); then
  echo 'occupied destination was accepted' >&2
  exit 1
fi
grep -Fx 'do not overwrite' "$scratch/existing/sentinel" >/dev/null
# An untracked file makes the pool ineligible; normal creation must leave it intact.
dirty=$(cd "$repo" && SUPACODE_USE_PREWARM=1 PATH="$scratch/git-proxy:$PATH" "$wt" switch fallback --from main)
[ -e "$dirty/tracked" ]
grep -Fx 'user content' "$pool/worktree/untracked" >/dev/null

# A failing post-checkout hook leaves a journal and preserves files it wrote.
hook_repo="$scratch/hook-failure"
git init -q -b main "$hook_repo"
git -C "$hook_repo" config user.name Test
git -C "$hook_repo" config user.email test@example.com
printf 'tracked\n' > "$hook_repo/tracked"
git -C "$hook_repo" add tracked
git -C "$hook_repo" commit -q -m initial
(cd "$hook_repo" && PATH="$scratch/git-proxy:$PATH" "$wt" __prewarm --from main)
printf '#!/bin/sh\nprintf "preserve hook data\\n" > "$PWD/hook-data"\nexit 1\n' > "$hook_repo/.git/hooks/post-checkout"
chmod +x "$hook_repo/.git/hooks/post-checkout"
if (cd "$hook_repo" && SUPACODE_USE_PREWARM=1 PATH="$scratch/git-proxy:$PATH" "$wt" switch failed-hook --from main); then
  echo 'failing hook was accepted' >&2
  exit 1
fi
hook_checkout="$hook_repo/.worktrees/failed-hook"
grep -Fx 'preserve hook data' "$hook_checkout/hook-data" >/dev/null
[ -f "$hook_repo/.git/supacode-prewarm/owner.json" ]
(cd "$hook_repo" && PATH="$scratch/git-proxy:$PATH" "$wt" __prewarm --from main)
grep -Fx 'preserve hook data' "$hook_checkout/hook-data" >/dev/null
[ "$(git -C "$hook_checkout" branch --show-current)" = failed-hook ]

# Simulate a process dying after the atomic move but before updating gitdir.
recovery="$scratch/recovery"
git init -q -b main "$recovery"
git -C "$recovery" config user.name Test
git -C "$recovery" config user.email test@example.com
printf 'tracked\n' > "$recovery/tracked"
git -C "$recovery" add tracked
git -C "$recovery" commit -q -m initial
(cd "$recovery" && PATH="$scratch/git-proxy:$PATH" "$wt" __prewarm --from main)
recovered="$scratch/recovered-checkout"
python3 - "$recovery/.git/supacode-prewarm/owner.json" "$recovered" <<'PYTHON'
import json, os, sys
marker_path, destination = sys.argv[1:]
with open(marker_path) as f: marker = json.load(f)
marker['claimDestination'] = destination
marker['claimBranch'] = 'interrupted'
with open(marker_path, 'w') as f: json.dump(marker, f)
os.rename(marker['worktree'], destination)
PYTHON
printf 'preserve me\n' > "$recovered/user-file"
(cd "$recovery" && PATH="$scratch/git-proxy:$PATH" "$wt" __prewarm --from main)
grep -Fx 'preserve me' "$recovered/user-file" >/dev/null
git -C "$recovered" status --porcelain | grep -F 'user-file' >/dev/null
[ "$(git -C "$recovery" worktree list --porcelain | grep -c '^worktree ')" = 3 ]
[ -f "$recovery/.git/supacode-prewarm/owner.json" ]

# A completed Git move can leave the journal behind after a crash. Recovery
# must recognize relative worktree links and leave the moved checkout intact.
relative="$scratch/relative-recovery"
git init -q -b main "$relative"
git -C "$relative" config user.name Test
git -C "$relative" config user.email test@example.com
git -C "$relative" config worktree.useRelativePaths true
printf 'tracked\n' > "$relative/tracked"
git -C "$relative" add tracked
git -C "$relative" commit -qm initial
(cd "$relative" && PATH="$scratch/git-proxy:$PATH" "$wt" __prewarm --from main)
relative_destination="$scratch/relative-recovered"
python3 - "$relative/.git/supacode-prewarm/owner.json" "$relative_destination" <<'PYTHON'
import json, sys
path, destination = sys.argv[1:]
with open(path) as f: marker = json.load(f)
marker['claimDestination'] = destination
marker['claimBranch'] = 'interrupted-relative'
with open(path, 'w') as f: json.dump(marker, f)
PYTHON
git -C "$relative" worktree unlock "$relative/.git/supacode-prewarm/worktree"
git -C "$relative" worktree move "$relative/.git/supacode-prewarm/worktree" "$relative_destination"
printf 'preserve relative\n' > "$relative_destination/user-file"
(cd "$relative" && PATH="$scratch/git-proxy:$PATH" "$wt" __prewarm --from main)
grep -Fx 'preserve relative' "$relative_destination/user-file" >/dev/null
git -C "$relative_destination" status --porcelain | grep -F user-file >/dev/null
[ -f "$relative/.git/supacode-prewarm/owner.json" ]

# A forged destination must not have its Git metadata rewritten.
forged="$scratch/forged"
git init -q -b main "$forged"
git -C "$forged" config user.name Test
git -C "$forged" config user.email test@example.com
printf 'tracked\n' > "$forged/tracked"
git -C "$forged" add tracked
git -C "$forged" commit -q -m initial
(cd "$forged" && PATH="$scratch/git-proxy:$PATH" "$wt" __prewarm --from main)
foreign="$scratch/foreign-checkout"
mkdir "$foreign"
printf 'gitdir: /not/the/owned/admin\n' > "$foreign/.git"
printf 'keep\n' > "$foreign/user-file"
python3 - "$forged/.git/supacode-prewarm/owner.json" "$foreign" <<'PYTHON'
import json, os, sys
marker_path, destination = sys.argv[1:]
with open(marker_path) as f: marker = json.load(f)
marker['claimDestination'] = destination
marker['claimBranch'] = 'interrupted'
with open(marker_path, 'w') as f: json.dump(marker, f)
os.rename(marker['worktree'], marker['worktree'] + '-preserved')
PYTHON
if (cd "$forged" && PATH="$scratch/git-proxy:$PATH" "$wt" __prewarm --from main); then
  echo 'forged recovery destination was accepted' >&2
  exit 1
fi
grep -Fx 'gitdir: /not/the/owned/admin' "$foreign/.git" >/dev/null
grep -Fx keep "$foreign/user-file" >/dev/null
[ -f "$forged/.git/supacode-prewarm/worktree-preserved/tracked" ]

unowned="$scratch/unowned"
git init -q -b main "$unowned"
git -C "$unowned" config user.name Test
git -C "$unowned" config user.email test@example.com
printf 'tracked\n' > "$unowned/tracked"
git -C "$unowned" add tracked
git -C "$unowned" commit -q -m initial
mkdir -p "$unowned/.git/supacode-prewarm/worktree"
printf 'keep\n' > "$unowned/.git/supacode-prewarm/worktree/user-file"
if (cd "$unowned" && PATH="$scratch/git-proxy:$PATH" "$wt" __prewarm --from main); then
  echo 'unowned checkout was accepted' >&2
  exit 1
fi
grep -Fx keep "$unowned/.git/supacode-prewarm/worktree/user-file" >/dev/null
symlinked="$scratch/symlinked"
git init -q -b main "$symlinked"
git -C "$symlinked" config user.name Test
git -C "$symlinked" config user.email test@example.com
printf 'tracked\n' > "$symlinked/tracked"
git -C "$symlinked" add tracked
git -C "$symlinked" commit -q -m initial
mkdir "$scratch/foreign"
printf 'keep\n' > "$scratch/foreign/user-file"
ln -s "$scratch/foreign" "$symlinked/.git/supacode-prewarm"
if (cd "$symlinked" && PATH="$scratch/git-proxy:$PATH" "$wt" __prewarm --from main); then
  echo 'symlinked pool was accepted' >&2
  exit 1
fi
grep -Fx keep "$scratch/foreign/user-file" >/dev/null
if git lfs version >/dev/null 2>&1; then
  lfs="$scratch/lfs"
  git init -q -b main "$lfs"
  git -C "$lfs" config user.name Test
  git -C "$lfs" config user.email test@example.com
  git -C "$lfs" lfs install --local >/dev/null
  git -C "$lfs" lfs track '*.asset' >/dev/null
  printf 'old lfs content\n' > "$lfs/test.asset"
  git -C "$lfs" add .gitattributes test.asset
  git -C "$lfs" commit -q -m initial
  (cd "$lfs" && "$wt" __prewarm --from main)
  printf 'new lfs content\n' > "$lfs/test.asset"
  git -C "$lfs" add test.asset
  git -C "$lfs" commit -q -m latest
  lfs_claim=$(cd "$lfs" && SUPACODE_USE_PREWARM=1 "$wt" switch lfs-claim --from main)
  cmp "$lfs/test.asset" "$lfs_claim/test.asset"
  [ ! -e "$lfs/.git/supacode-prewarm/worktree" ]
fi
printf 'Prewarm checkout created once, detached, with user files preserved.\n'
