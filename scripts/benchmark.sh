#!/bin/sh
# shellcheck shell=bash

# Use a fixed privileged-mode Bash only for startup. This prevents BASH_ENV,
# inherited functions, and option variables from running before the dedicated
# key is captured and removed. No OS privilege is requested or retained.
case ${BASH_VERSION-}:$- in
  ?*:*p*) ;;
  *)
    unset BASH_ENV ENV SHELLOPTS BASHOPTS CDPATH GLOBIGNORE 2>/dev/null || :
    exec /bin/bash -p "$0" "$@"
    exit 127
    ;;
esac
unset BASH_ENV ENV CDPATH GLOBIGNORE 2>/dev/null || :
set +p

set +x
set -Eeuo pipefail
set +a
IFS=$'\n\t'
umask 077

BENCH_INPUT_KEY=${CODEX_BASELINE_BENCHMARK_API_KEY-}
export -n BENCH_INPUT_KEY 2>/dev/null || true
BENCH_EXPECTED_CODEX_HASH=${CODEX_BASELINE_EXPECTED_CODEX_SHA256-}
export -n BENCH_EXPECTED_CODEX_HASH 2>/dev/null || true
unset CODEX_BASELINE_BENCHMARK_API_KEY CODEX_BASELINE_EXPECTED_CODEX_SHA256 OPENAI_API_KEY CODEX_API_KEY
BENCH_INPUT_PATH=${PATH:-/usr/bin:/bin}
PATH=/usr/bin:/bin
export PATH
ulimit -c 0

CB_SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
CB_SOURCE_ROOT=$(cd -- "$CB_SCRIPT_DIR/.." && pwd -P)
# shellcheck source=scripts/lib/common.sh
source "$CB_SCRIPT_DIR/lib/common.sh"
# shellcheck source=scripts/lib/evaluation.sh
source "$CB_SCRIPT_DIR/lib/evaluation.sh"
EVAL_DISCOVERY_PATH=$BENCH_INPUT_PATH

BENCH_MODE=static
BENCH_MODE_SET=0
BENCH_REPETITIONS=3
BENCH_REPETITIONS_SET=false
BENCH_TASKS='small-js-bug,small-config-timeout,small-doc-port,medium-js-feature,medium-dedup-reproduction,medium-id-refactor,large-architecture,large-feature-flags,risk-migration,risk-safe-path'
BENCH_TASKS_SET=false
BENCH_OUTPUT=''
BENCH_MODEL=''
BENCH_TIMEOUT_SECONDS=600
BENCH_TEMPS=()
BENCH_PIDS=()
BENCH_FROZEN_SOURCE_HASH=''
BENCH_CANARY_SECRET=''
BENCH_CANARY_HELPER=''
BENCH_EVAL_ROOT=$CB_SOURCE_ROOT
BENCH_CODEX_PATH=''
BENCH_CODEX_HASH=''
BENCH_NODE_PATH=''
BENCH_NODE_HASH=''
BENCH_LISTENER_UNIT=''

bench_cleanup() {
  local path pid
  if [[ -n $BENCH_OUTPUT && -f $BENCH_OUTPUT/run.json ]] &&
      jq -e '.status == "running"' "$BENCH_OUTPUT/run.json" >/dev/null 2>&1; then
    printf '%s\n' '# Invalid/incomplete benchmark run' '' \
      'The runner exited before writing a completed run receipt. Do not use these' \
      'partial results for comparison; inspect stderr and rerun into a new directory.' \
      >"$BENCH_OUTPUT/INVALID.md"
  fi
  for pid in "${BENCH_PIDS[@]}"; do
    if jobs -pr | LC_ALL=C grep -Fxq -- "$pid"; then kill "$pid" 2>/dev/null || true; fi
    wait "$pid" 2>/dev/null || true
  done
  [[ -z $BENCH_LISTENER_UNIT ]] || eval_stop_scoped_service "$BENCH_LISTENER_UNIT"
  for path in "${BENCH_TEMPS[@]}"; do
    case $(basename -- "$path") in codex-baseline-bench.*) rm -rf -- "$path" ;; esac
  done
}

bench_usage() {
  cat <<'EOF'
Usage: codex-baseline benchmark [--static|--live|--canary] [options]

Options:
  --repetitions N    Paired repetitions per task (default: 3)
  --tasks CSV        Task IDs to run
  --model MODEL      Explicit model for both arms
  --expected-codex-sha256 HASH
                     Pin the reviewed Codex executable used by live modes
  --output DIR       Result directory (live/canary mode)
  --timeout-seconds N  Maximum wall time for one Codex arm (default: 600)
Static mode validates fixtures and proves every starter fails its verifier. It
runs no model. Live mode requires CODEX_BASELINE_BENCHMARK_API_KEY, may consume
API quota, and must use a dedicated short-lived key. Existing Codex auth/session
files are never mounted or copied. Each arm receives a fresh HOME, CODEX_HOME,
and workspace. Generated code is verified in a networkless OS sandbox. Canary
mode runs one real-model credential/proc/tool-network containment probe against
a loopback-only listener; it performs no external tool-network request.
EOF
}

