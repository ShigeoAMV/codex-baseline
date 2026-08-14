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

# Capture the dedicated input before even path discovery, then remove every
# credential variable from the host process environment. The retained shell
# variable is deliberately non-exported and is exposed only by exec_clean_environment.
ROUTING_INPUT_KEY=${CODEX_BASELINE_BENCHMARK_API_KEY-}
export -n ROUTING_INPUT_KEY 2>/dev/null || true
ROUTING_EXPECTED_CODEX_HASH=${CODEX_BASELINE_EXPECTED_CODEX_SHA256-}
export -n ROUTING_EXPECTED_CODEX_HASH 2>/dev/null || true
unset CODEX_BASELINE_BENCHMARK_API_KEY CODEX_BASELINE_EXPECTED_CODEX_SHA256 OPENAI_API_KEY CODEX_API_KEY
ROUTING_INPUT_PATH=${PATH:-/usr/bin:/bin}
PATH=/usr/bin:/bin
export PATH
ulimit -c 0

CB_SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
CB_SOURCE_ROOT=$(cd -- "$CB_SCRIPT_DIR/.." && pwd -P)
# shellcheck source=scripts/lib/common.sh
source "$CB_SCRIPT_DIR/lib/common.sh"
# shellcheck source=scripts/lib/evaluation.sh
source "$CB_SCRIPT_DIR/lib/evaluation.sh"
EVAL_DISCOVERY_PATH=$ROUTING_INPUT_PATH

ROUTING_REPETITIONS=3
ROUTING_OUTPUT=''
ROUTING_MODEL=''
ROUTING_TIMEOUT_SECONDS=180
ROUTING_TEMP=''
ROUTING_FROZEN_SOURCE_HASH=''
ROUTING_RUN_COUNT=0
ROUTING_PIDS=()
ROUTING_LAST=''
ROUTING_EVENTS=''
ROUTING_STDERR=''
ROUTING_PROCESS_EXIT=0
ROUTING_ELAPSED_MS=0
ROUTING_TURNS=0
ROUTING_COMMANDS=0
ROUTING_FILE_CHANGES=0
ROUTING_INPUT_TOKENS=0
ROUTING_OUTPUT_TOKENS=0
ROUTING_PROMPT_HASH=''
ROUTING_BEHAVIOR_INSPECTOR=''
ROUTING_EVAL_ROOT=$CB_SOURCE_ROOT
ROUTING_CODEX_PATH=''
ROUTING_CODEX_HASH=''
ROUTING_NODE_PATH=''
ROUTING_NODE_HASH=''

routing_cleanup() {
  local pid
  if [[ -n $ROUTING_OUTPUT && -f $ROUTING_OUTPUT/run.json ]] &&
      jq -e '.status == "running"' "$ROUTING_OUTPUT/run.json" >/dev/null 2>&1; then
    printf '%s\n' '# Invalid/incomplete routing run' '' \
      'The runner exited before writing a completed run receipt. Do not use these' \
      'partial results as release evidence; inspect stderr and rerun into a new directory.' \
      >"$ROUTING_OUTPUT/INVALID.md"
  fi
  for pid in "${ROUTING_PIDS[@]}"; do
    if jobs -pr | LC_ALL=C grep -Fxq -- "$pid"; then kill "$pid" 2>/dev/null || true; fi
    wait "$pid" 2>/dev/null || true
  done
  case ${ROUTING_TEMP:-} in
    "${TMPDIR:-/tmp}"/codex-baseline-routing.*) rm -rf -- "$ROUTING_TEMP" ;;
  esac
}

routing_usage() {
  cat <<'EOF'
Usage: routing-probe.sh [--repetitions N] [--output DIR] [--model MODEL]
                        [--expected-codex-sha256 HASH]

Runs schema-constrained, read-only, ephemeral live Codex routing and behavior
probes on Linux/WSL. Behavior cases exercise research-first ambiguity handling,
DEEP/high-risk planning, semantic onboarding, and independent conformance.
This consumes quota and requires a dedicated short-lived key in
CODEX_BASELINE_BENCHMARK_API_KEY. Existing Codex auth/session files are never
mounted or copied. Results are probabilistic evidence bound to a frozen source
hash; interruption or source drift creates INVALID.md.
EOF
}

