#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

CB_SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
CB_SOURCE_ROOT=$(cd -- "$CB_SCRIPT_DIR/.." && pwd -P)
# shellcheck source=scripts/lib/common.sh
source "$CB_SCRIPT_DIR/lib/common.sh"

BENCH_MODE=static
BENCH_REPETITIONS=3
BENCH_TASKS='small-js-bug,small-config-timeout,small-doc-port,medium-js-feature,medium-dedup-reproduction,medium-id-refactor,large-architecture,large-feature-flags,risk-migration,risk-safe-path'
BENCH_OUTPUT=''
BENCH_MODEL=''
BENCH_TIMEOUT_SECONDS=600
BENCH_TEMPS=()
BENCH_FROZEN_SOURCE_HASH=''

bench_cleanup() {
  local path
  if [[ -n $BENCH_OUTPUT && -f $BENCH_OUTPUT/run.json ]] &&
      jq -e '.status == "running"' "$BENCH_OUTPUT/run.json" >/dev/null 2>&1; then
    printf '%s\n' '# Invalid/incomplete benchmark run' '' \
      'The runner exited before writing a completed run receipt. Do not use these' \
      'partial results for comparison; inspect stderr and rerun into a new directory.' \
      >"$BENCH_OUTPUT/INVALID.md"
  fi
  for path in "${BENCH_TEMPS[@]}"; do
    case $(basename -- "$path") in codex-baseline-bench.*) rm -rf -- "$path" ;; esac
  done
}

bench_usage() {
  cat <<'EOF'
Usage: codex-baseline benchmark [--static|--live] [options]

Options:
  --repetitions N    Paired repetitions per task (default: 3)
  --tasks CSV        Task IDs to run
  --model MODEL      Explicit model for both arms
  --output DIR       Result directory (live mode)
  --timeout-seconds N  Maximum wall time for one Codex arm (default: 600)
Static mode validates fixtures and proves every starter fails its verifier. It
runs no model. Live mode requires CODEX_BASELINE_BENCHMARK_API_KEY, may consume
API quota, and must use a dedicated short-lived key. Existing Codex auth/session
files are never mounted or copied. Each arm receives a fresh HOME, CODEX_HOME,
and workspace. Generated code is verified in a networkless OS sandbox.
EOF
}

