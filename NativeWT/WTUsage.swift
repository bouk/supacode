// Help and completion output derived from the pinned MIT-licensed git-wt.
enum WTUsage {
  static let general = #"""
wt - A simple git worktree sugar

Usage:
  wt [--base-dir <dir>] <command>

Global Flags:
  --base-dir <dir>  base dir override
  -h, --help        show help

Commands:
  switch <branch> create or open a workspace
  sw <branch>     alias for switch
  exec <branch>   open a workspace and run a command
  sync [from to]  copy files between worktrees
  ls              list workspaces
  rm <branch>     remove a workspace
  merge <target>  squash, rebase, and merge to target
  here            print current workspace branch
  base            print base dir
  root            print main worktree path
  completion      print shell completion
  help [command]  show help
"""#

  static let switchCommand = #"""
wt switch|sw <branch>

Flags:
  --from <ref>      base ref for new branch
  --path <dir>      explicit worktree path
  --fetch           fetch remotes before resolving --from
  --copy-all        copy all files to new worktree
  --copy-ignored    copy gitignored files to new worktree
  --copy-untracked  copy untracked files to new worktree
  --copy-modified   copy modified files to new worktree
  -f, --force       overwrite existing destination files
  -v, --verbose     print copy progress
  -h, --help        show help
"""#

  static let exec = #"""
wt exec <branch> -- <cmd...>

Flags:
  --from <ref>    base ref for new branch
  --path <dir>    explicit worktree path
  --fetch         fetch remotes before resolving --from
  -h, --help      show help
"""#

  static let sync = #"""
wt sync [<from-branch> <to-branch>]

Defaults to primary worktree -> current worktree.

Flags:
  --copy-all        copy all files
  --copy-ignored    copy gitignored files
  --copy-untracked  copy untracked files
  --copy-modified   copy modified files
  -f, --force       overwrite existing destination files
  -v, --verbose     print copy progress
  -n, --dry-run     show files that would be copied
  -h, --help        show help
"""#

  static let ls = #"""
wt ls

Flags:
  --plain         tab-delimited output
  --json          JSON output
  -h, --help      show help
"""#

  static let rm = #"""
wt rm <branch>

Flags:
  -f, --force     remove even if dirty
  -h, --help      show help
"""#

  static let merge = #"""
wt merge <target>

Squash, rebase, and fast-forward merge into target branch.

Flags:
  --no-squash   preserve individual commits
  --no-rebase   skip rebase (fail if not rebased)
  --no-commit   skip committing uncommitted changes
  -h, --help    show help
"""#

  static let here = #"""
wt here
"""#

  static let base = #"""
wt base
"""#

  static let root = #"""
wt root
"""#

  static let completion = #"""
wt completion <shell>

Shells:
  bash
  zsh
  fish
"""#

  static let bash = #"""
command -v wt >/dev/null 2>&1 || return 0

wt() {
  case "$1" in
    switch|sw)
      local i
      for i in "$@"; do
        case "$i" in
          -h|--help)
            command wt "$@"
            return $?
            ;;
        esac
      done
      local out path
      out=$(command wt "$@")
      local rc=$?
      path=$(printf '%s\n' "$out" | tail -n 1)
      if [[ $rc -eq 0 && -n "$path" && -d "$path" ]]; then
        if [[ "$out" != "$path" ]]; then
          printf '%s\n' "$out" | sed '$d'
        fi
        cd "$path"
      else
        [[ -n "$out" ]] && printf '%s\n' "$out"
        return $rc
      fi
      ;;
    *)
      command wt "$@"
      ;;
  esac
}

__wt_branches() {
  command wt __branches 2>/dev/null || return 0
}