routing_parse() {
  while [[ $# -gt 0 ]]; do
    case $1 in
      --shared-auth) cb_die '--shared-auth was removed because auth/session files must never be exposed to probe workers' ;;
      --repetitions)
        [[ $# -ge 2 && $2 =~ ^[1-9][0-9]*$ ]] || cb_die 'invalid repetitions'
        ROUTING_REPETITIONS=$2; shift ;;
      --output) [[ $# -ge 2 ]] || cb_die 'missing output'; ROUTING_OUTPUT=$2; shift ;;
      --model) [[ $# -ge 2 ]] || cb_die 'missing model'; ROUTING_MODEL=$2; shift ;;
      --expected-codex-sha256)
        [[ $# -ge 2 ]] || cb_die 'missing expected Codex hash'
        ROUTING_EXPECTED_CODEX_HASH=$2; shift ;;
      --timeout-seconds)
        [[ $# -ge 2 && $2 =~ ^[1-9][0-9]*$ && $2 -le 1800 ]] || cb_die 'timeout must be an integer from 1 through 1800'
        ROUTING_TIMEOUT_SECONDS=$2; shift ;;
      -h|--help) routing_usage; exit 0 ;;
      *) cb_die "unknown option: $1" ;;
    esac
    shift
  done
}

routing_git() {
  eval_git "$@"
}

routing_exec_clean_environment() {
  eval_exec_clean_environment "$@"
}

routing_write_codex_launcher() {
  local path=$1
  cat >"$path" <<'EOF'
#!/bin/bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 077
source /eval-lib/common.sh
source /eval-lib/evaluation.sh
IFS= read -r benchmark_key
/usr/bin/cp -a -- /home-seed/. /worker-home/
set +e
/usr/bin/env OPENAI_API_KEY="$benchmark_key" /opt/codex "$@" -C /repo -o /last-message
codex_exit=$?
set -e
eval_quiesce_worker_processes
EVAL_SECRET_ONE=$benchmark_key
eval_tree_is_clean /worker-home 4096 268435456
printf '%s\n' "$codex_exit" > /worker-status
unset benchmark_key EVAL_SECRET_ONE
EOF
  chmod 0500 -- "$path"
  [[ -f $path && ! -L $path && -x $path ]] || cb_die 'cannot create routing credential launcher'
}

routing_artifact_is_clean() {
  EVAL_SECRET_ONE=$ROUTING_INPUT_KEY
  EVAL_SECRET_TWO=''
  eval_artifact_is_clean "$1"
}

routing_tree_is_clean() {
  EVAL_SECRET_ONE=$ROUTING_INPUT_KEY
  EVAL_SECRET_TWO=''
  eval_tree_is_clean "$1" 4096 268435456
}

routing_assert_frozen_source() {
  [[ $(cb_source_tree_hash "$CB_SOURCE_ROOT") == "$ROUTING_FROZEN_SOURCE_HASH" ]] ||
    cb_die 'source changed during routing probe; run invalidated'
  [[ $(cb_source_tree_hash "$ROUTING_EVAL_ROOT") == "$ROUTING_FROZEN_SOURCE_HASH" ]] ||
    cb_die 'private source snapshot changed during routing probe; run invalidated'
}

routing_freeze_source_and_tools() {
  local snapshot live_hash snapshot_hash tool_root
  snapshot="$ROUTING_TEMP/source-snapshot"
  mkdir -- "$snapshot"
  cb_copy_source_tree "$CB_SOURCE_ROOT" "$snapshot"
  live_hash=$(cb_source_tree_hash "$CB_SOURCE_ROOT")
  snapshot_hash=$(cb_source_tree_hash "$snapshot")
  [[ $live_hash == "$ROUTING_FROZEN_SOURCE_HASH" && $snapshot_hash == "$ROUTING_FROZEN_SOURCE_HASH" ]] ||
    cb_die 'source changed while creating the private routing snapshot'
  ROUTING_EVAL_ROOT=$snapshot
  eval_validate_system_boundary
  eval_require_cgroup_boundary
  eval_validate_expected_codex_hash "$ROUTING_EXPECTED_CODEX_HASH"
  tool_root="$ROUTING_TEMP/tools"
  mkdir -- "$tool_root"
  ROUTING_CODEX_PATH="$tool_root/codex"
  ROUTING_NODE_PATH="$tool_root/node"
  ROUTING_CODEX_HASH=$(eval_freeze_executable codex "$CB_SOURCE_ROOT" "$ROUTING_CODEX_PATH")
  [[ $ROUTING_CODEX_HASH == "$ROUTING_EXPECTED_CODEX_HASH" ]] ||
    cb_die 'resolved Codex executable does not match the caller-pinned SHA-256'
  ROUTING_NODE_HASH=$(eval_freeze_executable node "$CB_SOURCE_ROOT" "$ROUTING_NODE_PATH")
}

routing_prepare() {
  local platform=linux source_revision=unversioned source_dirty=null untracked_source=''
  local codex_path=$1 source_git_home routing_cases behavior_cases version_home codex_version
  eval_validate_key "$ROUTING_INPUT_KEY"
  ROUTING_OUTPUT=$(eval_prepare_output "$CB_SOURCE_ROOT" behavior-results "$ROUTING_OUTPUT" "routing-$(date -u '+%Y%m%dT%H%M%SZ')")
  ROUTING_TEMP=$(mktemp -d "${TMPDIR:-/tmp}/codex-baseline-routing.XXXXXX")
  ROUTING_FROZEN_SOURCE_HASH=$(cb_source_tree_hash "$CB_SOURCE_ROOT")
  routing_freeze_source_and_tools
  codex_path=$ROUTING_CODEX_PATH
  version_home="$ROUTING_TEMP/version-home"
  mkdir -p -- "$version_home/.codex" "$version_home/.agents"
  codex_version=$(routing_exec_clean_environment /usr/bin/env -i HOME="$version_home" CODEX_HOME="$version_home/.codex" \
    AGENTS_HOME="$version_home/.agents" PATH=/usr/bin:/bin LANG=C.UTF-8 LC_ALL=C.UTF-8 "$codex_path" --version)
  source_git_home="$ROUTING_TEMP/source-git-home"
  if routing_git "$CB_SOURCE_ROOT" "$source_git_home" rev-parse HEAD >/dev/null 2>&1; then
    source_revision=$(routing_git "$CB_SOURCE_ROOT" "$source_git_home" rev-parse HEAD)
    source_dirty=false
    routing_git "$CB_SOURCE_ROOT" "$source_git_home" diff --quiet --no-ext-diff --no-textconv --ignore-submodules HEAD -- || source_dirty=true
    untracked_source=$(routing_git "$CB_SOURCE_ROOT" "$source_git_home" ls-files --others --exclude-standard --directory)
    [[ -z $untracked_source ]] || source_dirty=true
  fi
  if grep -qi microsoft /proc/sys/kernel/osrelease 2>/dev/null; then platform=wsl2; fi
  routing_cases=$(jq '.cases | length' "$ROUTING_EVAL_ROOT/tests/routing/cases.json")
  behavior_cases=$(jq '.cases | length' "$ROUTING_EVAL_ROOT/tests/behavior/cases.json")
  jq -nc --arg created "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" --arg codex "$codex_version" \
    --arg model "${ROUTING_MODEL:-account-default}" --arg platform "$platform" --arg revision "$source_revision" \
    --argjson dirty "$source_dirty" --arg source_hash "$ROUTING_FROZEN_SOURCE_HASH" \
    --arg codex_binary_hash "$ROUTING_CODEX_HASH" --arg node_binary_hash "$ROUTING_NODE_HASH" \
    --argjson repetitions "$ROUTING_REPETITIONS" --argjson routing_cases "$routing_cases" --argjson behavior_cases "$behavior_cases" \
    '{schema:1,contract:"codex-baseline-routing-run/v1",platform:$platform,mode:"live-routing-and-behavior",status:"running",isolation:"os-sandboxed-local-cgroup",model_invoked:true,host_checks_executed:true,created:$created,codex:$codex,model:$model,source_revision:$revision,source_dirty:$dirty,source_hash:$source_hash,codex_binary_hash:$codex_binary_hash,codex_identity:"caller-pinned-sha256",node_binary_hash:$node_binary_hash,repetitions:$repetitions,routing_cases:$routing_cases,behavior_cases:$behavior_cases,auth:"dedicated-api-key-stdin-pipe",resource_profile:"user-cgroup-memory2g-swap0-tasks128-cpu200-runtime-bounded-tmpfs"}' \
    >"$ROUTING_OUTPUT/run.json"
  : >"$ROUTING_OUTPUT/results.jsonl"
  : >"$ROUTING_OUTPUT/behavior-results.jsonl"
}

routing_prepare_worker() {
  mkdir -p -- "$ROUTING_TEMP/home/.codex" "$ROUTING_TEMP/home/.agents" "$ROUTING_TEMP/repo" "$ROUTING_TEMP/git-home/empty-template"
  routing_git "$ROUTING_TEMP/repo" "$ROUTING_TEMP/git-home" init -q
  HOME="$ROUTING_TEMP/home" CODEX_HOME="$ROUTING_TEMP/home/.codex" AGENTS_HOME="$ROUTING_TEMP/home/.agents" \
    "$ROUTING_EVAL_ROOT/scripts/codex-baseline.sh" install --acknowledge-unverified-source >"$ROUTING_OUTPUT/install.log"
  rm -rf -- "$ROUTING_TEMP/home/.codex/codex-baseline/runtime" "$ROUTING_TEMP/home/.local/bin/codex-baseline"
  cat >"$ROUTING_TEMP/home/.codex/config.toml" <<'EOF'
default_permissions = "routing-worker"
approval_policy = "never"

[permissions.routing-worker.filesystem]
":minimal" = "read"
"/proc" = "deny"

[permissions.routing-worker.filesystem.":workspace_roots"]
"." = "read"

[permissions.routing-worker.network]
enabled = false

[shell_environment_policy]
inherit = "core"
exclude = ["OPENAI_API_KEY", "CODEX_API_KEY", "CODEX_BASELINE_BENCHMARK_API_KEY"]
EOF
  routing_write_codex_launcher "$ROUTING_TEMP/codex-launch"
  routing_artifact_is_clean "$ROUTING_OUTPUT/install.log"
  routing_tree_is_clean "$ROUTING_TEMP/home"
}

routing_invoke() {
  local label=$1 repetition=$2 repository=$3 schema=$4 prompt=$5
  local codex_path=$6 timeout_path=$7 prlimit_path=$8 bwrap_path=$9 start_ns end_ns
  local launcher="$ROUTING_TEMP/codex-launch" worker_status infrastructure_exit
  local -a behavior_mount=()
  [[ $label =~ ^[a-z0-9-]+$ ]] || cb_die "unsafe routing invocation label: $label"
  [[ -d $repository && ! -L $repository ]] || cb_die "unsafe routing fixture repository: $repository"
  [[ -f $schema && ! -L $schema && -r $schema ]] || cb_die "unsafe routing output schema: $schema"
  routing_assert_frozen_source
  ROUTING_LAST="$ROUTING_OUTPUT/$label-r$repetition.json"
  ROUTING_EVENTS="$ROUTING_OUTPUT/$label-r$repetition.jsonl"
  ROUTING_STDERR="$ROUTING_OUTPUT/$label-r$repetition.stderr"
  ROUTING_PROMPT_HASH=$(printf '%s' "$prompt" | cb_sha256_text)
  [[ -f $launcher && ! -L $launcher && -x $launcher ]] || cb_die 'unsafe routing Codex launcher'
  if [[ -n $ROUTING_BEHAVIOR_INSPECTOR ]]; then
    [[ -f $ROUTING_BEHAVIOR_INSPECTOR && ! -L $ROUTING_BEHAVIOR_INSPECTOR && -x $ROUTING_BEHAVIOR_INSPECTOR ]] ||
      cb_die 'unsafe behavior evidence inspector'
    behavior_mount=(--ro-bind "$ROUTING_BEHAVIOR_INSPECTOR" /behavior-inspect)
  fi
  : >"$ROUTING_LAST"
  worker_status="$ROUTING_TEMP/worker-$label-r$repetition.status"
  : >"$worker_status"
  [[ $(cb_sha256_file "$codex_path") == "$ROUTING_CODEX_HASH" ]] || cb_die 'frozen Codex executable changed before routing invocation'
  [[ $(cb_sha256_file "$ROUTING_NODE_PATH") == "$ROUTING_NODE_HASH" ]] || cb_die 'frozen Node executable changed before routing invocation'
  local -a args=(exec --json --ephemeral --strict-config --ignore-rules --skip-git-repo-check --output-schema /response.schema.json)
  [[ -z $ROUTING_MODEL ]] || args+=(-m "$ROUTING_MODEL")
  start_ns=$(date +%s%N)
  set +e
  EVAL_SECRET_ONE=$ROUTING_INPUT_KEY
  EVAL_SECRET_TWO=''
  eval_run_scoped_worker "$((ROUTING_TIMEOUT_SECONDS + 30))" \
    "$EVAL_ENV" -i PATH=/usr/bin:/bin LANG=C.UTF-8 LC_ALL=C.UTF-8 \
    "$timeout_path" --foreground --signal=TERM --kill-after=10 "$ROUTING_TIMEOUT_SECONDS" \
    "$prlimit_path" --core=0 --fsize=16777216 --nofile=256 --nproc=4096 --as=2147483648 --cpu="$ROUTING_TIMEOUT_SECONDS" -- \
    "$bwrap_path" --unshare-all --share-net --unshare-user --disable-userns --die-with-parent --new-session --cap-drop ALL \
    --ro-bind /usr /usr --symlink usr/bin /bin --symlink usr/lib /lib --symlink usr/lib64 /lib64 \
    --dir /etc --ro-bind-try /etc/ssl /etc/ssl --ro-bind-try /etc/resolv.conf /etc/resolv.conf \
    --ro-bind-try /etc/hosts /etc/hosts --ro-bind-try /etc/nsswitch.conf /etc/nsswitch.conf \
    --proc /proc --dev /dev --size 134217728 --tmpfs /tmp \
    --dir /worker-home --size 268435456 --tmpfs /worker-home --dir /opt --dir /opt/node --dir /eval-lib \
    --ro-bind "$ROUTING_TEMP/home" /home-seed --ro-bind "$repository" /repo \
    --ro-bind "$codex_path" /opt/codex --ro-bind "$ROUTING_NODE_PATH" /opt/node/node \
    --ro-bind "$schema" /response.schema.json --ro-bind "$launcher" /codex-launch \
    --ro-bind "$ROUTING_EVAL_ROOT/scripts/lib/common.sh" /eval-lib/common.sh \
    --ro-bind "$ROUTING_EVAL_ROOT/scripts/lib/evaluation.sh" /eval-lib/evaluation.sh \
    --bind "$ROUTING_LAST" /last-message --bind "$worker_status" /worker-status \
    "${behavior_mount[@]}" \
    --setenv HOME /worker-home --setenv CODEX_HOME /worker-home/.codex --setenv AGENTS_HOME /worker-home/.agents \
    --setenv CODEX_BASELINE_EVAL_PID_NAMESPACE 1 \
    --setenv PATH /opt/node:/usr/bin:/bin --setenv LANG C.UTF-8 --setenv LC_ALL C.UTF-8 \
    --chdir /repo /usr/bin/bash /codex-launch "${args[@]}" "$prompt" \
    >"$ROUTING_EVENTS" 2>"$ROUTING_STDERR"
  infrastructure_exit=$?
  set -e
  [[ $(cb_sha256_file "$codex_path") == "$ROUTING_CODEX_HASH" ]] || cb_die 'frozen Codex executable changed during routing invocation'
  [[ $(cb_sha256_file "$ROUTING_NODE_PATH") == "$ROUTING_NODE_HASH" ]] || cb_die 'frozen Node executable changed during routing invocation'
  [[ $infrastructure_exit -eq 0 ]] || return "$infrastructure_exit"
  [[ -f $worker_status && ! -L $worker_status ]] || cb_die "missing routing worker status: $label r$repetition"
  IFS= read -r ROUTING_PROCESS_EXIT <"$worker_status" || cb_die "malformed routing worker status: $label r$repetition"
  [[ $ROUTING_PROCESS_EXIT =~ ^[0-9]+$ ]] || cb_die "invalid routing worker status: $label r$repetition"
  end_ns=$(date +%s%N)
  ROUTING_ELAPSED_MS=$(((end_ns - start_ns) / 1000000))
  [[ -s $ROUTING_LAST || -L $ROUTING_LAST ]] ||
    cb_die "missing routing last-message artifact: $label r$repetition"
  [[ -f $ROUTING_LAST && ! -L $ROUTING_LAST ]] ||
    cb_die "linked or special routing last-message artifact: $label r$repetition"
  jq -s -e 'length > 0 and all(.[]; type == "object") and any(.[]; .type == "turn.completed")' \
    "$ROUTING_EVENTS" >/dev/null 2>&1 || cb_die 'routing JSONL is malformed, truncated, or incomplete'
  routing_artifact_is_clean "$ROUTING_EVENTS"
  routing_artifact_is_clean "$ROUTING_LAST"
  routing_artifact_is_clean "$ROUTING_STDERR"
  routing_assert_frozen_source
  ROUTING_TURNS=$(jq -s -e '[.[] | select(.type == "turn.completed")] | length' "$ROUTING_EVENTS") || cb_die 'cannot derive routing turn telemetry'
  ROUTING_COMMANDS=$(jq -s -e '[.[] | select(.type == "item.completed" and .item.type == "command_execution")] | length' "$ROUTING_EVENTS") || cb_die 'cannot derive routing command telemetry'
  ROUTING_FILE_CHANGES=$(jq -s -e '[.[] | select(.type == "item.completed" and (.item.type == "file_change" or .item.type == "file_changes"))] | length' "$ROUTING_EVENTS") || cb_die 'cannot derive routing change telemetry'
  ROUTING_INPUT_TOKENS=$(jq -s -e '[.[] | .usage.input_tokens? // empty] | if length == 0 then null else add end' "$ROUTING_EVENTS") || cb_die 'cannot derive routing input telemetry'
  ROUTING_OUTPUT_TOKENS=$(jq -s -e '[.[] | .usage.output_tokens? // empty] | if length == 0 then null else add end' "$ROUTING_EVENTS") || cb_die 'cannot derive routing output telemetry'
}

routing_behavior_events_pass() {
  local events=$1
  jq -s -e '
    def text($value): ($value // "" | if type == "array" then join(" ") else tostring end);
    [.[] | select(.type == "item.completed" and .item.type == "command_execution") | .item] as $commands |
    ($commands | length) == 1 and
    (text($commands[0].command) == "/behavior-inspect") and
    (($commands[0].exit_code // -1) == 0) and
    (text($commands[0].aggregated_output // $commands[0].output // $commands[0].stdout) | endswith("behavior-evidence-complete\n"))
  ' "$events" >/dev/null
}

routing_run_behavior_verifier() {
  local verifier=$1 result=$2 output=$3
  eval_run_scoped_command 15 \
    "$EVAL_ENV" -i PATH=/usr/bin:/bin LANG=C.UTF-8 LC_ALL=C.UTF-8 \
    "$EVAL_TIMEOUT" --foreground --signal=TERM --kill-after=2 10 \
    "$EVAL_PRLIMIT" --core=0 --fsize=16777216 --nofile=64 --nproc=4096 --as=536870912 --cpu=8 -- \
    "$EVAL_BWRAP" --unshare-all --unshare-user --disable-userns --die-with-parent --new-session --clearenv --cap-drop ALL \
    --ro-bind /usr /usr --symlink usr/bin /bin --symlink usr/lib /lib --symlink usr/lib64 /lib64 \
    --proc /proc --dev /dev --size 67108864 --tmpfs /tmp --dir /home \
    --ro-bind "$verifier" /verifier --ro-bind "$result" /result.json \
    --setenv HOME /home --setenv PATH /usr/bin:/bin --setenv LANG C.UTF-8 \
    --chdir /home /usr/bin/bash /verifier /result.json >"$output" 2>&1
}

routing_run_case() {
  local case_json=$1 repetition=$2 codex_path=$3 timeout_path=$4 prlimit_path=$5 bwrap_path=$6
  local id task expected_workflow expected_risk expected_skill prompt pass=false actual
  id=$(jq -r '.id' <<<"$case_json")
  task=$(jq -r '.task' <<<"$case_json")
  expected_workflow=$(jq -r '.workflow' <<<"$case_json")
  expected_risk=$(jq -r '.high_risk' <<<"$case_json")
  expected_skill=$(jq -r '.skill // empty' <<<"$case_json")
  [[ $id =~ ^[a-z0-9-]+$ ]] || cb_die "unsafe routing case id: $id"
  prompt="Classify this hypothetical engineering request under the installed Codex Baseline. Do not perform the task, use tools, read files, or alter the repository. Return only the schema response. Select a baseline skill only if its description directly matches. Request: $task"
  routing_invoke "routing-$id" "$repetition" "$ROUTING_TEMP/repo" "$ROUTING_EVAL_ROOT/tests/routing/output.schema.json" "$prompt" \
    "$codex_path" "$timeout_path" "$prlimit_path" "$bwrap_path"
  if [[ $ROUTING_PROCESS_EXIT -eq 0 && $ROUTING_COMMANDS -eq 0 && $ROUTING_FILE_CHANGES -eq 0 ]] &&
      jq -e --arg workflow "$expected_workflow" --argjson risk "$expected_risk" --arg skill "$expected_skill" '
    .workflow == $workflow and .high_risk == $risk and
    (if $skill == "" then (.selected_skills | length) == 0 else (.selected_skills | index($skill)) != null end)
  ' "$ROUTING_LAST" >/dev/null 2>&1; then
    pass=true
  fi
  actual=$(jq -c . "$ROUTING_LAST" 2>/dev/null || printf 'null')
  jq -nc --arg id "$id" --argjson repetition "$repetition" --argjson pass "$pass" --argjson process_exit "$ROUTING_PROCESS_EXIT" \
    --argjson elapsed_ms "$ROUTING_ELAPSED_MS" --argjson turns "$ROUTING_TURNS" --argjson commands "$ROUTING_COMMANDS" --argjson file_changes "$ROUTING_FILE_CHANGES" \
    --argjson input_tokens "$ROUTING_INPUT_TOKENS" --argjson output_tokens "$ROUTING_OUTPUT_TOKENS" \
    --arg expected_workflow "$expected_workflow" --argjson expected_risk "$expected_risk" --arg expected_skill "$expected_skill" \
    --argjson actual "$actual" --arg source_hash "$ROUTING_FROZEN_SOURCE_HASH" --arg prompt_hash "$ROUTING_PROMPT_HASH" \
    '{schema:1,contract:"codex-baseline-routing-result/v1",id:$id,repetition:$repetition,pass:$pass,process_exit:$process_exit,elapsed_ms:$elapsed_ms,turns:$turns,commands:$commands,file_changes:$file_changes,input_tokens:$input_tokens,output_tokens:$output_tokens,source_hash:$source_hash,prompt_hash:$prompt_hash,expected:{workflow:$expected_workflow,high_risk:$expected_risk,skill:(if $expected_skill=="" then null else $expected_skill end)},actual:$actual}' \
    >>"$ROUTING_OUTPUT/results.jsonl"
  routing_tree_is_clean "$ROUTING_OUTPUT"
  ROUTING_RUN_COUNT=$((ROUTING_RUN_COUNT + 1))
  if [[ ${CODEX_BASELINE_TESTING:-0} == 1 && ${CODEX_BASELINE_TEST_ROUTING_INVALIDATE_AFTER_FIRST:-0} == 1 && $ROUTING_RUN_COUNT -eq 1 ]]; then
    ROUTING_FROZEN_SOURCE_HASH=0000000000000000000000000000000000000000000000000000000000000000
  fi
  printf '%s r%d pass=%s\n' "$id" "$repetition" "$pass"
}

routing_run_behavior_case() {
  local case_json=$1 repetition=$2 codex_path=$3 timeout_path=$4 prlimit_path=$5 bwrap_path=$6
  local id task fixture verifier verifier_log verifier_exit pass=false actual prompt
  id=$(jq -r '.id' <<<"$case_json")
  task=$(jq -r '.task' <<<"$case_json")
  [[ $id =~ ^[a-z0-9-]+$ ]] || cb_die "unsafe behavior case id: $id"
  fixture="$ROUTING_EVAL_ROOT/tests/behavior/fixtures/$id"
  verifier="$ROUTING_EVAL_ROOT/tests/behavior/verifiers/$id.sh"
  [[ -d $fixture && ! -L $fixture && -x $verifier && ! -L $verifier ]] || cb_die "incomplete behavior case: $id"
  prompt="Follow the installed Codex Baseline for this contained evaluation. First run /behavior-inspect exactly once using the shell tool; this host-owned read-only helper supplies the complete bounded repository evidence. Do not run any other command. Then use the smallest trustworthy workflow and select a baseline skill only when its description directly matches. Return only the response schema with case_id '$id'. Do not expose credentials. Task: $task"
  ROUTING_BEHAVIOR_INSPECTOR="$ROUTING_EVAL_ROOT/tests/behavior/inspect.sh"
  routing_invoke "behavior-$id" "$repetition" "$fixture" "$ROUTING_EVAL_ROOT/tests/behavior/output.schema.json" "$prompt" \
    "$codex_path" "$timeout_path" "$prlimit_path" "$bwrap_path"
  ROUTING_BEHAVIOR_INSPECTOR=''
  verifier_log="$ROUTING_OUTPUT/behavior-$id-r$repetition.verifier.log"
  set +e
  routing_run_behavior_verifier "$verifier" "$ROUTING_LAST" "$verifier_log"
  verifier_exit=$?
  set -e
  routing_artifact_is_clean "$verifier_log"
  if [[ $ROUTING_PROCESS_EXIT -eq 0 && $verifier_exit -eq 0 ]] && routing_behavior_events_pass "$ROUTING_EVENTS" &&
      [[ $ROUTING_FILE_CHANGES -eq 0 ]]; then
    pass=true
  fi
  actual=$(jq -c . "$ROUTING_LAST" 2>/dev/null || printf 'null')
  jq -nc --arg id "$id" --argjson repetition "$repetition" --argjson pass "$pass" \
    --argjson process_exit "$ROUTING_PROCESS_EXIT" --argjson verifier_exit "$verifier_exit" --argjson elapsed_ms "$ROUTING_ELAPSED_MS" \
    --argjson turns "$ROUTING_TURNS" --argjson commands "$ROUTING_COMMANDS" --argjson file_changes "$ROUTING_FILE_CHANGES" \
    --argjson input_tokens "$ROUTING_INPUT_TOKENS" --argjson output_tokens "$ROUTING_OUTPUT_TOKENS" \
    --arg source_hash "$ROUTING_FROZEN_SOURCE_HASH" --arg prompt_hash "$ROUTING_PROMPT_HASH" --argjson actual "$actual" \
    '{schema:1,contract:"codex-baseline-behavior-result/v1",id:$id,repetition:$repetition,pass:$pass,process_exit:$process_exit,verifier_exit:$verifier_exit,elapsed_ms:$elapsed_ms,turns:$turns,commands:$commands,file_changes:$file_changes,input_tokens:$input_tokens,output_tokens:$output_tokens,source_hash:$source_hash,prompt_hash:$prompt_hash,actual:$actual}' \
    >>"$ROUTING_OUTPUT/behavior-results.jsonl"
  routing_tree_is_clean "$ROUTING_OUTPUT"
  ROUTING_RUN_COUNT=$((ROUTING_RUN_COUNT + 1))
  printf 'behavior %s r%d pass=%s\n' "$id" "$repetition" "$pass"
}

routing_main() {
  local codex_path timeout_path prlimit_path bwrap_path repetition case_json completed_source_hash
  local expected_routing expected_behavior actual_routing actual_behavior
  trap routing_cleanup EXIT
  routing_parse "$@"
  cb_require_command git
  cb_require_command jq
  routing_prepare ''
  codex_path=$ROUTING_CODEX_PATH
  timeout_path=$EVAL_TIMEOUT
  prlimit_path=$EVAL_PRLIMIT
  bwrap_path=$EVAL_BWRAP
  routing_prepare_worker
  for ((repetition=1; repetition<=ROUTING_REPETITIONS; repetition++)); do
    while IFS= read -r case_json; do
      routing_run_case "$case_json" "$repetition" "$codex_path" "$timeout_path" "$prlimit_path" "$bwrap_path"
    done < <(jq -c '.cases[]' "$ROUTING_EVAL_ROOT/tests/routing/cases.json")
    while IFS= read -r case_json; do
      routing_run_behavior_case "$case_json" "$repetition" "$codex_path" "$timeout_path" "$prlimit_path" "$bwrap_path"
    done < <(jq -c '.cases[]' "$ROUTING_EVAL_ROOT/tests/behavior/cases.json")
  done
  if [[ ${CODEX_BASELINE_TESTING:-0} == 1 && ${CODEX_BASELINE_TEST_ROUTING_INVALIDATE_AFTER_LAST:-0} == 1 ]]; then
    ROUTING_FROZEN_SOURCE_HASH=0000000000000000000000000000000000000000000000000000000000000000
  fi
  routing_assert_frozen_source
  completed_source_hash=$ROUTING_FROZEN_SOURCE_HASH
  jq -n --arg source_hash "$completed_source_hash" --argjson repetitions "$ROUTING_REPETITIONS" \
    --slurpfile routing "$ROUTING_OUTPUT/results.jsonl" --slurpfile behavior "$ROUTING_OUTPUT/behavior-results.jsonl" \
    '{schema:1,contract:"codex-baseline-routing-summary/v1",source_hash:$source_hash,repetitions:$repetitions,routing:{runs:($routing|length),passes:($routing|map(select(.pass))|length),by_case:($routing|group_by(.id)|map({id:.[0].id,runs:length,passes:(map(select(.pass))|length)}))},behavior:{runs:($behavior|length),passes:($behavior|map(select(.pass))|length),by_case:($behavior|group_by(.id)|map({id:.[0].id,runs:length,passes:(map(select(.pass))|length)}))}}' \
    >"$ROUTING_OUTPUT/summary.json"
  routing_tree_is_clean "$ROUTING_OUTPUT"
  jq '.status = "completed"' "$ROUTING_OUTPUT/run.json" >"$ROUTING_OUTPUT/run.json.tmp"
  mv -- "$ROUTING_OUTPUT/run.json.tmp" "$ROUTING_OUTPUT/run.json"
  cat "$ROUTING_OUTPUT/summary.json"
  expected_routing=$(jq -er '.routing_cases * .repetitions' "$ROUTING_OUTPUT/run.json")
  expected_behavior=$(jq -er '.behavior_cases * .repetitions' "$ROUTING_OUTPUT/run.json")
  actual_routing=$(jq -er '.routing.passes' "$ROUTING_OUTPUT/summary.json")
  actual_behavior=$(jq -er '.behavior.passes' "$ROUTING_OUTPUT/summary.json")
  [[ $actual_routing -eq $expected_routing && $actual_behavior -eq $expected_behavior ]] ||
    cb_die 'routing/behavior release threshold not met; completed failure receipt retained'
}

routing_main "$@"