bench_parse() {
  while [[ $# -gt 0 ]]; do
    case $1 in
      --static) BENCH_MODE=static ;;
      --live) BENCH_MODE=live ;;
      --shared-auth) cb_die '--shared-auth was removed because auth/session files must never be exposed to benchmark workers' ;;
      --repetitions)
        [[ $# -ge 2 && $2 =~ ^[1-9][0-9]*$ ]] || cb_die '--repetitions requires a positive integer'
        BENCH_REPETITIONS=$2; shift ;;
      --tasks) [[ $# -ge 2 ]] || cb_die '--tasks requires CSV'; BENCH_TASKS=$2; shift ;;
      --model) [[ $# -ge 2 ]] || cb_die '--model requires a value'; BENCH_MODEL=$2; shift ;;
      --output) [[ $# -ge 2 ]] || cb_die '--output requires a directory'; BENCH_OUTPUT=$2; shift ;;
      --timeout-seconds)
        [[ $# -ge 2 && $2 =~ ^[1-9][0-9]*$ ]] || cb_die '--timeout-seconds requires a positive integer'
        BENCH_TIMEOUT_SECONDS=$2; shift ;;
      -h|--help) bench_usage; exit 0 ;;
      *) cb_die "unknown benchmark option: $1" ;;
    esac
    shift
  done
}

bench_each_task() {
  tr ',' '\n' <<<"$BENCH_TASKS"
}

bench_source_hash() {
  local manifest entry rel mode digest
  manifest=$(mktemp "${TMPDIR:-/tmp}/codex-baseline-source.XXXXXX")
  if find -P "$CB_SOURCE_ROOT" \
    \( -path "$CB_SOURCE_ROOT/.git" -o -path "$CB_SOURCE_ROOT/benchmark-results" -o -path "$CB_SOURCE_ROOT/behavior-results" -o -path "$CB_SOURCE_ROOT/.codebase-memory" \) -prune -o \
    -type l -print -quit | grep -q .; then
    rm -f -- "$manifest"
    cb_die 'symbolic links are not allowed in benchmarked source'
  fi
  while IFS= read -r -d '' entry; do
    rel=${entry#"$CB_SOURCE_ROOT"/}
    mode=$(stat -c '%a' -- "$entry")
    digest=$(cb_sha256_file "$entry")
    printf 'f\t%s\t%s\t%s\n' "$mode" "$digest" "$rel" >>"$manifest"
  done < <(find -P "$CB_SOURCE_ROOT" \
    \( -path "$CB_SOURCE_ROOT/.git" -o -path "$CB_SOURCE_ROOT/benchmark-results" -o -path "$CB_SOURCE_ROOT/behavior-results" -o -path "$CB_SOURCE_ROOT/.codebase-memory" \) -prune -o \
    -type f -print0 | LC_ALL=C sort -z)
  digest=$(cb_sha256_file "$manifest")
  rm -f -- "$manifest"
  printf '%s' "$digest"
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

bench_scope_metrics() {
  local task=$1 workspace=$2 output=$3 isolated_home=$4 path changed=0 unnecessary=0
  while IFS= read -r -d '' path; do
    changed=$((changed + 1))
    if ! jq -e --arg task "$task" --arg path "$path" \
      '.tasks[] | select(.id == $task) | .allowed_changed_paths | index($path)' \
      "$CB_SOURCE_ROOT/benchmarks/manifest.json" >/dev/null; then
      unnecessary=$((unnecessary + 1))
    fi
  done < <({ bench_git "$workspace" "$isolated_home" diff --no-ext-diff --name-only -z HEAD --; bench_git "$workspace" "$isolated_home" ls-files --others --exclude-standard -z; } | LC_ALL=C sort -zu)
  printf '%d\t%d\n' "$changed" "$unnecessary" >"$output"
}

bench_run_verifier() {
  local verifier=$1 workspace=$2 output=$3 node_path
  node_path=$(command -v node)
  [[ $node_path == /* && -f $node_path && ! -L $node_path ]] || cb_die 'node must resolve to a regular absolute executable for verifier isolation'
  timeout --signal=TERM --kill-after=5 60 \
    prlimit --core=0 --fsize=16777216 --nofile=256 --nproc=1024 --as=4294967296 --cpu=55 -- \
    bwrap --unshare-all --unshare-user --disable-userns --die-with-parent --new-session --clearenv --cap-drop ALL \
    --ro-bind /usr /usr --symlink usr/bin /bin --symlink usr/lib /lib --symlink usr/lib64 /lib64 \
    --proc /proc --dev /dev --tmpfs /tmp --dir /home --dir /opt --dir /opt/node \
    --ro-bind "$node_path" /opt/node/node --bind "$workspace" /workspace \
    --ro-bind "$verifier" /verifier --setenv HOME /tmp/verifier-home \
    --setenv PATH /opt/node:/usr/bin:/bin --setenv LANG C.UTF-8 --chdir /workspace \
    /usr/bin/bash /verifier /workspace >"$output" 2>&1
}

bench_validate_task() {
  local task=$1 fixture verifier scratch status verifier_log
  fixture="$CB_SOURCE_ROOT/benchmarks/fixtures/$task"
  verifier="$CB_SOURCE_ROOT/benchmarks/verifiers/$task.sh"
  [[ $task =~ ^[a-z0-9-]+$ ]] || cb_die "unsafe task id: $task"
  [[ -f $fixture/task.md && -d $fixture/workspace && -x $verifier ]] || cb_die "incomplete benchmark task: $task"
  bash -n "$verifier"
  scratch=$(mktemp -d "${TMPDIR:-/tmp}/codex-baseline-bench.XXXXXX")
  BENCH_TEMPS+=("$scratch")
  cp -a -- "$fixture/workspace/." "$scratch/"
  verifier_log=$(mktemp "${TMPDIR:-/tmp}/codex-baseline-bench.verifier.XXXXXX")
  BENCH_TEMPS+=("$verifier_log")
  set +e
  bench_run_verifier "$verifier" "$scratch" "$verifier_log"
  status=$?
  set -e
  [[ $status -eq 1 ]] || cb_die "starter verifier returned unexpected infrastructure status $status: $task"
  printf 'static: %s fixture valid; starter fails verifier as expected\n' "$task"
}

bench_static() {
  local task count=0
  cb_require_command bwrap
  cb_require_command node
  cb_require_command prlimit
  cb_require_command timeout
  [[ -f $CB_SOURCE_ROOT/benchmarks/manifest.json ]] || cb_die 'benchmark manifest missing'
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
      "$CB_SOURCE_ROOT/scripts/codex-baseline.sh" install --acknowledge-unverified-source >"$home/install.log"
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
exclude = ["OPENAI_API_KEY", "CODEX_API_KEY", "CODEX_BASELINE_BENCHMARK_API_KEY"]
EOF
}

bench_metric() {
  local events=$1 filter=$2
  jq -s "$filter" "$events" 2>/dev/null || printf '0'
}

bench_git() {
  local workspace=$1 isolated_home=$2
  shift 2
  mkdir -p -- "$isolated_home" "$isolated_home/empty-template"
  env -i HOME="$isolated_home" XDG_CONFIG_HOME="$isolated_home/config" PATH="$PATH" LC_ALL=C \
    GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
    git -C "$workspace" -c core.hooksPath=/dev/null -c init.templateDir="$isolated_home/empty-template" \
    -c commit.gpgsign=false -c tag.gpgsign=false "$@"
}

bench_artifacts_are_clean() {
  local file
  for file in "$@"; do
    [[ -f $file ]] || continue
    if LC_ALL=C grep -Eaq \
      '(sk-[A-Za-z0-9_-]{20,}|-----BEGIN ([A-Z ]+ )?PRIVATE KEY-----|eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,})' \
      "$file"; then
      cb_die "possible credential material detected in benchmark artifact; quarantining run: $file"
    fi
  done
}

bench_executable() {
  local command_path resolved
  command_path=$(command -v "$1") || cb_die "required command not found: $1"
  resolved=$(realpath -e -- "$command_path") || cb_die "cannot resolve executable: $1"
  [[ $resolved == /* && -f $resolved && ! -L $resolved && -x $resolved ]] || cb_die "unsafe executable for worker isolation: $resolved"
  printf '%s' "$resolved"
}

bench_run_codex() {
  local home=$1 workspace=$2 events=$3 stderr_log=$4 last_host=$5 prompt=$6
  shift 6
  local codex_path node_path last_worker=/worker-home/last-message.txt process_exit
  codex_path=$(bench_executable codex)
  node_path=$(bench_executable node)
  rm -f -- "$home/user/last-message.txt"
  timeout --foreground --signal=TERM --kill-after=15 "$BENCH_TIMEOUT_SECONDS" \
    env -i OPENAI_API_KEY="$CODEX_BASELINE_BENCHMARK_API_KEY" \
    prlimit --core=0 --fsize=268435456 --nofile=512 --nproc=1024 --as=8589934592 --cpu="$BENCH_TIMEOUT_SECONDS" -- \
    bwrap --unshare-all --share-net --unshare-user --disable-userns --die-with-parent --new-session --cap-drop ALL \
    --ro-bind /usr /usr --symlink usr/bin /bin --symlink usr/lib /lib --symlink usr/lib64 /lib64 \
    --dir /etc --ro-bind-try /etc/ssl /etc/ssl --ro-bind-try /etc/resolv.conf /etc/resolv.conf \
    --ro-bind-try /etc/hosts /etc/hosts --ro-bind-try /etc/nsswitch.conf /etc/nsswitch.conf \
    --ro-bind-try /etc/gai.conf /etc/gai.conf --ro-bind-try /etc/host.conf /etc/host.conf \
    --proc /proc --dev /dev --tmpfs /tmp --dir /worker-home --dir /opt --dir /opt/node \
    --bind "$home/user" /worker-home --bind "$workspace" /workspace \
    --ro-bind "$codex_path" /opt/codex --ro-bind "$node_path" /opt/node/node \
    --setenv HOME /worker-home --setenv CODEX_HOME /worker-home/.codex --setenv AGENTS_HOME /worker-home/.agents \
    --setenv PATH /opt/node:/usr/bin:/bin --setenv LANG C.UTF-8 --setenv LC_ALL C.UTF-8 \
    --chdir /workspace /opt/codex "$@" -C /workspace -o "$last_worker" "$prompt" \
    </dev/null >"$events" 2>"$stderr_log"
  process_exit=$?
  if [[ -f $home/user/last-message.txt && ! -L $home/user/last-message.txt ]]; then
    cp -- "$home/user/last-message.txt" "$last_host"
  fi
  return "$process_exit"
}

bench_run_one() {
  local task=$1 repetition=$2 arm=$3 fixture verifier run_root workspace home events last prompt
  local start_ns end_ns elapsed process_exit verifier_exit pass turns commands changes changed_files unnecessary_files failed_commands subagents input_tokens output_tokens
  local current_source_hash layer_hash layer_bytes fixture_hash prompt_hash verifier_hash scope_metrics task_class
  fixture="$CB_SOURCE_ROOT/benchmarks/fixtures/$task"
  verifier="$CB_SOURCE_ROOT/benchmarks/verifiers/$task.sh"
  task_class=$(jq -er --arg id "$task" '.tasks[] | select(.id == $id) | .class' "$CB_SOURCE_ROOT/benchmarks/manifest.json") || cb_die "cannot resolve benchmark class: $task"
  run_root=$(mktemp -d "${TMPDIR:-/tmp}/codex-baseline-bench.XXXXXX")
  BENCH_TEMPS+=("$run_root")
  workspace="$run_root/workspace"
  home="$run_root/home"
  mkdir -p -- "$workspace"
  cp -a -- "$fixture/workspace/." "$workspace/"
  bench_git "$workspace" "$run_root/git-home" init -q
  bench_git "$workspace" "$run_root/git-home" add --all
  bench_git "$workspace" "$run_root/git-home" -c user.name=codex-baseline -c user.email=baseline.invalid commit -qm starter
  bench_prepare_home "$arm" "$home"
  current_source_hash=$(bench_source_hash)
  [[ $current_source_hash == "$BENCH_FROZEN_SOURCE_HASH" ]] || cb_die 'source changed during benchmark; run invalidated before next arm'
  layer_hash=$(bench_layer_hash "$arm" "$home")
  layer_bytes=$(bench_layer_bytes "$arm" "$home")
  fixture_hash=$(cb_tree_hash "$fixture/workspace")
  verifier_hash=$(cb_sha256_file "$verifier")
  events="$BENCH_OUTPUT/events-$task-r$repetition-$arm.jsonl"
  last="$BENCH_OUTPUT/last-$task-r$repetition-$arm.txt"
  prompt=$(<"$fixture/task.md")
  prompt+=$'\n\nWork only inside the supplied workspace. Do not inspect benchmark runner or verifier files outside it. Report commands actually run and remaining uncertainty.'
  prompt_hash=$(printf '%s' "$prompt" | cb_sha256_text)
  local -a args=(exec --json --ephemeral --strict-config --ignore-rules --skip-git-repo-check)
  [[ -z $BENCH_MODEL ]] || args+=(-m "$BENCH_MODEL")
  start_ns=$(date +%s%N)
  set +e
  bench_run_codex "$home" "$workspace" "$events" "$BENCH_OUTPUT/stderr-$task-r$repetition-$arm.log" "$last" "$prompt" "${args[@]}"
  process_exit=$?
  set -e
  bench_artifacts_are_clean "$events" "$last" "$BENCH_OUTPUT/stderr-$task-r$repetition-$arm.log"
  end_ns=$(date +%s%N)
  elapsed=$(((end_ns - start_ns) / 1000000))
  set +e
  bench_run_verifier "$verifier" "$workspace" "$BENCH_OUTPUT/verifier-$task-r$repetition-$arm.log"
  verifier_exit=$?
  set -e
  pass=false
  [[ $process_exit -eq 0 && $verifier_exit -eq 0 ]] && pass=true
  scope_metrics="$run_root/scope.tsv"
  bench_scope_metrics "$task" "$workspace" "$scope_metrics" "$run_root/git-home"
  IFS=$'\t' read -r changed_files unnecessary_files <"$scope_metrics"
  turns=$(bench_metric "$events" '[.[] | select(.type == "turn.completed")] | length')
  commands=$(bench_metric "$events" '[.[] | select(.type == "item.completed" and .item.type == "command_execution")] | length')
  changes=$(bench_metric "$events" '[.[] | select(.type == "item.completed" and (.item.type == "file_change" or .item.type == "file_changes"))] | length')
  failed_commands=$(bench_metric "$events" '[.[] | select(.type == "item.completed" and .item.type == "command_execution" and ((.item.exit_code // 0) != 0))] | length')
  subagents=$(bench_metric "$events" '[.[] | select((.type // "" | test("subagent|collab")) or (.item.type // "" | test("subagent|collab")))] | length')
  input_tokens=$(bench_metric "$events" '[.[] | .usage.input_tokens? // empty] | add // 0')
  output_tokens=$(bench_metric "$events" '[.[] | .usage.output_tokens? // empty] | add // 0')
  jq -nc \
    --arg task "$task" --arg class "$task_class" --arg arm "$arm" --argjson repetition "$repetition" --argjson pass "$pass" \
    --argjson process_exit "$process_exit" --argjson verifier_exit "$verifier_exit" --argjson elapsed_ms "$elapsed" \
    --argjson turns "$turns" --argjson commands "$commands" --argjson file_changes "$changes" --argjson changed_files "$changed_files" --argjson unnecessary_files "$unnecessary_files" --argjson failed_command_events "$failed_commands" --argjson subagent_events "$subagents" \
    --argjson input_tokens "$input_tokens" --argjson output_tokens "$output_tokens" \
    --argjson baseline_layer_bytes "$layer_bytes" \
    --arg source_hash "$BENCH_FROZEN_SOURCE_HASH" --arg layer_hash "$layer_hash" --arg fixture_hash "$fixture_hash" --arg prompt_hash "$prompt_hash" --arg verifier_hash "$verifier_hash" \
    '{schema:1,task:$task,class:$class,arm:$arm,repetition:$repetition,pass:$pass,process_exit:$process_exit,verifier_exit:$verifier_exit,elapsed_ms:$elapsed_ms,turns:$turns,commands:$commands,file_changes:$file_changes,changed_files:$changed_files,unnecessary_files:$unnecessary_files,failed_command_events:$failed_command_events,subagent_events:$subagent_events,input_tokens:$input_tokens,output_tokens:$output_tokens,baseline_layer_bytes:$baseline_layer_bytes,retry_count:null,review_findings:null,isolation:"os-sandboxed-local",source_hash:$source_hash,layer_hash:$layer_hash,fixture_hash:$fixture_hash,prompt_hash:$prompt_hash,verifier_hash:$verifier_hash}' \
    >>"$BENCH_OUTPUT/results.jsonl"
  printf 'live: %s r%d %s pass=%s process=%d verifier=%d elapsed=%dms\n' "$task" "$repetition" "$arm" "$pass" "$process_exit" "$verifier_exit" "$elapsed"
}

bench_order() {
  local task=$1 repetition=$2 nibble
  nibble=$(printf '%s:%s' "$task" "$repetition" | cb_sha256_text)
  nibble=${nibble: -1}
  if (( 16#$nibble % 2 == 0 )); then printf '%s\n' vanilla baseline; else printf '%s\n' baseline vanilla; fi
}

bench_live() {
  local task repetition arm source_revision=unversioned source_dirty=null source_git_home output_absolute untracked_source='' platform=linux
  cb_require_command codex
  cb_require_command jq
  cb_require_command node
  cb_require_command git
  cb_require_command timeout
  cb_require_command bwrap
  cb_require_command prlimit
  [[ -n ${CODEX_BASELINE_BENCHMARK_API_KEY:-} ]] || \
    cb_die 'live mode requires a dedicated short-lived key in CODEX_BASELINE_BENCHMARK_API_KEY'
  if [[ -z $BENCH_OUTPUT ]]; then BENCH_OUTPUT="$CB_SOURCE_ROOT/benchmark-results/$(date -u '+%Y%m%dT%H%M%SZ')"; fi
  output_absolute=$(realpath -m -- "$BENCH_OUTPUT") || cb_die "cannot normalize result directory: $BENCH_OUTPUT"
  case $output_absolute in
    "$CB_SOURCE_ROOT/benchmark-results"/*|"$CB_SOURCE_ROOT/behavior-results"/*) ;;
    "$CB_SOURCE_ROOT"/*) cb_die 'result directory inside source must be below benchmark-results or behavior-results' ;;
  esac
  BENCH_OUTPUT=$output_absolute
  [[ ! -e $BENCH_OUTPUT ]] || cb_die "result directory already exists: $BENCH_OUTPUT"
  mkdir -p -- "$BENCH_OUTPUT"
  BENCH_FROZEN_SOURCE_HASH=$(bench_source_hash)
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
  jq -nc --arg created "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" --arg codex "$(codex --version)" --arg model "${BENCH_MODEL:-account-default}" --arg platform "$platform" \
    --arg revision "$source_revision" --argjson dirty "$source_dirty" --arg manifest_hash "$(cb_sha256_file "$CB_SOURCE_ROOT/benchmarks/manifest.json")" \
    --arg source_hash "$BENCH_FROZEN_SOURCE_HASH" \
    '{schema:1,contract:"codex-baseline-benchmark/v1",platform:$platform,mode:"live-paired",status:"running",isolation:"os-sandboxed-local",model_invoked:true,verifiers_executed:true,created:$created,codex:$codex,model:$model,source_revision:$revision,source_dirty:$dirty,source_hash:$source_hash,manifest_hash:$manifest_hash,auth:"dedicated-api-key-env-not-captured",account_service_tier:"unknown"}' \
    >"$BENCH_OUTPUT/run.json"
  : >"$BENCH_OUTPUT/results.jsonl"
  while IFS= read -r task; do
    [[ -n $task ]] || continue
    bench_validate_task "$task" >/dev/null
    for ((repetition=1; repetition<=BENCH_REPETITIONS; repetition++)); do
      while IFS= read -r arm; do bench_run_one "$task" "$repetition" "$arm"; done < <(bench_order "$task" "$repetition")
    done
  done < <(bench_each_task)
  jq -s -f "$CB_SOURCE_ROOT/benchmarks/summarize.jq" \
    "$BENCH_OUTPUT/results.jsonl" >"$BENCH_OUTPUT/summary.json"
  jq '.status = "completed"' "$BENCH_OUTPUT/run.json" >"$BENCH_OUTPUT/run.json.tmp"
  mv -- "$BENCH_OUTPUT/run.json.tmp" "$BENCH_OUTPUT/run.json"
  printf 'benchmark results: %s\n' "$BENCH_OUTPUT"
}

main() {
  trap bench_cleanup EXIT
  bench_parse "$@"
  case $BENCH_MODE in static) bench_static ;; live) bench_live ;; esac
}

main "$@"
