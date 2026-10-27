#!/usr/bin/env bash
set -euo pipefail

project_root=$(cd "$(dirname "$0")/.." && pwd -P)
export ROOT="$project_root/Resources/git-wt"
export WT_BIN="$project_root/.build/native-wt/wt"
scratch=$(mktemp -d "${TMPDIR:-/tmp}/supacode-native-wt-switch.XXXXXXXX")
scratch=$(cd "$scratch" && pwd -P)
trap 'rm -rf "$scratch"' EXIT
export TMPDIR="$scratch/" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

for test_case in \
  root_output root_from_worktree root_submodule bare_root \
  open_create open_existing open_branch_exists_no_worktree open_branch_exists_with_path \
  switch_default_from invalid_from_ref path_conflict switch_flags base_dir here \
  ls_output ls_flags ls_detached bare_ls ls_submodule_paths base_trailing_slash \
  rm_clean rm_dirty_force rm_flags rm_not_found rm_force_broken_worktree \
  exec_flags exec_runs exec_exit_code; do
  printf 'Running %s\n' "$test_case"
  bash "$ROOT/tests/cases/$test_case.t"
done

# The compatibility assertions also check that the static interface remains
# byte-for-byte identical, not merely that expected phrases are present.
for topic in general switch exec sync ls rm merge here base root completion; do
  if [ "$topic" = general ]; then set -- --help; else set -- help "$topic"; fi
  "$ROOT/wt" "$@" > "$scratch/reference"
  "$WT_BIN" "$@" > "$scratch/candidate"
  cmp "$scratch/reference" "$scratch/candidate"
done

# The app carries an upstream patch for broken nested worktree links. Ensure
# discovery never aliases the broken child to its parent repository.
repository="$scratch/broken-repo"
git init -q -b main "$repository"
git -C "$repository" config user.name Test
git -C "$repository" config user.email test@example.com
printf 'fixture\n' > "$repository/file"
git -C "$repository" add file
git -C "$repository" commit -q -m fixture
worktree=$(cd "$repository" && "$WT_BIN" switch broken --from main)
rm "$worktree/.git"
listing=$(cd "$repository" && "$WT_BIN" ls --json)
printf '%s\n' "$listing" | grep -F "\"path\":\"$worktree\"" >/dev/null

# Repository and worktree discovery must use libgit2, not a git subprocess.
mkdir -p "$scratch/no-git"
cat > "$scratch/no-git/git" <<'EOF'
#!/bin/sh
echo 'unexpected git subprocess' >&2
exit 99
EOF
chmod +x "$scratch/no-git/git"
(
  cd "$repository"
  PATH="$scratch/no-git:$PATH" "$WT_BIN" root >/dev/null
  PATH="$scratch/no-git:$PATH" "$WT_BIN" base >/dev/null
  PATH="$scratch/no-git:$PATH" "$WT_BIN" ls --json >/dev/null
  PATH="$scratch/no-git:$PATH" "$WT_BIN" __branches | grep -Fx main >/dev/null
)

export WT_TEST_GIT=$(command -v git)
mkdir "$scratch/git-proxy"
printf '#!/bin/sh\nexec "$WT_TEST_GIT" "$@"\n' > "$scratch/git-proxy/git"
chmod +x "$scratch/git-proxy/git"
repository="$scratch/native-copy"
git init -q -b main "$repository"
git -C "$repository" config user.name Test
git -C "$repository" config user.email test@example.com
printf 'fixture\n' > "$repository/file"
mkdir "$repository/progress-files"
for index in $(seq 1 2000); do printf 'content\n' > "$repository/progress-files/$index"; done
printf '*.slow filter=slow\n' > "$repository/.gitattributes"
printf 'filtered\n' > "$repository/a.slow"
git -C "$repository" config filter.slow.clean cat
git -C "$repository" config filter.slow.smudge 'sleep 3; cat'
git -C "$repository" add file
git -C "$repository" add progress-files
git -C "$repository" add .gitattributes a.slow
git -C "$repository" commit -q -m fixture
printf 'scratch/\n' >> "$repository/.git/info/exclude"
mkdir "$repository/scratch"
printf 'copied\n' > "$repository/scratch/value"
worktree=$(cd "$repository" && SUPACODE_WT_PROGRESS=1 PATH="$scratch/git-proxy:$PATH" "$WT_BIN" switch native-copy --from main 2> "$scratch/progress")
grep -E '^SUPACODE_CHECKOUT_PROGRESS [0-9]+ [1-9][0-9]*$' "$scratch/progress" >/dev/null || {
  echo 'native checkout did not report progress' >&2
  exit 1
}
(cd "$worktree" && PATH="$scratch/git-proxy:$PATH" "$WT_BIN" sync --copy-ignored)
cmp "$repository/scratch/value" "$worktree/scratch/value"
printf 'native merge\n' > "$worktree/merged"
git -C "$worktree" add merged
git -C "$worktree" commit -q -m 'native merge'
(cd "$worktree" && PATH="$scratch/git-proxy:$PATH" "$WT_BIN" merge main)
git -C "$repository" show main:merged | grep -Fx 'native merge' >/dev/null
# A clean worktree can also be removed through Git.
(cd "$repository" && PATH="$scratch/git-proxy:$PATH" "$WT_BIN" rm native-copy >/dev/null)
[ ! -e "$worktree" ] || { echo 'worktree was not removed' >&2; exit 1; }

# A local LFS fixture checks that the native creation path retains external
# checkout filters and hooks. No network or user repository is involved.
if git lfs version >/dev/null 2>&1; then
  repository="$scratch/lfs-repo"
  git init -q -b main "$repository"
  git -C "$repository" config user.name Test
  git -C "$repository" config user.email test@example.com
  git -C "$repository" lfs install --local >/dev/null
  git -C "$repository" lfs track '*.asset' >/dev/null
  printf 'lfs fixture contents\n' > "$repository/file.asset"
  git -C "$repository" add .gitattributes file.asset
  git -C "$repository" commit -q -m fixture
  printf '\ntouch .native-wt-hook-fired\n' >> "$repository/.git/hooks/post-checkout"
  worktree=$(cd "$repository" && "$WT_BIN" switch lfs-test --from main)
  cmp "$repository/file.asset" "$worktree/file.asset"
  [ -f "$worktree/.native-wt-hook-fired" ] || { echo 'post-checkout hook did not run' >&2; exit 1; }
  printf 'LFS and post-checkout hook passed\n'
else
  printf 'Skipping LFS fixture: git-lfs is unavailable\n' >&2
fi