_wt_complete() {
  local cur prev cmd
  cur="${COMP_WORDS[COMP_CWORD]}"
  prev="${COMP_WORDS[COMP_CWORD-1]}"
  cmd=""
  compopt +o default +o bashdefault 2>/dev/null
  local commands="switch sw exec sync ls rm merge here base root help completion"
  local flags=""
  local i
  local global_flags="--base-dir -h --help"
  for i in "${COMP_WORDS[@]}"; do
    if [ "$i" = "--" ]; then
      return 0
    fi
  done
  if [ "$prev" = "--base-dir" ]; then
    return 0
  fi
  i=1
  while [ "$i" -lt "$COMP_CWORD" ]; do
    local word="${COMP_WORDS[$i]}"
    case "$word" in
      --base-dir)
        i=$((i + 2))
        ;;
      --base-dir=*)
        i=$((i + 1))
        ;;
      -h|--help)
        i=$((i + 1))
        ;;
      --*)
        i=$((i + 1))
        ;;
      *)
        cmd="$word"
        break
        ;;
    esac
  done
  if [ -z "$cmd" ]; then
    COMPREPLY=( $(compgen -W "$global_flags $commands" -- "$cur") )
    return 0
  fi
  case "$cmd" in
    switch|sw)
      flags="--from --path --fetch --copy-all --copy-ignored --copy-untracked --copy-modified -f --force -v --verbose -h --help"
      case "$prev" in
        --from|--path) return 0 ;;
      esac
      COMPREPLY=( $(compgen -W "$flags $(__wt_branches)" -- "$cur") )
      ;;
    exec)
      flags="--from --path --fetch -h --help --"
      case "$prev" in
        --from|--path|--) return 0 ;;
      esac
      if [ "$COMP_CWORD" -eq 2 ]; then
        COMPREPLY=( $(compgen -W "$(__wt_branches)" -- "$cur") )
      else
        COMPREPLY=( $(compgen -W "$flags" -- "$cur") )
      fi
      ;;
    sync)
      flags="--copy-all --copy-ignored --copy-untracked --copy-modified -f --force -v --verbose -n --dry-run -h --help"
      COMPREPLY=( $(compgen -W "$flags $(__wt_branches)" -- "$cur") )
      ;;
    rm)
      flags="-f --force -h --help"
      COMPREPLY=( $(compgen -W "$flags $(__wt_branches)" -- "$cur") )
      ;;
    merge)
      flags="--no-squash --no-rebase --no-commit -h --help"
      COMPREPLY=( $(compgen -W "$flags $(__wt_branches)" -- "$cur") )
      ;;
    ls)
      flags="--plain --json -h --help"
      COMPREPLY=( $(compgen -W "$flags" -- "$cur") )
      ;;
    here|base|root)
      flags="-h --help"
      COMPREPLY=( $(compgen -W "$flags" -- "$cur") )
      ;;
    help)
      flags="switch sw exec sync ls rm merge here base root help completion"
      COMPREPLY=( $(compgen -W "$flags" -- "$cur") )
      ;;
    completion)
      flags="bash zsh fish"
      COMPREPLY=( $(compgen -W "$flags" -- "$cur") )
      ;;
  esac
}

complete -F _wt_complete wt
"""#

  static let zsh = #"""
command -v wt >/dev/null 2>&1 || return 0

wt() {
  case "$1" in
    switch|sw)
      local i
      for i in "$@"; do
        case "$i" in
          -h|--help)
            command wt "$@"
            return $?
            ;;
        esac
      done
      local out path
      out=$(command wt "$@")
      local rc=$?
      path=$(printf '%s\n' "$out" | tail -n 1)
      if [[ $rc -eq 0 && -n "$path" && -d "$path" ]]; then
        if [[ "$out" != "$path" ]]; then
          printf '%s\n' "$out" | sed '$d'
        fi
        cd "$path"
      else
        [[ -n "$out" ]] && printf '%s\n' "$out"
        return $rc
      fi
      ;;
    *)
      command wt "$@"
      ;;
  esac
}

__wt_branches() {
  command wt __branches 2>/dev/null || return 0
}

