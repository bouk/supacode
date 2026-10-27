#!/usr/bin/env bash
set -euo pipefail

# Run the pinned upstream contract against a candidate executable. With no
# argument, run against the same patched shell script shipped by the app.
project_root=$(cd "$(dirname "$0")/.." && pwd -P)
export ROOT="$project_root/Resources/git-wt"
scratch=$(mktemp -d "${TMPDIR:-/tmp}/supacode-wt-contract.XXXXXXXX")
scratch=$(cd "$scratch" && pwd -P)
trap 'rm -rf "$scratch"' EXIT

if [ "$#" -gt 1 ]; then
  printf 'usage: %s [candidate-executable]\n' "$0" >&2
  exit 2
fi
if [ "$#" -eq 1 ]; then
  case "$1" in
    /*) WT_BIN="$1" ;;
    *) WT_BIN="$PWD/$1" ;;
  esac
else
  WT_BIN="$scratch/wt"
  cp "$ROOT/wt" "$WT_BIN"
  (cd "$scratch" && GIT_DIR=/dev/null git apply -p1 "$project_root/patches/git-wt/git-wt-canonical-worktree-path.patch")
fi
if [ ! -x "$WT_BIN" ]; then
  printf 'error: candidate is not executable: %s\n' "$WT_BIN" >&2
  exit 2
fi
export WT_BIN

# The upstream fixtures use mktemp and remove their own directories. Put all
# of them beneath our scratch directory as well, so even failed tests cannot
# leave worktrees or repositories behind.
export TMPDIR="$scratch/"
mkdir -p "$scratch/home"
export HOME="$scratch/home"
export XDG_CONFIG_HOME="$HOME/.config"
export XDG_STATE_HOME="$HOME/.local/state"
export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL=/dev/null
# Fish also loads machine-wide configuration in noninteractive shells. Run it
# without configuration so a PWD hook cannot change completion-test output.
if fish_path=$(command -v fish) && "$fish_path" --no-config -c true >/dev/null 2>&1; then
  mkdir -p "$scratch/bin"
  export WT_CONTRACT_FISH="$fish_path"
  cat > "$scratch/bin/fish" <<'EOF'
#!/usr/bin/env bash
exec "$WT_CONTRACT_FISH" --no-config \
  --init-command 'for handler in (functions --handlers-type variable | string match -r "^PWD +\K[^ ]+"); functions --erase $handler; end' "$@"
EOF
  chmod +x "$scratch/bin/fish"
  export PATH="$scratch/bin:$PATH"
fi
passed=0
failed=0
for test_case in "$ROOT"/tests/cases/*.t; do
  name=${test_case##*/}
  printf 'Running %s\n' "$name"
  if bash "$test_case"; then
    passed=$((passed + 1))
  else
    failed=$((failed + 1))
    printf 'FAILED: %s\n' "$name" >&2
  fi
done
printf 'wt compatibility: %d passed, %d failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