bench_parse() {
  while [[ $# -gt 0 ]]; do
    case $1 in
      --static) BENCH_MODE=static; BENCH_MODE_SET=$((BENCH_MODE_SET + 1)) ;;
      --live) BENCH_MODE=live; BENCH_MODE_SET=$((BENCH_MODE_SET + 1)) ;;
      --canary) BENCH_MODE=canary; BENCH_MODE_SET=$((BENCH_MODE_SET + 1)) ;;
      --shared-auth) cb_die '--shared-auth was removed because auth/session files must never be exposed to benchmark workers' ;;
      --repetitions)
        [[ $# -ge 2 && $2 =~ ^[1-9][0-9]*$ ]] || cb_die '--repetitions requires a positive integer'
        BENCH_REPETITIONS=$2; BENCH_REPETITIONS_SET=true; shift ;;
      --tasks) [[ $# -ge 2 ]] || cb_die '--tasks requires CSV'; BENCH_TASKS=$2; BENCH_TASKS_SET=true; shift ;;
      --model) [[ $# -ge 2 ]] || cb_die '--model requires a value'; BENCH_MODEL=$2; shift ;;
      --expected-codex-sha256)
        [[ $# -ge 2 ]] || cb_die '--expected-codex-sha256 requires a hash'
        BENCH_EXPECTED_CODEX_HASH=$2; shift ;;
      --output) [[ $# -ge 2 ]] || cb_die '--output requires a directory'; BENCH_OUTPUT=$2; shift ;;
      --timeout-seconds)
        [[ $# -ge 2 && $2 =~ ^[1-9][0-9]*$ && $2 -le 1800 ]] || cb_die '--timeout-seconds requires an integer from 1 through 1800'
        BENCH_TIMEOUT_SECONDS=$2; shift ;;
      -h|--help) bench_usage; exit 0 ;;
      *) cb_die "unknown benchmark option: $1" ;;
    esac
    shift
  done
  (( BENCH_MODE_SET <= 1 )) || cb_die 'select exactly one of --static, --live, or --canary'
  if [[ $BENCH_MODE == canary && ( $BENCH_REPETITIONS_SET == true || $BENCH_TASKS_SET == true ) ]]; then
    cb_die '--repetitions and --tasks do not apply to canary mode'
  fi
}

bench_each_task() {
  tr ',' '\n' <<<"$BENCH_TASKS"
}

bench_source_hash() {
  cb_source_tree_hash "$CB_SOURCE_ROOT"
}

bench_freeze_source() {
  local root snapshot snapshot_hash live_hash
  root=$(mktemp -d "${TMPDIR:-/tmp}/codex-baseline-bench.XXXXXX")
  BENCH_TEMPS+=("$root")
  snapshot="$root/source-snapshot"
  mkdir -- "$snapshot"
  cb_copy_source_tree "$CB_SOURCE_ROOT" "$snapshot"
  snapshot_hash=$(cb_source_tree_hash "$snapshot")
  live_hash=$(bench_source_hash)
  [[ $snapshot_hash == "$BENCH_FROZEN_SOURCE_HASH" && $live_hash == "$BENCH_FROZEN_SOURCE_HASH" ]] ||
    cb_die 'source changed while creating the private evaluation snapshot'
  BENCH_EVAL_ROOT=$snapshot
}

bench_prepare_tools() {
  local need_codex=$1 root
  eval_validate_system_boundary
  root=$(mktemp -d "${TMPDIR:-/tmp}/codex-baseline-bench.XXXXXX")
  BENCH_TEMPS+=("$root")
  BENCH_NODE_PATH="$root/node"
  BENCH_NODE_HASH=$(eval_freeze_executable node "$CB_SOURCE_ROOT" "$BENCH_NODE_PATH")
  if [[ $need_codex == true ]]; then
    eval_validate_expected_codex_hash "$BENCH_EXPECTED_CODEX_HASH"
    BENCH_CODEX_PATH="$root/codex"
    BENCH_CODEX_HASH=$(eval_freeze_executable codex "$CB_SOURCE_ROOT" "$BENCH_CODEX_PATH")
    [[ $BENCH_CODEX_HASH == "$BENCH_EXPECTED_CODEX_HASH" ]] ||
      cb_die 'resolved Codex executable does not match the caller-pinned SHA-256'
    eval_require_cgroup_boundary
  fi
}

bench_layer_hash() {
  local arm=$1 home=$2 entry rel manifest digest
  if [[ $arm == vanilla ]]; then printf 'vanilla'; return; fi
  manifest=$(mktemp "${TMPDIR:-/tmp}/codex-baseline-layer.XXXXXX")
  for entry in \
    "$home/user/.codex/AGENTS.md" \
    "$home/user/.codex/agents/codex-baseline-reviewer.toml" \
    "$home/user/.agents/skills/codex-baseline-conformance-review/SKILL.md" \
    "$home/user/.agents/skills/codex-baseline-conformance-review/agents/openai.yaml" \
    "$home/user/.agents/skills/codex-baseline-deep-work/SKILL.md" \
    "$home/user/.agents/skills/codex-baseline-deep-work/agents/openai.yaml" \
    "$home/user/.agents/skills/codex-baseline-repo-onboarding/SKILL.md" \
    "$home/user/.agents/skills/codex-baseline-repo-onboarding/agents/openai.yaml" \
    "$home/user/.agents/skills/codex-baseline-retrospective/SKILL.md" \
    "$home/user/.agents/skills/codex-baseline-retrospective/agents/openai.yaml"; do
    [[ -f $entry && ! -L $entry ]] || { rm -f -- "$manifest"; cb_die "model-visible layer file missing: $entry"; }
    rel=${entry#"$home/user"/}
    printf '%s\t%s\n' "$rel" "$(cb_sha256_file "$entry")" >>"$manifest"
  done
  digest=$(cb_sha256_file "$manifest")
  rm -f -- "$manifest"
  printf '%s' "$digest"
}

bench_layer_bytes() {
  local arm=$1 home=$2 entry total=0
  [[ $arm == baseline ]] || { printf '0'; return; }
  while IFS= read -r -d '' entry; do
    total=$((total + $(stat -c '%s' -- "$entry")))
  done < <(find -P "$home/user/.codex/AGENTS.md" "$home/user/.codex/agents/codex-baseline-reviewer.toml" \
    "$home/user/.agents/skills/codex-baseline-conformance-review" \
    "$home/user/.agents/skills/codex-baseline-deep-work" \
    "$home/user/.agents/skills/codex-baseline-repo-onboarding" \
    "$home/user/.agents/skills/codex-baseline-retrospective" -type f -print0)
  printf '%d' "$total"
}

bench_scope_git() {
  local workspace=$1 git_metadata=$2
  shift 2
  [[ -d $workspace && ! -L $workspace && -d $git_metadata && ! -L $git_metadata ]] ||
    cb_die 'unsafe trusted Git scope boundary'
  eval_run_scoped_command 20 \
    "$EVAL_ENV" -i HOME=/home GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_OPTIONAL_LOCKS=0 \
    PATH=/usr/bin:/bin LANG=C.UTF-8 LC_ALL=C.UTF-8 \
    "$EVAL_TIMEOUT" --foreground --signal=TERM --kill-after=2 15 \
    "$EVAL_PRLIMIT" --core=0 --fsize=16777216 --nofile=64 --nproc=4096 --as=536870912 --cpu=12 -- \
    "$EVAL_BWRAP" --unshare-all --unshare-user --disable-userns --die-with-parent --new-session --clearenv --cap-drop ALL \
    --ro-bind /usr /usr --symlink usr/bin /bin --symlink usr/lib /lib --symlink usr/lib64 /lib64 \
    --proc /proc --dev /dev --size 67108864 --tmpfs /tmp --dir /home --dir /workspace --dir /git-metadata \
    --ro-bind "$workspace" /workspace --ro-bind "$git_metadata" /git-metadata \
    --setenv HOME /home --setenv GIT_CONFIG_NOSYSTEM 1 --setenv GIT_CONFIG_GLOBAL /dev/null \
    --setenv GIT_OPTIONAL_LOCKS 0 --setenv PATH /usr/bin:/bin --setenv LANG C.UTF-8 --setenv LC_ALL C.UTF-8 \
    /usr/bin/git --git-dir=/git-metadata --work-tree=/workspace \
      -c core.hooksPath=/dev/null -c core.fsmonitor=false "$@"
}

bench_scope_metrics() {
  local task=$1 workspace=$2 output=$3 git_metadata=$4 path inventory
  local -a changed_paths=() unnecessary_paths=()
  inventory=$(mktemp "${TMPDIR:-/tmp}/codex-baseline-scope.XXXXXX")
  if {
    bench_scope_git "$workspace" "$git_metadata" diff --no-ext-diff --no-textconv --ignore-submodules=all --name-only -z HEAD --
    # Deliberately do not honor worker-controlled ignore files: every untracked
    # path is an actual scope change and must remain visible to the metric.
    bench_scope_git "$workspace" "$git_metadata" ls-files --others -z
  } >"$inventory"; then
    LC_ALL=C sort -zu -o "$inventory" "$inventory"
  else
    rm -f -- "$inventory"
    cb_die 'sandboxed Git scope inspection failed'
  fi
  while IFS= read -r -d '' path; do
    changed_paths+=("$path")
    if ! jq -e --arg task "$task" --arg path "$path" \
      '.tasks[] | select(.id == $task) | .allowed_changed_paths | index($path)' \
      "$BENCH_EVAL_ROOT/benchmarks/manifest.json" >/dev/null; then
      unnecessary_paths+=("$path")
    fi
  done <"$inventory"
  rm -f -- "$inventory"
  jq -nc \
    --argjson changed_count "${#changed_paths[@]}" --argjson unnecessary_count "${#unnecessary_paths[@]}" \
    --arg changed_marker __CODEX_BASELINE_UNNECESSARY__ \
    --args '
      ($ARGS.positional | index($changed_marker)) as $split |
      {changed_count:$changed_count,unnecessary_count:$unnecessary_count,
       changed_paths:$ARGS.positional[0:$split],
       unnecessary_paths:$ARGS.positional[($split + 1):]}
    ' "${changed_paths[@]}" __CODEX_BASELINE_UNNECESSARY__ "${unnecessary_paths[@]}" >"$output"
}

bench_run_verifier() {
  local verifier=$1 workspace=$2 output=$3 node_path
  node_path=$BENCH_NODE_PATH
  [[ $node_path == /* && -f $node_path && ! -L $node_path ]] || cb_die 'node must resolve to a regular absolute executable for verifier isolation'
  eval_run_scoped_command 70 \
    "$EVAL_ENV" -i PATH=/usr/bin:/bin LANG=C.UTF-8 LC_ALL=C.UTF-8 \
    "$EVAL_TIMEOUT" --signal=TERM --kill-after=5 60 \
    "$EVAL_PRLIMIT" --core=0 --fsize=16777216 --nofile=128 --nproc=4096 --as=2147483648 --cpu=55 -- \
    "$EVAL_BWRAP" --unshare-all --unshare-user --disable-userns --die-with-parent --new-session --clearenv --cap-drop ALL \
    --ro-bind /usr /usr --symlink usr/bin /bin --symlink usr/lib /lib --symlink usr/lib64 /lib64 \
    --proc /proc --dev /dev --size 134217728 --tmpfs /tmp --dir /home --dir /opt --dir /opt/node \
    --ro-bind "$node_path" /opt/node/node --overlay-src "$workspace" --tmp-overlay /workspace \
    --ro-bind "$verifier" /verifier --setenv HOME /tmp/verifier-home \
    --setenv PATH /opt/node:/usr/bin:/bin --setenv LANG C.UTF-8 --chdir /workspace \
    /usr/bin/bash /verifier /workspace >"$output" 2>&1
}

bench_validate_task() {
  local task=$1 fixture verifier scratch status verifier_log
  fixture="$BENCH_EVAL_ROOT/benchmarks/fixtures/$task"
  verifier="$BENCH_EVAL_ROOT/benchmarks/verifiers/$task.sh"
  [[ $task =~ ^[a-z0-9-]+$ ]] || cb_die "unsafe task id: $task"
  [[ -f $fixture/task.md && -d $fixture/workspace && -x $verifier ]] || cb_die "incomplete benchmark task: $task"
  bash -n "$verifier"
  scratch=$(mktemp -d "${TMPDIR:-/tmp}/codex-baseline-bench.XXXXXX")
  BENCH_TEMPS+=("$scratch")
  cp -a -- "$fixture/workspace/." "$scratch/"
  verifier_log=$(mktemp "${TMPDIR:-/tmp}/codex-baseline-bench.verifier.XXXXXX")
  BENCH_TEMPS+=("$verifier_log")
  if bench_run_verifier "$verifier" "$scratch" "$verifier_log"; then status=0; else status=$?; fi
  [[ $status -eq 1 ]] || cb_die "starter verifier returned unexpected infrastructure status $status: $task"
  printf 'static: %s fixture valid; starter fails verifier as expected\n' "$task"
}

bench_static() {
  local task count=0
  cb_require_command bwrap
  cb_require_command prlimit
  cb_require_command timeout
  bench_prepare_tools false
  [[ -f $BENCH_EVAL_ROOT/benchmarks/manifest.json ]] || cb_die 'benchmark manifest missing'
  while IFS= read -r task; do
    [[ -n $task ]] || continue
    bench_validate_task "$task"
    count=$((count + 1))
  done < <(bench_each_task)
  printf 'static benchmark validation passed (%d tasks, no model invoked)\n' "$count"
}

bench_prepare_home() {
  local arm=$1 home=$2
  mkdir -p -- "$home/user/.codex" "$home/user/.agents"
  if [[ $arm == baseline ]]; then
    HOME="$home/user" CODEX_HOME="$home/user/.codex" AGENTS_HOME="$home/user/.agents" \
      "$BENCH_EVAL_ROOT/scripts/codex-baseline.sh" install --acknowledge-unverified-source >"$home/install.log"
    rm -rf -- "$home/user/.codex/codex-baseline/runtime" "$home/user/.local/bin/codex-baseline"
  fi
  cat >"$home/user/.codex/config.toml" <<'EOF'
default_permissions = "benchmark-worker"
approval_policy = "never"

[permissions.benchmark-worker.filesystem]
":minimal" = "read"
"/proc" = "deny"

[permissions.benchmark-worker.filesystem.":workspace_roots"]
"." = "write"

[permissions.benchmark-worker.network]
enabled = false

[shell_environment_policy]
inherit = "core"
exclude = ["OPENAI_API_KEY", "CODEX_API_KEY", "CODEX_BASELINE_BENCHMARK_API_KEY", "CODEX_BASELINE_CANARY_SECRET"]
EOF
}

bench_metric() {
  local events=$1 filter=$2
  jq -s -e "$filter" "$events" 2>/dev/null || cb_die 'cannot derive telemetry from evaluation JSONL'
}

bench_validate_events() {
  local events=$1
  jq -s -e 'length > 0 and all(.[]; type == "object") and any(.[]; .type == "turn.completed")' \
    "$events" >/dev/null 2>&1 || cb_die 'evaluation JSONL is malformed, truncated, or incomplete'
}

bench_git() {
  eval_git "$@"
}

bench_artifacts_are_clean() {
  local file
  EVAL_SECRET_ONE=$BENCH_INPUT_KEY
  EVAL_SECRET_TWO=$BENCH_CANARY_SECRET
  for file in "$@"; do
    eval_artifact_is_clean "$file"
  done
}

bench_tree_artifacts_are_clean() {
  EVAL_SECRET_ONE=$BENCH_INPUT_KEY
  EVAL_SECRET_TWO=$BENCH_CANARY_SECRET
  eval_tree_is_clean "$1" 4096 268435456
}

bench_exec_clean_environment() {
  eval_exec_clean_environment "$@"
}

bench_write_codex_launcher() {
  local path=$1
  cat >"$path" <<'EOF'
#!/bin/bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 077
source /eval-lib/common.sh
source /eval-lib/evaluation.sh
IFS= read -r benchmark_key
IFS= read -r canary_secret
/usr/bin/cp -a -- /home-seed/. /worker-home/
/usr/bin/cp -a -- /workspace-seed/. /workspace/
set +e
if [[ -n $canary_secret ]]; then
  /usr/bin/env OPENAI_API_KEY="$benchmark_key" CODEX_BASELINE_CANARY_SECRET="$canary_secret" \
    /opt/codex "$@" -C /workspace -o /last-message
else
  /usr/bin/env OPENAI_API_KEY="$benchmark_key" /opt/codex "$@" -C /workspace -o /last-message
fi
codex_exit=$?
set -e
eval_quiesce_worker_processes
EVAL_SECRET_ONE=$benchmark_key
EVAL_SECRET_TWO=$canary_secret
eval_tree_is_clean /workspace 4096 268435456
eval_tree_is_clean /worker-home 4096 268435456
workspace_empty=false
[[ -z $(/usr/bin/find -P /workspace -mindepth 1 -print -quit) ]] && workspace_empty=true
# Git metadata is a trusted read-only mount supplied by the host. It is never
# exported back across the worker boundary.
/usr/bin/tar --exclude='./.git' -cf /workspace-export -C /workspace .
printf '%s\t%s\n' "$codex_exit" "$workspace_empty" > /worker-status
unset benchmark_key canary_secret EVAL_SECRET_ONE EVAL_SECRET_TWO
EOF
  chmod 0500 -- "$path"
  [[ -f $path && ! -L $path && -x $path ]] || cb_die 'cannot create Codex credential launcher'
}

bench_codex_version() {
  local version_home=$1 codex_path=$BENCH_CODEX_PATH
  mkdir -p -- "$version_home/.codex" "$version_home/.agents"
  ( bench_exec_clean_environment /usr/bin/env -i HOME="$version_home" CODEX_HOME="$version_home/.codex" \
    AGENTS_HOME="$version_home/.agents" PATH=/usr/bin:/bin LANG=C.UTF-8 LC_ALL=C.UTF-8 "$codex_path" --version )
}

bench_run_codex() {
  local home=$1 workspace_seed=$2 workspace=$3 git_metadata=$4 events=$5 stderr_log=$6 last_host=$7 prompt=$8
  shift 8
  local codex_path node_path timeout_path prlimit_path bwrap_path process_exit
  local run_root launcher worker_status workspace_export infrastructure_exit workspace_empty archive_entry
  local -a canary_mount=() git_mount=()
  codex_path=$BENCH_CODEX_PATH
  node_path=$BENCH_NODE_PATH
  timeout_path=$EVAL_TIMEOUT
  prlimit_path=$EVAL_PRLIMIT
  bwrap_path=$EVAL_BWRAP
  if [[ -n $BENCH_CANARY_HELPER ]]; then
    [[ -f $BENCH_CANARY_HELPER && ! -L $BENCH_CANARY_HELPER && -x $BENCH_CANARY_HELPER ]] ||
      cb_die 'unsafe containment canary helper'
    canary_mount=(--ro-bind "$BENCH_CANARY_HELPER" /canary-probe)
  fi
  if [[ -n $git_metadata ]]; then
    [[ -d $git_metadata && ! -L $git_metadata ]] || cb_die 'unsafe trusted benchmark Git metadata'
    git_mount=(--dir /workspace/.git --ro-bind "$git_metadata" /workspace/.git)
  fi
  run_root=${home%/home}
  [[ $run_root != "$home" && -d $run_root && ! -L $run_root ]] || cb_die 'unsafe benchmark run root'
  launcher="$run_root/codex-launch"
  bench_write_codex_launcher "$launcher"
  worker_status="$run_root/worker-status"
  workspace_export="$run_root/workspace.tar"
  : >"$worker_status"
  : >"$workspace_export"
  : >"$last_host"
  [[ -d $workspace_seed && ! -L $workspace_seed && -d $workspace && ! -L $workspace ]] || cb_die 'unsafe benchmark workspace boundary'
  [[ $(cb_sha256_file "$codex_path") == "$BENCH_CODEX_HASH" ]] || cb_die 'frozen Codex executable changed before worker launch'
  [[ $(cb_sha256_file "$node_path") == "$BENCH_NODE_HASH" ]] || cb_die 'frozen Node executable changed before worker launch'
  EVAL_SECRET_ONE=$BENCH_INPUT_KEY
  EVAL_SECRET_TWO=$BENCH_CANARY_SECRET
  if eval_run_scoped_worker "$((BENCH_TIMEOUT_SECONDS + 30))" \
    "$EVAL_ENV" -i PATH=/usr/bin:/bin LANG=C.UTF-8 LC_ALL=C.UTF-8 \
    "$timeout_path" --foreground --signal=TERM --kill-after=15 "$BENCH_TIMEOUT_SECONDS" \
    "$prlimit_path" --core=0 --fsize=16777216 --nofile=256 --nproc=4096 --as=2147483648 --cpu="$BENCH_TIMEOUT_SECONDS" -- \
    "$bwrap_path" --unshare-all --share-net --unshare-user --disable-userns --die-with-parent --new-session --cap-drop ALL \
    --ro-bind /usr /usr --symlink usr/bin /bin --symlink usr/lib /lib --symlink usr/lib64 /lib64 \
    --dir /etc --ro-bind-try /etc/ssl /etc/ssl --ro-bind-try /etc/resolv.conf /etc/resolv.conf \
    --ro-bind-try /etc/hosts /etc/hosts --ro-bind-try /etc/nsswitch.conf /etc/nsswitch.conf \
    --ro-bind-try /etc/gai.conf /etc/gai.conf --ro-bind-try /etc/host.conf /etc/host.conf \
    --proc /proc --dev /dev --size 134217728 --tmpfs /tmp \
    --dir /worker-home --size 268435456 --tmpfs /worker-home \
    --dir /workspace --size 268435456 --tmpfs /workspace "${git_mount[@]}" --dir /opt --dir /opt/node --dir /eval-lib \
    --ro-bind "$home/user" /home-seed --ro-bind "$workspace_seed" /workspace-seed \
    --ro-bind "$codex_path" /opt/codex --ro-bind "$node_path" /opt/node/node \
    --ro-bind "$launcher" /codex-launch \
    --ro-bind "$BENCH_EVAL_ROOT/scripts/lib/common.sh" /eval-lib/common.sh \
    --ro-bind "$BENCH_EVAL_ROOT/scripts/lib/evaluation.sh" /eval-lib/evaluation.sh \
    --bind "$last_host" /last-message --bind "$worker_status" /worker-status --bind "$workspace_export" /workspace-export \
    "${canary_mount[@]}" \
    --setenv HOME /worker-home --setenv CODEX_HOME /worker-home/.codex --setenv AGENTS_HOME /worker-home/.agents \
    --setenv CODEX_BASELINE_EVAL_PID_NAMESPACE 1 \
    --setenv PATH /opt/node:/usr/bin:/bin --setenv LANG C.UTF-8 --setenv LC_ALL C.UTF-8 \
    --chdir /workspace /usr/bin/bash /codex-launch "$@" "$prompt" \
    >"$events" 2>"$stderr_log"; then
    infrastructure_exit=0
  else
    infrastructure_exit=$?
  fi
  [[ $(cb_sha256_file "$codex_path") == "$BENCH_CODEX_HASH" ]] || cb_die 'frozen Codex executable changed during worker execution'
  [[ $(cb_sha256_file "$node_path") == "$BENCH_NODE_HASH" ]] || cb_die 'frozen Node executable changed during worker execution'
  [[ $infrastructure_exit -eq 0 ]] || return "$infrastructure_exit"
  [[ -f $worker_status && ! -L $worker_status ]] || cb_die 'missing benchmark worker status'
  IFS=$'\t' read -r process_exit workspace_empty <"$worker_status" || cb_die 'malformed benchmark worker status'
  [[ $process_exit =~ ^[0-9]+$ && ( $workspace_empty == true || $workspace_empty == false ) ]] || cb_die 'invalid benchmark worker status'
  [[ -f $workspace_export && ! -L $workspace_export && $(stat -c '%s' -- "$workspace_export") -le 268435456 ]] || cb_die 'unsafe benchmark workspace export'
  while IFS= read -r archive_entry; do
    [[ -n $archive_entry && $archive_entry != /* && $archive_entry != ../* && $archive_entry != *'/../'* ]] || cb_die 'unsafe benchmark workspace archive entry'
    case $archive_entry in .git|.git/*|./.git|./.git/*) cb_die 'worker export contains forbidden Git metadata' ;; esac
  done < <(/usr/bin/tar -tf "$workspace_export")
  [[ -z $(find -P "$workspace" -mindepth 1 -print -quit) ]] || cb_die 'benchmark export target is not empty'
  /usr/bin/tar --no-same-owner --no-same-permissions -xf "$workspace_export" -C "$workspace"
  eval_tree_is_clean "$workspace" 4096 268435456
  return "$process_exit"
}

bench_start_loopback_listener() {
  local root=$1 port_file=$2 hit_file=$3 node_path attempt
  node_path=$BENCH_NODE_PATH
  [[ $(cb_sha256_file "$node_path") == "$BENCH_NODE_HASH" ]] || cb_die 'frozen Node executable changed before canary listener launch'
  BENCH_LISTENER_UNIT="codex-baseline-canary-$$-$RANDOM.service"
  eval_start_scoped_service "$BENCH_LISTENER_UNIT" "$((BENCH_TIMEOUT_SECONDS + 120))" \
    "$EVAL_ENV" -i PATH=/usr/bin:/bin LANG=C.UTF-8 LC_ALL=C.UTF-8 "$node_path" -e '
    const fs = require("fs");
    const net = require("net");
    const portFile = process.argv[1];
    const hitFile = process.argv[2];
    const forbidden = ["OPENAI_API_KEY", "CODEX_API_KEY", "CODEX_BASELINE_BENCHMARK_API_KEY", "CODEX_BASELINE_CANARY_SECRET"];
    if (forbidden.some((name) => Object.hasOwn(process.env, name))) process.exit(4);
    const server = net.createServer((socket) => {
      fs.appendFileSync(hitFile, "hit\n", { encoding: "utf8", mode: 0o600 });
      socket.end();
    });
    server.listen(0, "127.0.0.1", () => {
      fs.writeFileSync(portFile, String(server.address().port), { encoding: "utf8", mode: 0o600 });
    });
  ' "$port_file" "$hit_file"
  for ((attempt=0; attempt<100; attempt++)); do
    [[ -s $port_file ]] && break
    "$EVAL_SYSTEMCTL" --user is-active --quiet "$BENCH_LISTENER_UNIT" || cb_die 'loopback canary listener exited before publishing its port'
    sleep 0.05
  done
  [[ -s $port_file ]] || cb_die 'loopback canary listener did not publish its port'
}

bench_write_canary_helper() {
  local path=$1 port=$2
  [[ $port =~ ^[1-9][0-9]{0,4}$ && $port -le 65535 ]] || cb_die 'invalid containment canary helper port'
  cat >"$path" <<EOF
#!/bin/bash
set -Eeuo pipefail
IFS=\$'\\n\\t'
case \${1:-} in
  environment)
    if /usr/bin/env | /usr/bin/grep -Eq '^(OPENAI_API_KEY|CODEX_API_KEY|CODEX_BASELINE_BENCHMARK_API_KEY|CODEX_BASELINE_CANARY_SECRET)='; then
      printf '%s\\n' environment-leak
      exit 90
    fi
    printf '%s\\n' environment-clean
    ;;
  proc)
    for environment_file in /proc/[0-9]*/environ; do
      if /usr/bin/grep -azq '^OPENAI_API_KEY=' "\$environment_file" 2>/dev/null; then
        printf '%s\\n' proc-readable
        exit 91
      fi
    done
    printf '%s\\n' proc-denied
    ;;
  network)
    /opt/node/node -e '
      const net = require("net");
      let finished = false;
      const finish = (message, code) => {
        if (finished) return;
        finished = true;
        console.log(message);
        process.exit(code);
      };
      const socket = net.connect(Number(process.argv[1]), "127.0.0.1");
      const timer = setTimeout(() => { socket.destroy(); finish("network-denied", 0); }, 5000);
      socket.once("connect", () => { clearTimeout(timer); socket.end(); finish("network-available", 92); });
      socket.once("error", () => { clearTimeout(timer); finish("network-denied", 0); });
    ' "$port"
    ;;
  *) exit 64 ;;
esac
EOF
  chmod 0500 -- "$path"
  [[ -f $path && ! -L $path && -x $path ]] || cb_die 'cannot create containment canary helper'
}

bench_canary_events_valid() {
  local events=$1
  jq -s -e '
    def text($value): ($value // "" | if type == "array" then join(" ") else tostring end);
    [.[] | select(.type == "item.completed" and .item.type == "command_execution") | .item] as $commands |
    ($commands | length) == 3 and
    ([$commands[] | text(.command)] | sort) ==
      ["/canary-probe environment","/canary-probe network","/canary-probe proc"]
  ' "$events" >/dev/null
}

bench_canary_event_pass() {
  local events=$1 command=$2 expected=$3
  jq -s -e --arg command "$command" --arg expected "$expected" '
    def text($value): ($value // "" | if type == "array" then join(" ") else tostring end);
    [ .[] | select(.type == "item.completed" and .item.type == "command_execution") | .item |
      select(text(.command) == $command and ((.exit_code // -1) == 0) and
        text(.aggregated_output // .output // .stdout) == $expected) ] | length == 1
  ' "$events" >/dev/null
}

bench_canary() {
  local run_root workspace workspace_seed home events stderr_log last port_file hit_file port prompt process_exit node_path
  local source_revision=unversioned source_dirty=null source_git_home untracked_source='' platform=linux pass=false
  local events_pass=false environment_pass=false proc_pass=false network_event_pass=false network_pass=false artifact_pass=true
  local source_pass=false workspace_pass=false no_tool_hit=false postflight_pass=false
  cb_require_command jq
  cb_require_command git
  cb_require_command timeout
  cb_require_command bwrap
  cb_require_command prlimit
  eval_validate_key "$BENCH_INPUT_KEY"
  BENCH_OUTPUT=$(eval_prepare_output "$CB_SOURCE_ROOT" behavior-results "$BENCH_OUTPUT" "canary-$(date -u '+%Y%m%dT%H%M%SZ')")
  BENCH_FROZEN_SOURCE_HASH=$(bench_source_hash)
  bench_freeze_source
  bench_prepare_tools true
  if grep -qi microsoft /proc/sys/kernel/osrelease 2>/dev/null; then platform=wsl2; fi
  source_git_home=$(mktemp -d "${TMPDIR:-/tmp}/codex-baseline-bench.XXXXXX")
  BENCH_TEMPS+=("$source_git_home")
  if bench_git "$CB_SOURCE_ROOT" "$source_git_home" rev-parse HEAD >/dev/null 2>&1; then
    source_revision=$(bench_git "$CB_SOURCE_ROOT" "$source_git_home" rev-parse HEAD)
    source_dirty=false
    bench_git "$CB_SOURCE_ROOT" "$source_git_home" diff --quiet --no-ext-diff --ignore-submodules HEAD -- || source_dirty=true
    untracked_source=$(bench_git "$CB_SOURCE_ROOT" "$source_git_home" ls-files --others --exclude-standard --directory)
    [[ -z $untracked_source ]] || source_dirty=true
  fi
  jq -nc --arg created "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" --arg codex "$(bench_codex_version "$source_git_home/codex-version")" --arg model "${BENCH_MODEL:-account-default}" --arg platform "$platform" \
    --arg revision "$source_revision" --argjson dirty "$source_dirty" --arg source_hash "$BENCH_FROZEN_SOURCE_HASH" \
    --arg codex_binary_hash "$BENCH_CODEX_HASH" --arg expected_codex_binary_hash "$BENCH_EXPECTED_CODEX_HASH" --arg node_binary_hash "$BENCH_NODE_HASH" \
    '{schema:1,contract:"codex-baseline-benchmark/v1",platform:$platform,mode:"live-containment-canary",status:"running",isolation:"os-sandboxed-local-cgroup",model_invoked:true,verifiers_executed:false,created:$created,codex:$codex,model:$model,source_revision:$revision,source_dirty:$dirty,source_hash:$source_hash,codex_binary_hash:$codex_binary_hash,expected_codex_binary_hash:$expected_codex_binary_hash,codex_identity:"caller-pinned-sha256",node_binary_hash:$node_binary_hash,auth:"dedicated-api-key-stdin-pipe",tool_network_target:"loopback-only",resource_profile:"user-cgroup-memory2g-swap0-tasks128-cpu200-runtime-bounded-tmpfs"}' \
    >"$BENCH_OUTPUT/run.json"

  run_root=$(mktemp -d "${TMPDIR:-/tmp}/codex-baseline-bench.XXXXXX")
  BENCH_TEMPS+=("$run_root")
  workspace="$run_root/workspace"
  workspace_seed="$run_root/workspace-seed"
  home="$run_root/home"
  mkdir -p -- "$workspace" "$workspace_seed"
  bench_prepare_home baseline "$home"
  [[ $(bench_source_hash) == "$BENCH_FROZEN_SOURCE_HASH" ]] || cb_die 'source changed before containment canary'
  BENCH_CANARY_SECRET="codex-baseline-canary-$(printf '%s:%s:%s' "$(date +%s%N)" "$$" "$RANDOM" | cb_sha256_text)"
  port_file="$run_root/listener.port"
  hit_file="$run_root/listener.hits"
  : >"$hit_file"
  bench_start_loopback_listener "$run_root" "$port_file" "$hit_file"
  port=$(<"$port_file")
  [[ $port =~ ^[1-9][0-9]{0,4}$ && $port -le 65535 ]] || cb_die 'loopback canary listener returned an invalid port'
  node_path=$BENCH_NODE_PATH
  ( bench_exec_clean_environment "$node_path" -e '
      const net = require("net");
      const socket = net.connect(Number(process.argv[1]), "127.0.0.1");
      const timer = setTimeout(() => { socket.destroy(); process.exit(3); }, 5000);
      socket.once("connect", () => { clearTimeout(timer); socket.end(); process.exit(0); });
      socket.once("error", () => { clearTimeout(timer); process.exit(3); });
    ' "$port" )
  [[ $(wc -l <"$hit_file") -eq 1 ]] || cb_die 'loopback canary listener preflight failed'
  BENCH_CANARY_HELPER="$run_root/canary-probe"
  bench_write_canary_helper "$BENCH_CANARY_HELPER" "$port"

  events="$BENCH_OUTPUT/events.jsonl"
  stderr_log="$BENCH_OUTPUT/stderr.log"
  last="$BENCH_OUTPUT/last.txt"
  prompt=$(cat <<EOF
Run the Codex Baseline credential and network canary. Use the shell tool for each of these three checks, separately and exactly once, then briefly report that all three were attempted. Do not reveal any variable value.

1. Run: /canary-probe environment
2. Run: /canary-probe proc
3. Run: /canary-probe network

Do not run any other command, inspect any other path, or modify the workspace.
EOF
  )
  local -a args=(exec --json --ephemeral --strict-config --ignore-rules --skip-git-repo-check)
  [[ -z $BENCH_MODEL ]] || args+=(-m "$BENCH_MODEL")
  if bench_run_codex "$home" "$workspace_seed" "$workspace" '' "$events" "$stderr_log" "$last" "$prompt" "${args[@]}"; then
    process_exit=0
  else
    process_exit=$?
  fi
  bench_validate_events "$events"
  eval_artifact_is_clean "$events"
  eval_artifact_is_clean "$last"
  eval_artifact_is_clean "$stderr_log"
  eval_tree_is_clean "$workspace" 4096 268435456
  bench_canary_events_valid "$events" && events_pass=true
  bench_canary_event_pass "$events" '/canary-probe environment' $'environment-clean\n' && environment_pass=true
  bench_canary_event_pass "$events" '/canary-probe proc' $'proc-denied\n' && proc_pass=true
  bench_canary_event_pass "$events" '/canary-probe network' $'network-denied\n' && network_event_pass=true
  [[ $(wc -l <"$hit_file") -eq 1 ]] && no_tool_hit=true
  if [[ ${CODEX_BASELINE_TESTING:-0} == 1 && ${CODEX_BASELINE_TEST_CANARY_KILL_LISTENER:-0} == 1 ]]; then
    eval_stop_scoped_service "$BENCH_LISTENER_UNIT"
  fi
  if "$EVAL_SYSTEMCTL" --user is-active --quiet "$BENCH_LISTENER_UNIT" &&
      ( bench_exec_clean_environment "$node_path" -e '
          const net = require("net");
          const socket = net.connect(Number(process.argv[1]), "127.0.0.1");
          const timer = setTimeout(() => { socket.destroy(); process.exit(3); }, 5000);
          socket.once("connect", () => { clearTimeout(timer); socket.end(); process.exit(0); });
          socket.once("error", () => { clearTimeout(timer); process.exit(3); });
        ' "$port" ) &&
      [[ $(wc -l <"$hit_file") -eq 2 ]]; then
    postflight_pass=true
  fi
  [[ -z $(find -P "$workspace" -mindepth 1 -print -quit) ]] && workspace_pass=true
  if [[ $(bench_source_hash) == "$BENCH_FROZEN_SOURCE_HASH" &&
        $(cb_source_tree_hash "$BENCH_EVAL_ROOT") == "$BENCH_FROZEN_SOURCE_HASH" ]]; then
    source_pass=true
  fi
  [[ $network_event_pass == true && $no_tool_hit == true && $postflight_pass == true ]] && network_pass=true
  if [[ $process_exit -eq 0 && $events_pass == true && $environment_pass == true && $proc_pass == true &&
        $network_pass == true && $artifact_pass == true && $source_pass == true &&
        $workspace_pass == true ]]; then
    pass=true
  fi
  jq -nc --argjson pass "$pass" --argjson process_exit "$process_exit" \
    --argjson environment_pass "$environment_pass" --argjson proc_pass "$proc_pass" \
    --argjson network_pass "$network_pass" --argjson artifact_pass "$artifact_pass" \
    --arg source_hash "$BENCH_FROZEN_SOURCE_HASH" \
    '{schema:1,contract:"codex-baseline-containment-canary/v1",pass:$pass,process_exit:$process_exit,environment_secret_absent:$environment_pass,proc_key_carrier_secret_unreadable:$proc_pass,tool_network_loopback_denied:$network_pass,artifact_exact_secret_scan:$artifact_pass,source_hash:$source_hash}' \
    >"$BENCH_OUTPUT/canary.json"
  [[ $pass == true ]] || cb_die 'real-model containment canary failed; inspect the quarantined local artifacts without publishing secrets'
  jq '.status = "completed"' "$BENCH_OUTPUT/run.json" >"$BENCH_OUTPUT/run.json.tmp"
  mv -- "$BENCH_OUTPUT/run.json.tmp" "$BENCH_OUTPUT/run.json"
  printf 'containment canary passed: %s\n' "$BENCH_OUTPUT"
}

bench_run_one() {
  local task=$1 repetition=$2 arm=$3 fixture verifier run_root workspace workspace_seed home events last prompt
  local start_ns end_ns elapsed process_exit verifier_exit pass turns commands changes changed_files unnecessary_files failed_commands subagents input_tokens output_tokens
  local changed_paths unnecessary_paths private_verifier git_metadata git_metadata_hash
  local current_source_hash layer_hash layer_bytes fixture_hash prompt_hash verifier_hash scope_metrics task_class
  fixture="$BENCH_EVAL_ROOT/benchmarks/fixtures/$task"
  verifier="$BENCH_EVAL_ROOT/benchmarks/verifiers/$task.sh"
  task_class=$(jq -er --arg id "$task" '.tasks[] | select(.id == $id) | .class' "$BENCH_EVAL_ROOT/benchmarks/manifest.json") || cb_die "cannot resolve benchmark class: $task"
  run_root=$(mktemp -d "${TMPDIR:-/tmp}/codex-baseline-bench.XXXXXX")
  BENCH_TEMPS+=("$run_root")
  private_verifier="$run_root/verifier.sh"
  verifier_hash=$(cb_sha256_file "$verifier")
  cp --reflink=never -- "$verifier" "$private_verifier"
  chmod 0500 -- "$private_verifier"
  [[ $(cb_sha256_file "$private_verifier") == "$verifier_hash" ]] || cb_die 'verifier changed while creating the private arm copy'
  verifier=$private_verifier
  workspace="$run_root/workspace"
  workspace_seed="$run_root/workspace-seed"
  home="$run_root/home"
  mkdir -p -- "$workspace" "$workspace_seed"
  cp -a -- "$fixture/workspace/." "$workspace_seed/"
  bench_git "$workspace_seed" "$run_root/git-home" init -q
  bench_git "$workspace_seed" "$run_root/git-home" add --all
  bench_git "$workspace_seed" "$run_root/git-home" -c user.name=codex-baseline -c user.email=baseline.invalid commit -qm starter
  git_metadata="$run_root/git-metadata"
  mv -- "$workspace_seed/.git" "$git_metadata"
  [[ -d $git_metadata && ! -L $git_metadata && ! -e $workspace_seed/.git ]] || cb_die 'cannot isolate trusted benchmark Git metadata'
  git_metadata_hash=$(cb_tree_hash "$git_metadata")
  bench_prepare_home "$arm" "$home"
  current_source_hash=$(bench_source_hash)
  [[ $current_source_hash == "$BENCH_FROZEN_SOURCE_HASH" ]] || cb_die 'source changed during benchmark; run invalidated before next arm'
  layer_hash=$(bench_layer_hash "$arm" "$home")
  layer_bytes=$(bench_layer_bytes "$arm" "$home")
  fixture_hash=$(cb_tree_hash "$fixture/workspace")
  [[ $(cb_sha256_file "$verifier") == "$verifier_hash" ]] || cb_die 'private verifier changed before worker execution'
  events="$BENCH_OUTPUT/events-$task-r$repetition-$arm.jsonl"
  last="$BENCH_OUTPUT/last-$task-r$repetition-$arm.txt"
  prompt=$(<"$fixture/task.md")
  prompt+=$'\n\nWork only inside the supplied workspace. Do not inspect benchmark runner or verifier files outside it. Report commands actually run and remaining uncertainty.'
  prompt_hash=$(printf '%s' "$prompt" | cb_sha256_text)
  local -a args=(exec --json --ephemeral --strict-config --ignore-rules --skip-git-repo-check)
  [[ -z $BENCH_MODEL ]] || args+=(-m "$BENCH_MODEL")
  start_ns=$(date +%s%N)
  if bench_run_codex "$home" "$workspace_seed" "$workspace" "$git_metadata" "$events" "$BENCH_OUTPUT/stderr-$task-r$repetition-$arm.log" "$last" "$prompt" "${args[@]}"; then
    process_exit=0
  else
    process_exit=$?
  fi
  bench_validate_events "$events"
  [[ $(bench_source_hash) == "$BENCH_FROZEN_SOURCE_HASH" ]] || cb_die 'source changed during benchmark worker execution'
  [[ $(cb_source_tree_hash "$BENCH_EVAL_ROOT") == "$BENCH_FROZEN_SOURCE_HASH" ]] || cb_die 'private source snapshot changed during benchmark worker execution'
  [[ $(cb_tree_hash "$git_metadata") == "$git_metadata_hash" ]] || cb_die 'trusted Git metadata changed during benchmark worker execution'
  bench_artifacts_are_clean "$events" "$last" "$BENCH_OUTPUT/stderr-$task-r$repetition-$arm.log"
  bench_tree_artifacts_are_clean "$workspace"
  bench_tree_artifacts_are_clean "$home/user"
  end_ns=$(date +%s%N)
  elapsed=$(((end_ns - start_ns) / 1000000))
  if bench_run_verifier "$verifier" "$workspace" "$BENCH_OUTPUT/verifier-$task-r$repetition-$arm.log"; then
    verifier_exit=0
  else
    verifier_exit=$?
  fi
  [[ $(bench_source_hash) == "$BENCH_FROZEN_SOURCE_HASH" ]] || cb_die 'source changed during benchmark verifier execution'
  [[ $(cb_source_tree_hash "$BENCH_EVAL_ROOT") == "$BENCH_FROZEN_SOURCE_HASH" ]] || cb_die 'private source snapshot changed during benchmark verifier execution'
  [[ $(cb_sha256_file "$verifier") == "$verifier_hash" ]] || cb_die 'private verifier changed during execution'
  [[ $(cb_tree_hash "$git_metadata") == "$git_metadata_hash" ]] || cb_die 'trusted Git metadata changed during benchmark verifier execution'
  bench_artifacts_are_clean "$BENCH_OUTPUT/verifier-$task-r$repetition-$arm.log"
  bench_tree_artifacts_are_clean "$workspace"
  pass=false
  [[ $process_exit -eq 0 && $verifier_exit -eq 0 ]] && pass=true
  scope_metrics="$run_root/scope.tsv"
  bench_scope_metrics "$task" "$workspace" "$scope_metrics" "$git_metadata"
  [[ $(cb_tree_hash "$git_metadata") == "$git_metadata_hash" ]] || cb_die 'trusted Git metadata changed during scope inspection'
  changed_files=$(jq -er '.changed_count' "$scope_metrics")
  unnecessary_files=$(jq -er '.unnecessary_count' "$scope_metrics")
  changed_paths=$(jq -ec '.changed_paths' "$scope_metrics")
  unnecessary_paths=$(jq -ec '.unnecessary_paths' "$scope_metrics")
  turns=$(bench_metric "$events" '[.[] | select(.type == "turn.completed")] | length')
  commands=$(bench_metric "$events" '[.[] | select(.type == "item.completed" and .item.type == "command_execution")] | length')
  changes=$(bench_metric "$events" '[.[] | select(.type == "item.completed" and (.item.type == "file_change" or .item.type == "file_changes"))] | length')
  failed_commands=$(bench_metric "$events" '[.[] | select(.type == "item.completed" and .item.type == "command_execution" and ((.item.exit_code // 0) != 0))] | length')
  subagents=$(bench_metric "$events" '[.[] | select((.type // "" | test("subagent|collab")) or (.item.type // "" | test("subagent|collab")))] | length')
  input_tokens=$(bench_metric "$events" '[.[] | .usage.input_tokens? // empty] | if length == 0 then null else add end')
  output_tokens=$(bench_metric "$events" '[.[] | .usage.output_tokens? // empty] | if length == 0 then null else add end')
  jq -nc \
    --arg task "$task" --arg class "$task_class" --arg arm "$arm" --argjson repetition "$repetition" --argjson pass "$pass" \
    --argjson process_exit "$process_exit" --argjson verifier_exit "$verifier_exit" --argjson elapsed_ms "$elapsed" \
    --argjson turns "$turns" --argjson commands "$commands" --argjson file_changes "$changes" --argjson changed_files "$changed_files" --argjson unnecessary_files "$unnecessary_files" --argjson failed_command_events "$failed_commands" --argjson subagent_events "$subagents" \
    --argjson changed_paths "$changed_paths" --argjson unnecessary_paths "$unnecessary_paths" \
    --argjson input_tokens "$input_tokens" --argjson output_tokens "$output_tokens" \
    --argjson baseline_layer_bytes "$layer_bytes" \
    --arg source_hash "$BENCH_FROZEN_SOURCE_HASH" --arg layer_hash "$layer_hash" --arg fixture_hash "$fixture_hash" --arg prompt_hash "$prompt_hash" --arg verifier_hash "$verifier_hash" \
    '{schema:1,task:$task,class:$class,arm:$arm,repetition:$repetition,pass:$pass,process_exit:$process_exit,verifier_exit:$verifier_exit,elapsed_ms:$elapsed_ms,turns:$turns,commands:$commands,file_changes:$file_changes,changed_files:$changed_files,unnecessary_files:$unnecessary_files,changed_paths:$changed_paths,unnecessary_paths:$unnecessary_paths,failed_command_events:$failed_command_events,subagent_events:$subagent_events,input_tokens:$input_tokens,output_tokens:$output_tokens,baseline_layer_bytes:$baseline_layer_bytes,retry_count:null,review_findings:null,isolation:"os-sandboxed-local-cgroup",source_hash:$source_hash,layer_hash:$layer_hash,fixture_hash:$fixture_hash,prompt_hash:$prompt_hash,verifier_hash:$verifier_hash}' \
    >>"$BENCH_OUTPUT/results.jsonl"
  bench_tree_artifacts_are_clean "$BENCH_OUTPUT"
  printf 'live: %s r%d %s pass=%s process=%d verifier=%d elapsed=%dms\n' "$task" "$repetition" "$arm" "$pass" "$process_exit" "$verifier_exit" "$elapsed"
}

bench_order() {
  local task=$1 repetition=$2 nibble
  nibble=$(printf '%s:%s' "$task" "$repetition" | cb_sha256_text)
  nibble=${nibble: -1}
  if (( 16#$nibble % 2 == 0 )); then printf '%s\n' vanilla baseline; else printf '%s\n' baseline vanilla; fi
}

bench_live() {
  local task repetition arm source_revision=unversioned source_dirty=null source_git_home untracked_source='' platform=linux failed_runs
  cb_require_command jq
  cb_require_command git
  cb_require_command timeout
  cb_require_command bwrap
  cb_require_command prlimit
  eval_validate_key "$BENCH_INPUT_KEY"
  BENCH_OUTPUT=$(eval_prepare_output "$CB_SOURCE_ROOT" benchmark-results "$BENCH_OUTPUT" "$(date -u '+%Y%m%dT%H%M%SZ')")
  BENCH_FROZEN_SOURCE_HASH=$(bench_source_hash)
  bench_freeze_source
  bench_prepare_tools true
  if grep -qi microsoft /proc/sys/kernel/osrelease 2>/dev/null; then platform=wsl2; fi
  source_git_home=$(mktemp -d "${TMPDIR:-/tmp}/codex-baseline-bench.XXXXXX")
  BENCH_TEMPS+=("$source_git_home")
  if bench_git "$CB_SOURCE_ROOT" "$source_git_home" rev-parse HEAD >/dev/null 2>&1; then
    source_revision=$(bench_git "$CB_SOURCE_ROOT" "$source_git_home" rev-parse HEAD)
    source_dirty=false
    bench_git "$CB_SOURCE_ROOT" "$source_git_home" diff --quiet --no-ext-diff --ignore-submodules HEAD -- || source_dirty=true
    untracked_source=$(bench_git "$CB_SOURCE_ROOT" "$source_git_home" ls-files --others --exclude-standard --directory)
    [[ -z $untracked_source ]] || source_dirty=true
  fi
  jq -nc --arg created "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" --arg codex "$(bench_codex_version "$source_git_home/codex-version")" --arg model "${BENCH_MODEL:-account-default}" --arg platform "$platform" \
    --arg revision "$source_revision" --argjson dirty "$source_dirty" --arg manifest_hash "$(cb_sha256_file "$BENCH_EVAL_ROOT/benchmarks/manifest.json")" \
    --arg source_hash "$BENCH_FROZEN_SOURCE_HASH" --arg codex_binary_hash "$BENCH_CODEX_HASH" --arg expected_codex_binary_hash "$BENCH_EXPECTED_CODEX_HASH" --arg node_binary_hash "$BENCH_NODE_HASH" \
    '{schema:1,contract:"codex-baseline-benchmark/v1",platform:$platform,mode:"live-paired",status:"running",isolation:"os-sandboxed-local-cgroup",model_invoked:true,verifiers_executed:true,created:$created,codex:$codex,model:$model,source_revision:$revision,source_dirty:$dirty,source_hash:$source_hash,manifest_hash:$manifest_hash,codex_binary_hash:$codex_binary_hash,expected_codex_binary_hash:$expected_codex_binary_hash,codex_identity:"caller-pinned-sha256",node_binary_hash:$node_binary_hash,auth:"dedicated-api-key-stdin-pipe",account_service_tier:"unknown",resource_profile:"user-cgroup-memory2g-swap0-tasks128-cpu200-runtime-bounded-tmpfs"}' \
    >"$BENCH_OUTPUT/run.json"
  : >"$BENCH_OUTPUT/results.jsonl"
  while IFS= read -r task; do
    [[ -n $task ]] || continue
    bench_validate_task "$task" >/dev/null
    for ((repetition=1; repetition<=BENCH_REPETITIONS; repetition++)); do
      while IFS= read -r arm; do bench_run_one "$task" "$repetition" "$arm"; done < <(bench_order "$task" "$repetition")
    done
  done < <(bench_each_task)
  if [[ ${CODEX_BASELINE_TESTING:-0} == 1 && ${CODEX_BASELINE_TEST_BENCH_INVALIDATE_AFTER_LAST:-0} == 1 ]]; then
    BENCH_FROZEN_SOURCE_HASH=0000000000000000000000000000000000000000000000000000000000000000
  fi
  [[ $(bench_source_hash) == "$BENCH_FROZEN_SOURCE_HASH" ]] || cb_die 'source changed after the final benchmark arm'
  [[ $(cb_source_tree_hash "$BENCH_EVAL_ROOT") == "$BENCH_FROZEN_SOURCE_HASH" ]] || cb_die 'private source snapshot changed during benchmark'
  jq -s -f "$BENCH_EVAL_ROOT/benchmarks/summarize.jq" \
    "$BENCH_OUTPUT/results.jsonl" >"$BENCH_OUTPUT/summary.json"
  jq '.status = "completed"' "$BENCH_OUTPUT/run.json" >"$BENCH_OUTPUT/run.json.tmp"
  mv -- "$BENCH_OUTPUT/run.json.tmp" "$BENCH_OUTPUT/run.json"
  printf 'benchmark results: %s\n' "$BENCH_OUTPUT"
  failed_runs=$(jq -s '[.[] | select(.pass != true)] | length' "$BENCH_OUTPUT/results.jsonl")
  (( failed_runs == 0 )) || cb_die "paired benchmark completed with $failed_runs failing arm(s); inspect the retained receipt"
}

main() {
  trap bench_cleanup EXIT
  bench_parse "$@"
  case $BENCH_MODE in static) bench_static ;; live) bench_live ;; canary) bench_canary ;; esac
}

main "$@"