_wt() {
  local -a subcmds subdescs switch_flags switch_descs exec_flags exec_descs sync_flags sync_descs ls_flags ls_descs rm_flags rm_descs merge_flags merge_descs hb_flags hb_descs global_flags global_descs
  subcmds=(switch sw exec sync ls rm merge here base root help completion)
  subdescs=(
    "create or open a workspace"
    "alias for switch"
    "open a workspace and run a command"
    "copy files between worktrees"
    "list workspaces"
    "remove a workspace"
    "squash, rebase, and merge to target"
    "print current workspace branch"
    "print base dir"
    "print main worktree path"
    "show help"
    "print shell completion"
  )
  global_flags=(--base-dir -h --help)
  global_descs=("base dir override" "show help" "show help")
  switch_flags=(--from --path --fetch --copy-all --copy-ignored --copy-untracked --copy-modified -f --force -v --verbose -h --help)
  switch_descs=("base ref for new branch" "explicit worktree path" "fetch remotes before resolving --from" "copy all files to new worktree" "copy gitignored files to new worktree" "copy untracked files to new worktree" "copy modified files to new worktree" "overwrite existing destination files" "overwrite existing destination files" "print copy progress" "print copy progress" "show help" "show help")
  exec_flags=(--from --path --fetch -h --help --)
  exec_descs=("base ref for new branch" "explicit worktree path" "fetch remotes before resolving --from" "show help" "show help" "end of flags")
  sync_flags=(--copy-all --copy-ignored --copy-untracked --copy-modified -f --force -v --verbose -n --dry-run -h --help)
  sync_descs=("copy all files" "copy gitignored files" "copy untracked files" "copy modified files" "overwrite existing destination files" "overwrite existing destination files" "print copy progress" "print copy progress" "show files that would be copied" "show files that would be copied" "show help" "show help")
  ls_flags=(--plain --json -h --help)
  ls_descs=("tab-delimited output" "JSON output" "show help" "show help")
  rm_flags=(-f --force -h --help)
  rm_descs=("remove even if dirty" "remove even if dirty" "show help" "show help")
  merge_flags=(--no-squash --no-rebase --no-commit -h --help)
  merge_descs=("preserve individual commits" "skip rebase (fail if not rebased)" "skip committing uncommitted changes" "show help" "show help")
  hb_flags=(-h --help)
  hb_descs=("show help" "show help")
  if (( CURRENT == 2 )); then
    compadd -d global_descs -- $global_flags
    compadd -d subdescs -- $subcmds
    return 0
  fi
  local cmd=""
  local idx=2
  while (( idx <= CURRENT )); do
    local word=${words[idx]}
    case "$word" in
      --base-dir)
        idx=$((idx + 2))
        ;;
      --base-dir=*)
        idx=$((idx + 1))
        ;;
      -h|--help)
        idx=$((idx + 1))
        ;;
      --*)
        idx=$((idx + 1))
        ;;
      *)
        cmd=$word
        break
        ;;
    esac
  done
  if [[ "${words[CURRENT-1]}" == --base-dir ]]; then
    return 0
  fi
  if [[ -z "$cmd" ]]; then
    compadd -d global_descs -- $global_flags
    compadd -d subdescs -- $subcmds
    return 0
  fi
  case "$cmd" in
    switch|sw)
      if [[ "${words[CURRENT-1]}" == --from || "${words[CURRENT-1]}" == --path ]]; then
        return 0
      fi
      compadd -d switch_descs -- $switch_flags
      compadd -- ${(f)"$(__wt_branches)"}
      return 0
      ;;
    exec)
      if [[ "${words[CURRENT-1]}" == --from || "${words[CURRENT-1]}" == --path || "${words[CURRENT-1]}" == -- ]]; then
        return 0
      fi
      if (( CURRENT == 3 )); then
        compadd -- ${(f)"$(__wt_branches)"}
      else
        compadd -d exec_descs -- $exec_flags
      fi
      return 0
      ;;
    sync)
      compadd -d sync_descs -- $sync_flags
      compadd -- ${(f)"$(__wt_branches)"}
      return 0
      ;;
    rm)
      compadd -d rm_descs -- $rm_flags
      compadd -- ${(f)"$(__wt_branches)"}
      return 0
      ;;
    merge)
      compadd -d merge_descs -- $merge_flags
      compadd -- ${(f)"$(__wt_branches)"}
      return 0
      ;;
    ls)
      compadd -d ls_descs -- $ls_flags
      return 0
      ;;
    here|base|root)
      compadd -d hb_descs -- $hb_flags
      return 0
      ;;
    help)
      compadd -d subdescs -- $subcmds
      return 0
      ;;
    completion)
      compadd -- bash zsh fish
      return 0
      ;;
  esac
  return 0
}

