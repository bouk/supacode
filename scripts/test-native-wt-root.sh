#!/usr/bin/env bash
set -euo pipefail

project_root=$(cd "$(dirname "$0")/.." && pwd -P)
export ROOT="$project_root/Resources/git-wt"
export WT_BIN="$project_root/.build/native-wt/wt"
scratch=$(mktemp -d "${TMPDIR:-/tmp}/supacode-native-wt-root.XXXXXXXX")
scratch=$(cd "$scratch" && pwd -P)
trap 'rm -rf "$scratch"' EXIT
export TMPDIR="$scratch/" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

# These cases exercise the candidate's implemented command without relying on
# another, as-yet-unported wt command to set up the fixture.
for test_case in root_output root_submodule bare_root; do
  printf 'Running %s\n' "$test_case"
  bash "$ROOT/tests/cases/$test_case.t"
done

repository="$scratch/main"
linked="$scratch/linked"
git init -q -b main "$repository"
git -C "$repository" config user.name Test
git -C "$repository" config user.email test@example.com
printf 'fixture\n' > "$repository/file"
git -C "$repository" add file
git -C "$repository" commit -q -m fixture
git -C "$repository" worktree add -q -b feature "$linked"
actual=$(cd "$linked" && "$WT_BIN" root)
if [ "$actual" != "$repository" ]; then
  printf 'error: linked-worktree root was %s, expected %s\n' "$actual" "$repository" >&2
  exit 1
fi
printf 'Native wt root tests passed\n'
