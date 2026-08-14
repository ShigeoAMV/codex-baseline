#!/bin/bash

# Shared Linux/WSL live-evaluation boundary. This file is sourced only after
# the dedicated credential has been captured into a non-exported shell value
# and removed from the process environment.

EVAL_SYSTEMD_RUN=/usr/bin/systemd-run
EVAL_SYSTEMCTL=/usr/bin/systemctl
EVAL_BWRAP=/usr/bin/bwrap
EVAL_TIMEOUT=/usr/bin/timeout
EVAL_PRLIMIT=/usr/bin/prlimit
EVAL_ENV=/usr/bin/env
EVAL_GREP=/usr/bin/grep
EVAL_FIND=/usr/bin/find
EVAL_HEAD=/usr/bin/head
EVAL_STAT=/usr/bin/stat
EVAL_REALPATH=/usr/bin/realpath
EVAL_CP=/usr/bin/cp
EVAL_CHMOD=/usr/bin/chmod
EVAL_BASH=/bin/bash
EVAL_SECRET_ONE=''
EVAL_SECRET_TWO=''
EVAL_DISCOVERY_PATH=${EVAL_DISCOVERY_PATH:-/usr/bin:/bin}

eval_validate_system_boundary() {
  local path resolved owner mode cursor
  for path in "$EVAL_SYSTEMD_RUN" "$EVAL_SYSTEMCTL" "$EVAL_BWRAP" "$EVAL_TIMEOUT" \
    "$EVAL_PRLIMIT" "$EVAL_ENV" "$EVAL_GREP" "$EVAL_FIND" "$EVAL_HEAD" \
    "$EVAL_STAT" "$EVAL_REALPATH" "$EVAL_CP" "$EVAL_CHMOD" "$EVAL_BASH"; do
    [[ $path == /* && -f $path && -x $path ]] || cb_die "required trusted system tool is unavailable: $path"
    owner=$($EVAL_STAT -c '%u' -- "$path") || cb_die 'cannot inspect system-tool link ownership'
    [[ $owner -eq 0 ]] || cb_die "system-tool link is not root-owned: $path"
    cursor=$path
    while [[ $cursor != / ]]; do
      cursor=$(dirname -- "$cursor")
      cursor=$($EVAL_REALPATH -e -- "$cursor") || cb_die 'cannot resolve system-tool ancestor'
      owner=$($EVAL_STAT -c '%u' -- "$cursor") || cb_die 'cannot inspect system-tool ancestor ownership'
      mode=$($EVAL_STAT -c '%a' -- "$cursor") || cb_die 'cannot inspect system-tool ancestor mode'
      [[ $owner -eq 0 && $((8#$mode & 0022)) -eq 0 ]] || cb_die "system-tool ancestor is mutable by an untrusted identity: $cursor"
    done
    resolved=$($EVAL_REALPATH -e -- "$path") || cb_die "cannot resolve trusted system tool: $path"
    owner=$($EVAL_STAT -c '%u' -- "$resolved") || cb_die 'cannot inspect trusted system tool ownership'
    mode=$($EVAL_STAT -c '%a' -- "$resolved") || cb_die 'cannot inspect trusted system tool mode'
    [[ $owner -eq 0 && $((8#$mode & 0022)) -eq 0 ]] || cb_die "system tool is not root-owned and mutation-safe: $path"
    cursor=$resolved
    while [[ $cursor != / ]]; do
      cursor=$(dirname -- "$cursor")
      owner=$($EVAL_STAT -c '%u' -- "$cursor") || cb_die 'cannot inspect system-tool ancestor ownership'
      mode=$($EVAL_STAT -c '%a' -- "$cursor") || cb_die 'cannot inspect system-tool ancestor mode'
      [[ $owner -eq 0 && $((8#$mode & 0022)) -eq 0 ]] || cb_die "system-tool ancestor is mutable by an untrusted identity: $cursor"
    done
  done
}

eval_validate_key() {
  local key=$1
  [[ -n $key ]] || cb_die 'a dedicated short-lived benchmark key is required'
  [[ $key != *$'\n'* && $key != *$'\r'* ]] || cb_die 'benchmark key contains an invalid line break'
  (( ${#key} <= 8192 )) || cb_die 'benchmark key exceeds the 8192-byte input limit'
}

eval_validate_expected_codex_hash() {
  local expected=$1
  [[ $expected =~ ^[0-9a-f]{64}$ ]] ||
    cb_die 'live evaluation requires CODEX_BASELINE_EXPECTED_CODEX_SHA256 as 64 lowercase hexadecimal characters'
}

eval_assert_no_link_ancestors() {
  local path=$1 normalized rel segment cursor=''
  [[ $path == /* ]] || cb_die 'evaluation path must be absolute'
  normalized=$($EVAL_REALPATH -ms -- "$path") || cb_die 'cannot normalize evaluation path'
  rel=${normalized#/}
  IFS='/' read -r -a _eval_segments <<<"$rel"
  for segment in "${_eval_segments[@]}"; do
    [[ -n $segment && $segment != . && $segment != .. ]] || cb_die 'unsafe evaluation path segment'
    cursor="$cursor/$segment"
    [[ ! -L $cursor ]] || cb_die 'symbolic-link evaluation path segment is forbidden'
  done
}

eval_prepare_output() {
  local source_root=$1 kind=$2 requested=$3 timestamp=$4
  local output state_root code_home installed=false
  if [[ -z $requested ]]; then
    state_root=${XDG_STATE_HOME:-"$HOME/.local/state"}
    [[ $state_root == /* ]] || cb_die 'XDG_STATE_HOME must be absolute for live evaluation'
    requested="$state_root/codex-baseline/$kind/$timestamp"
  fi
  output=$($EVAL_REALPATH -ms -- "$requested") || cb_die 'cannot normalize evaluation result directory'
  [[ $output != / && $output != "$HOME" ]] || cb_die 'unsafe evaluation result directory'
  eval_assert_no_link_ancestors "$output"
  code_home=${CODEX_HOME:-"$HOME/.codex"}
  if [[ $code_home == /* ]]; then
    case $source_root in
      "$($EVAL_REALPATH -ms -- "$code_home/codex-baseline/runtime")") installed=true ;;
    esac
  fi
  if [[ $installed == true ]]; then
    case $output in "$source_root"|"$source_root"/*) cb_die 'installed runtime results must be outside the managed runtime tree' ;; esac
  else
    case $output in
      "$source_root/benchmark-results"/*|"$source_root/behavior-results"/*) ;;
      "$source_root"|"$source_root"/*) cb_die 'result directory inside source must be below benchmark-results or behavior-results' ;;
    esac
  fi
  [[ ! -e $output && ! -L $output ]] || cb_die 'evaluation result directory already exists'
  cb_safe_mkdir_path "$output"
  eval_assert_no_link_ancestors "$output"
  printf '%s' "$output"
}

eval_assert_user_owned_path() {
  local path=$1 source_root=$2 current_uid owner mode cursor
  current_uid=$(/usr/bin/id -u)
  case $path in
    "$source_root"/*)
      [[ ${CODEX_BASELINE_TESTING:-0} == 1 ]] || cb_die 'evaluation executable resolves inside the mutable source tree'
      ;;
  esac
  cursor=$path
  while [[ $cursor != / ]]; do
    owner=$($EVAL_STAT -c '%u' -- "$cursor") || cb_die 'cannot inspect evaluation executable ownership'
    mode=$($EVAL_STAT -c '%a' -- "$cursor") || cb_die 'cannot inspect evaluation executable mode'
    [[ $owner -eq 0 || $owner -eq $current_uid ]] || cb_die 'evaluation executable path has an unexpected owner'
    [[ $((8#$mode & 0022)) -eq 0 ]] || cb_die 'evaluation executable path is group/other writable'
    cursor=$(dirname -- "$cursor")
  done
}

# Resolve a user-installed executable without ever exporting the credential,
# then freeze its bytes in a private file. The returned hash is suitable for a
# receipt; callers execute only the frozen path.
eval_freeze_executable() {
  local name=$1 source_root=$2 destination=$3 candidate resolved before after frozen mode
  # shellcheck disable=SC2016 # $1 is intentionally expanded by the child Bash.
  candidate=$($EVAL_ENV -i PATH="$EVAL_DISCOVERY_PATH" "$EVAL_BASH" -c 'type -P -- "$1"' _ "$name") ||
    cb_die "required evaluation executable not found: $name"
  resolved=$($EVAL_REALPATH -e -- "$candidate") || cb_die "cannot resolve evaluation executable: $name"
  [[ $resolved == /* && -f $resolved && ! -L $resolved && -x $resolved ]] || cb_die "unsafe evaluation executable: $name"
  eval_assert_user_owned_path "$resolved" "$source_root"
  before=$(cb_sha256_file "$resolved")
  $EVAL_CP --reflink=never -- "$resolved" "$destination" || cb_die "cannot freeze evaluation executable: $name"
  mode=$($EVAL_STAT -c '%a' -- "$resolved") || cb_die "cannot inspect evaluation executable mode: $name"
  $EVAL_CHMOD "$mode" -- "$destination" || cb_die "cannot set frozen evaluation executable mode: $name"
  after=$(cb_sha256_file "$resolved")
  frozen=$(cb_sha256_file "$destination")
  [[ $before == "$after" && $before == "$frozen" ]] || cb_die "evaluation executable changed while freezing: $name"
  printf '%s' "$frozen"
}

eval_exec_clean_environment() {
  local name
  while IFS= read -r name; do unset "$name" 2>/dev/null || true; done < <(compgen -e)
  while IFS= read -r name; do export -n -f "${name?}" 2>/dev/null || true; done < <(compgen -A function)
  exec "$@"
}

eval_git() {
  local repository=$1 isolated_home=$2
  shift 2
  mkdir -p -- "$isolated_home" "$isolated_home/empty-template"
  $EVAL_ENV -i HOME="$isolated_home" XDG_CONFIG_HOME="$isolated_home/config" PATH=/usr/bin:/bin LC_ALL=C \
    GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_PAGER=cat \
    /usr/bin/git -C "$repository" -c core.hooksPath=/dev/null -c init.templateDir="$isolated_home/empty-template" \
    -c core.fsmonitor=false -c commit.gpgsign=false -c tag.gpgsign=false "$@"
}

eval_source_is_installed_runtime() {
  local source_root=$1 code_home runtime
  code_home=${CODEX_HOME:-"$HOME/.codex"}
  [[ $code_home == /* ]] || return 1
  runtime=$($EVAL_REALPATH -ms -- "$code_home/codex-baseline/runtime") || return 1
  [[ $source_root == "$runtime" && -f $source_root/baseline/manifest.json &&
      ! -L $source_root/baseline/manifest.json ]]
}

# Source provenance must not execute repository-local Git helpers on the host.
# Freeze ordinary Git metadata before use, reject every configuration key that
# can launch a hook/filter/diff helper, and run the remaining read-only command
# in the same networkless cgroup/Bubblewrap class as other host verifiers.
eval_source_git() {
  local repository=$1 isolated_home=$2 live_git_dir snapshot_git_dir expected_file
  local before after snapshot_hash expected unsafe_config status=0
  local unsafe_pattern='^(include|includeif)\.|^filter\..*\.(clean|smudge|process|required)$|^diff\..*\.(command|textconv)$|^core\.(fsmonitor|hookspath)$|^extensions\.worktreeconfig$'
  local -a scoped_command
  shift 2
  [[ $repository == /* && -d $repository && ! -L $repository && -d $repository/.git && ! -L $repository/.git ]] ||
    cb_die 'live evaluation source must use an ordinary non-linked .git directory'
  live_git_dir=$($EVAL_REALPATH -e -- "$repository/.git") || cb_die 'cannot resolve source Git metadata'
  [[ $live_git_dir == "$repository/.git" ]] || cb_die 'source Git metadata resolves outside the source root'
  mkdir -p -- "$isolated_home"
  snapshot_git_dir="$isolated_home/git-metadata"
  expected_file="$isolated_home/git-metadata.sha256"
  if [[ ! -e $snapshot_git_dir && ! -e $expected_file ]]; then
    before=$(cb_tree_hash "$live_git_dir")
    mkdir -- "$snapshot_git_dir"
    cb_copy_source_tree "$live_git_dir" "$snapshot_git_dir"
    after=$(cb_tree_hash "$live_git_dir")
    snapshot_hash=$(cb_tree_hash "$snapshot_git_dir")
    [[ $before == "$after" && $before == "$snapshot_hash" ]] ||
      cb_die 'source Git metadata changed while creating its private snapshot'
    printf '%s\n' "$snapshot_hash" >"$expected_file"
  fi
  [[ -d $snapshot_git_dir && ! -L $snapshot_git_dir && -f $expected_file && ! -L $expected_file ]] ||
    cb_die 'incomplete private source Git metadata snapshot'
  IFS= read -r expected <"$expected_file" || cb_die 'cannot read private source Git metadata hash'
  [[ $expected =~ ^[0-9a-f]{64}$ && $(cb_tree_hash "$live_git_dir") == "$expected" &&
      $(cb_tree_hash "$snapshot_git_dir") == "$expected" ]] ||
    cb_die 'source Git metadata changed after it was frozen'
  if unsafe_config=$($EVAL_ENV -i HOME=/home PATH=/usr/bin:/bin LC_ALL=C GIT_CONFIG_NOSYSTEM=1 \
      GIT_CONFIG_GLOBAL=/dev/null /usr/bin/git --git-dir="$snapshot_git_dir" \
      config --local --no-includes --name-only --get-regexp "$unsafe_pattern" 2>/dev/null); then
    cb_die "source Git metadata enables executable configuration: ${unsafe_config%%$'\n'*}"
  else
    status=$?
    [[ $status -eq 1 ]] || cb_die 'cannot validate source Git configuration'
  fi
  if [[ $# -eq 1 && $1 == --status ]]; then
    # The script is intentionally expanded only inside the isolated Bash.
    # shellcheck disable=SC2016
    scoped_command=(/bin/bash -c '
      set -Eeuo pipefail
      git_command=(/usr/bin/git --git-dir=/git-metadata --work-tree=/source
        -c core.hooksPath=/dev/null -c core.fsmonitor=false -c core.pager=cat
        -c commit.gpgsign=false -c tag.gpgsign=false)
      revision=$("${git_command[@]}" rev-parse HEAD)
      dirty=false
      set +e
      "${git_command[@]}" diff --quiet --no-ext-diff --no-textconv --ignore-submodules HEAD --
      diff_status=$?
      set -e
      case $diff_status in 0) ;; 1) dirty=true ;; *) exit "$diff_status" ;; esac
      untracked=$("${git_command[@]}" ls-files --others --exclude-standard --directory)
      [[ -z $untracked ]] || dirty=true
      printf "%s\t%s\n" "$revision" "$dirty"
    ')
  else
    scoped_command=(/usr/bin/git --git-dir=/git-metadata --work-tree=/source -c core.hooksPath=/dev/null
      -c core.fsmonitor=false -c core.pager=cat -c commit.gpgsign=false -c tag.gpgsign=false "$@")
  fi
  status=0
  eval_run_scoped_command 20 \
    "$EVAL_ENV" -i HOME=/home PATH=/usr/bin:/bin LC_ALL=C GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
    GIT_OPTIONAL_LOCKS=0 GIT_PAGER=cat \
    "$EVAL_BWRAP" --unshare-all --unshare-user --disable-userns --die-with-parent --new-session --clearenv --cap-drop ALL \
    --ro-bind /usr /usr --symlink usr/bin /bin --symlink usr/lib /lib --symlink usr/lib64 /lib64 \
    --proc /proc --dev /dev --size 16777216 --tmpfs /tmp --dir /home \
    --ro-bind "$repository" /source --ro-bind "$snapshot_git_dir" /git-metadata \
    --setenv HOME /home --setenv PATH /usr/bin:/bin --setenv LC_ALL C --setenv GIT_CONFIG_NOSYSTEM 1 \
    --setenv GIT_CONFIG_GLOBAL /dev/null --setenv GIT_OPTIONAL_LOCKS 0 --setenv GIT_PAGER cat \
    "${scoped_command[@]}" || status=$?
  [[ $(cb_tree_hash "$live_git_dir") == "$expected" && $(cb_tree_hash "$snapshot_git_dir") == "$expected" ]] ||
    cb_die 'source Git metadata changed during a provenance command'
  return "$status"
}

# Installed wrappers intentionally bind receipts to the reduced runtime tree,
# not a Git checkout. They remain useful operational checks but are never the
# final release-evidence path. Every other live source must provide the frozen,
# isolated ordinary-Git provenance above.
eval_source_provenance() {
  local repository=$1 isolated_home=$2
  if eval_source_is_installed_runtime "$repository"; then
    printf '%s\t%s\n' unversioned null
    return
  fi
  eval_source_git "$repository" "$isolated_home" --status
}

eval_require_cgroup_boundary() {
  $EVAL_SYSTEMD_RUN --user --quiet --wait --collect --pipe --service-type=exec --expand-environment=no \
    -p MemoryMax=67108864 -p MemorySwapMax=0 -p TasksMax=16 -p CPUQuota=100% -p RuntimeMaxSec=10 \
    -p KillMode=control-group -p LimitCORE=0 -p LimitFSIZE=16777216 "$EVAL_BASH" -c 'exit 0' </dev/null >/dev/null 2>&1 ||
    cb_die 'live evaluation requires an operational systemd user cgroup boundary'
}

# The credential is transported only through the service stdin pipe. No
# background FIFO writer is created. The service survives a killed caller only
# until RuntimeMaxSec, while MemoryMax/TasksMax/CPUQuota aggregate the entire
# process tree. Bubblewrap adds byte-bounded tmpfs mounts for mutable storage.
eval_run_scoped_worker() {
  local runtime_seconds=$1
  shift
  printf '%s\n%s\n' "$EVAL_SECRET_ONE" "$EVAL_SECRET_TWO" |
    $EVAL_PRLIMIT --core=0 --fsize=16777216 -- \
      $EVAL_SYSTEMD_RUN --user --quiet --wait --collect --pipe --service-type=exec --expand-environment=no \
        -p MemoryMax=2147483648 -p MemorySwapMax=0 -p TasksMax=128 -p CPUQuota=200% \
        -p "RuntimeMaxSec=$runtime_seconds" -p KillMode=control-group -p LimitCORE=0 -p LimitFSIZE=16777216 \
        "$@"
}

# Codex tool commands may leave descendants behind after the main CLI process
# exits. Before inspecting or exporting mutable tmpfs content, stop and kill
# every remaining process in the private PID namespace except Bubblewrap's
# reaper (PID 1) and this launcher. Repeated STOP passes close a bounded fork
# race; TasksMax limits the namespace to 128 processes. A zombie cannot mutate
# artifacts, while any other survivor invalidates the run.
eval_quiesce_worker_processes() {
  local round entry pid details state self=$$ all_stopped all_dead
  [[ ${CODEX_BASELINE_EVAL_PID_NAMESPACE:-0} == 1 && $self -ne 1 ]] ||
    cb_die 'worker quiescence requires the declared private PID namespace'
  for ((round=0; round<128; round++)); do
    all_stopped=true
    for entry in /proc/[0-9]*; do
      [[ -e $entry ]] || continue
      pid=${entry##*/}
      [[ $pid == 1 || $pid == "$self" ]] && continue
      IFS= read -r details 2>/dev/null <"$entry/stat" || continue
      state=${details##*) }
      state=${state%% *}
      [[ $state == T || $state == t || $state == Z ]] && continue
      all_stopped=false
      kill -STOP "$pid" 2>/dev/null || true
    done
    [[ $all_stopped == true ]] && break
  done
  for ((round=0; round<128; round++)); do
    all_dead=true
    for entry in /proc/[0-9]*; do
      [[ -e $entry ]] || continue
      pid=${entry##*/}
      [[ $pid == 1 || $pid == "$self" ]] && continue
      IFS= read -r details 2>/dev/null <"$entry/stat" || continue
      state=${details##*) }
      state=${state%% *}
      [[ $state == Z ]] && continue
      all_dead=false
      kill -KILL "$pid" 2>/dev/null || true
    done
    [[ $all_dead == true ]] && break
  done
  for entry in /proc/[0-9]*; do
    [[ -e $entry ]] || continue
    pid=${entry##*/}
    [[ $pid == 1 || $pid == "$self" ]] && continue
    IFS= read -r details 2>/dev/null <"$entry/stat" || continue
    state=${details##*) }
    state=${state%% *}
    [[ $state == Z ]] || cb_die 'a live worker process survived namespace quiescence'
  done
}

eval_run_scoped_command() {
  local runtime_seconds=$1
  shift
  $EVAL_PRLIMIT --core=0 --fsize=16777216 -- \
    $EVAL_SYSTEMD_RUN --user --quiet --wait --collect --pipe --service-type=exec --expand-environment=no \
      -p MemoryMax=2147483648 -p MemorySwapMax=0 -p TasksMax=128 -p CPUQuota=200% \
      -p "RuntimeMaxSec=$runtime_seconds" -p KillMode=control-group -p LimitCORE=0 -p LimitFSIZE=16777216 \
      "$@" </dev/null
}

eval_start_scoped_service() {
  local unit=$1 runtime_seconds=$2
  shift 2
  $EVAL_SYSTEMD_RUN --user --quiet --collect --service-type=exec --expand-environment=no --unit "$unit" \
    -p MemoryMax=67108864 -p MemorySwapMax=0 -p TasksMax=8 -p CPUQuota=50% \
    -p "RuntimeMaxSec=$runtime_seconds" -p KillMode=control-group -p LimitCORE=0 -p LimitFSIZE=16777216 \
    "$@"
}

eval_stop_scoped_service() {
  local unit=$1
  $EVAL_SYSTEMCTL --user stop "$unit" >/dev/null 2>&1 || true
  $EVAL_SYSTEMCTL --user reset-failed "$unit" >/dev/null 2>&1 || true
}

eval_value_is_clean() {
  local value=$1
  [[ -z $EVAL_SECRET_ONE || $value != *"$EVAL_SECRET_ONE"* ]] || return 1
  [[ -z $EVAL_SECRET_TWO || $value != *"$EVAL_SECRET_TWO"* ]] || return 1
  ! printf '%s' "$value" | $EVAL_GREP -Eaq \
    '(sk-[A-Za-z0-9_-]{20,}|-----BEGIN ([A-Z ]+ )?PRIVATE KEY-----|eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,})'
}

eval_artifact_is_clean() {
  local file=$1 status
  [[ -f $file && ! -L $file && -r $file ]] || cb_die 'unsafe or missing evaluation artifact'
  if [[ -n $EVAL_SECRET_ONE ]]; then
    if printf '%s\n' "$EVAL_SECRET_ONE" | $EVAL_GREP -Fqa -f - -- "$file"; then
      cb_die 'active credential appeared in an evaluation artifact; run quarantined'
    else
      status=$?
      [[ $status -eq 1 ]] || cb_die 'cannot scan evaluation artifact for the active credential'
    fi
  fi
  if [[ -n $EVAL_SECRET_TWO ]]; then
    if printf '%s\n' "$EVAL_SECRET_TWO" | $EVAL_GREP -Fqa -f - -- "$file"; then
      cb_die 'canary secret appeared in an evaluation artifact; run quarantined'
    else
      status=$?
      [[ $status -eq 1 ]] || cb_die 'cannot scan evaluation artifact for the canary secret'
    fi
  fi
  if $EVAL_GREP -Eaq \
    '(sk-[A-Za-z0-9_-]{20,}|-----BEGIN ([A-Z ]+ )?PRIVATE KEY-----|eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,})' \
    -- "$file"; then
    cb_die 'possible credential material appeared in an evaluation artifact; run quarantined'
  else
    status=$?
    [[ $status -eq 1 ]] || cb_die 'cannot scan evaluation artifact for credential patterns'
  fi
}

eval_tree_is_clean() {
  local root=$1 max_entries=${2:-4096} max_bytes=${3:-268435456}
  local inventory entry rel bytes entries=0 total=0 depth status
  [[ -d $root && ! -L $root ]] || cb_die 'unsafe evaluation artifact tree'
  inventory=$(mktemp "${TMPDIR:-/tmp}/codex-baseline-eval-scan.XXXXXX")
  if (
    set -o pipefail
    $EVAL_TIMEOUT --foreground --signal=TERM --kill-after=2 30 \
      $EVAL_FIND -P "$root" -mindepth 1 -print0 | $EVAL_HEAD -c 16777217 >"$inventory"
  ); then
    status=0
  else
    status=$?
  fi
  [[ $status -eq 0 ]] || { rm -f -- "$inventory"; cb_die 'evaluation artifact enumeration failed or exceeded its bound'; }
  # Removing the private inventory on a fail-closed branch is safe while its
  # already-open read descriptor is active.
  # shellcheck disable=SC2094
  while IFS= read -r -d '' entry; do
    entries=$((entries + 1))
    (( entries <= max_entries )) || { rm -f -- "$inventory"; cb_die 'evaluation artifact entry limit exceeded'; }
    rel=${entry#"$root"/}
    [[ $rel != *$'\n'* && $rel != *$'\t'* ]] || { rm -f -- "$inventory"; cb_die 'evaluation artifact path contains unsupported control characters'; }
    eval_value_is_clean "$rel" || { rm -f -- "$inventory"; cb_die 'credential material appeared in an evaluation artifact path; run quarantined'; }
    depth=${rel//[^\/]/}
    (( ${#depth} < 16 )) || { rm -f -- "$inventory"; cb_die 'evaluation artifact depth limit exceeded'; }
    if [[ -d $entry && ! -L $entry ]]; then
      [[ -r $entry && -x $entry ]] || { rm -f -- "$inventory"; cb_die 'unreadable evaluation artifact directory'; }
    elif [[ -f $entry && ! -L $entry ]]; then
      bytes=$($EVAL_STAT -c '%s' -- "$entry") || { rm -f -- "$inventory"; cb_die 'cannot size evaluation artifact'; }
      total=$((total + bytes))
      (( total <= max_bytes )) || { rm -f -- "$inventory"; cb_die 'evaluation artifact byte limit exceeded'; }
      eval_artifact_is_clean "$entry"
    else
      rm -f -- "$inventory"
      cb_die 'linked or special evaluation artifact is forbidden'
    fi
  done <"$inventory"
  rm -f -- "$inventory"
}