compdef _wt wt
"""#

  static let fish = #"""
type -q wt; or return

set -g __wt_bin '__NATIVE_WT_EXECUTABLE__'

function wt
  if test "$argv[1]" = "switch" -o "$argv[1]" = "sw"
    if contains -- -h $argv; or contains -- --help $argv
      command "$__wt_bin" $argv
      return $status
    end
    set -g __wt_rc 0
    set -l out (begin
      command "$__wt_bin" $argv
      set -g __wt_rc $status
    end | string collect | string trim --right)
    set -l rc $__wt_rc
    set -e __wt_rc
    set -l out_lines (string split -- "\n" $out)
    set -l path $out_lines[-1]
    if test $rc -eq 0 -a -n "$path" -a -d "$path"
      if test (count $out_lines) -gt 1
        printf '%s\n' $out_lines[1..-2]
      end
      cd "$path"
    else
      test -n "$out"; and printf '%s\n' "$out"
      return $rc
    end
  else
    command "$__wt_bin" $argv
  end
end

function __wt_branches
  command "$__wt_bin" __branches 2>/dev/null
end

complete -c wt -f
complete -c wt -l base-dir -r -d 'base dir override'
complete -c wt -s h -l help -d 'show help'
complete -c wt -n '__fish_use_subcommand' -a switch -d 'create or open a workspace'
complete -c wt -n '__fish_use_subcommand' -a sw -d 'alias for switch'
complete -c wt -n '__fish_use_subcommand' -a exec -d 'open a workspace and run a command'
complete -c wt -n '__fish_use_subcommand' -a sync -d 'copy files between worktrees'
complete -c wt -n '__fish_use_subcommand' -a ls -d 'list workspaces'
complete -c wt -n '__fish_use_subcommand' -a rm -d 'remove a workspace'
complete -c wt -n '__fish_use_subcommand' -a merge -d 'squash, rebase, and merge to target'
complete -c wt -n '__fish_use_subcommand' -a here -d 'print current workspace branch'
complete -c wt -n '__fish_use_subcommand' -a base -d 'print base dir'
complete -c wt -n '__fish_use_subcommand' -a root -d 'print main worktree path'
complete -c wt -n '__fish_use_subcommand' -a help -d 'show help'
complete -c wt -n '__fish_use_subcommand' -a completion -d 'print shell completion'
complete -c wt -n '__fish_seen_subcommand_from switch sw exec sync rm merge' -a '(__wt_branches)'

complete -c wt -n '__fish_seen_subcommand_from switch sw exec' -l from -r -d 'base ref for new branch'
complete -c wt -n '__fish_seen_subcommand_from switch sw exec' -l path -r -d 'explicit worktree path'
complete -c wt -n '__fish_seen_subcommand_from switch sw exec' -l fetch -d 'fetch remotes before resolving --from'
complete -c wt -n '__fish_seen_subcommand_from switch sw exec' -s h -l help -d 'show help'
complete -c wt -n '__fish_seen_subcommand_from switch sw' -l copy-all -d 'copy all files to new worktree'
complete -c wt -n '__fish_seen_subcommand_from switch sw' -l copy-ignored -d 'copy gitignored files to new worktree'
complete -c wt -n '__fish_seen_subcommand_from switch sw' -l copy-untracked -d 'copy untracked files to new worktree'
complete -c wt -n '__fish_seen_subcommand_from switch sw' -l copy-modified -d 'copy modified files to new worktree'
complete -c wt -n '__fish_seen_subcommand_from switch sw' -s f -l force -d 'overwrite existing destination files'
complete -c wt -n '__fish_seen_subcommand_from switch sw' -s v -l verbose -d 'print copy progress'
complete -c wt -n '__fish_seen_subcommand_from sync' -l copy-all -d 'copy all files'
complete -c wt -n '__fish_seen_subcommand_from sync' -l copy-ignored -d 'copy gitignored files'
complete -c wt -n '__fish_seen_subcommand_from sync' -l copy-untracked -d 'copy untracked files'
complete -c wt -n '__fish_seen_subcommand_from sync' -l copy-modified -d 'copy modified files'
complete -c wt -n '__fish_seen_subcommand_from sync' -s f -l force -d 'overwrite existing destination files'
complete -c wt -n '__fish_seen_subcommand_from sync' -s v -l verbose -d 'print copy progress'
complete -c wt -n '__fish_seen_subcommand_from sync' -s n -l dry-run -d 'show files that would be copied'
complete -c wt -n '__fish_seen_subcommand_from sync' -s h -l help -d 'show help'

complete -c wt -n '__fish_seen_subcommand_from ls' -l plain -d 'tab-delimited output'
complete -c wt -n '__fish_seen_subcommand_from ls' -l json -d 'JSON output'
complete -c wt -n '__fish_seen_subcommand_from ls' -s h -l help -d 'show help'

complete -c wt -n '__fish_seen_subcommand_from rm' -s f -l force -d 'remove even if dirty'
complete -c wt -n '__fish_seen_subcommand_from rm' -s h -l help -d 'show help'

complete -c wt -n '__fish_seen_subcommand_from merge' -l no-squash -d 'preserve individual commits'
complete -c wt -n '__fish_seen_subcommand_from merge' -l no-rebase -d 'skip rebase (fail if not rebased)'
complete -c wt -n '__fish_seen_subcommand_from merge' -l no-commit -d 'skip committing uncommitted changes'
complete -c wt -n '__fish_seen_subcommand_from merge' -s h -l help -d 'show help'

complete -c wt -n '__fish_seen_subcommand_from help' -a switch -d 'create or open a workspace'
complete -c wt -n '__fish_seen_subcommand_from help' -a sw -d 'alias for switch'
complete -c wt -n '__fish_seen_subcommand_from help' -a exec -d 'open a workspace and run a command'
complete -c wt -n '__fish_seen_subcommand_from help' -a sync -d 'copy files between worktrees'
complete -c wt -n '__fish_seen_subcommand_from help' -a ls -d 'list workspaces'
complete -c wt -n '__fish_seen_subcommand_from help' -a rm -d 'remove a workspace'
complete -c wt -n '__fish_seen_subcommand_from help' -a merge -d 'squash, rebase, and merge to target'
complete -c wt -n '__fish_seen_subcommand_from help' -a here -d 'print current workspace branch'
complete -c wt -n '__fish_seen_subcommand_from help' -a base -d 'print base dir'
complete -c wt -n '__fish_seen_subcommand_from help' -a root -d 'print main worktree path'
complete -c wt -n '__fish_seen_subcommand_from help' -a help -d 'show help'
complete -c wt -n '__fish_seen_subcommand_from help' -a completion -d 'print shell completion'
complete -c wt -n '__fish_seen_subcommand_from completion' -a 'bash zsh fish'
"""#

}
