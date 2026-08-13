#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

CB_SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
CB_SOURCE_ROOT=$(cd -- "$CB_SCRIPT_DIR/.." && pwd -P)
REPETITIONS=3
OUTPUT=''
MODEL=''
TIMEOUT_SECONDS=180
TEMP=''

cleanup() {
  [[ -z $TEMP || ! -e $TEMP ]] || rm -rf -- "$TEMP"
}

usage() {
  cat <<'EOF'
Usage: routing-probe.sh [--repetitions N] [--output DIR]

Runs schema-constrained, read-only, ephemeral live Codex routing probes. This
consumes quota and requires a dedicated short-lived key in
CODEX_BASELINE_BENCHMARK_API_KEY. Existing Codex auth/session files are never
mounted or copied. Results are probabilistic behavior evidence.
EOF
}

while [[ $# -gt 0 ]]; do
  case $1 in
    --shared-auth) printf '%s\n' '--shared-auth was removed because auth/session files must never be exposed to probe workers' >&2; exit 2 ;;
    --repetitions) [[ $# -ge 2 && $2 =~ ^[1-9][0-9]*$ ]] || { printf '%s\n' 'invalid repetitions' >&2; exit 2; }; REPETITIONS=$2; shift ;;
    --output) [[ $# -ge 2 ]] || { printf '%s\n' 'missing output' >&2; exit 2; }; OUTPUT=$2; shift ;;
    --model) [[ $# -ge 2 ]] || { printf '%s\n' 'missing model' >&2; exit 2; }; MODEL=$2; shift ;;
    --timeout-seconds) [[ $# -ge 2 && $2 =~ ^[1-9][0-9]*$ ]] || { printf '%s\n' 'invalid timeout' >&2; exit 2; }; TIMEOUT_SECONDS=$2; shift ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'unknown option: %s\n' "$1" >&2; exit 2 ;;
  esac
  shift
done

for command in codex git jq timeout bwrap realpath; do command -v "$command" >/dev/null || { printf 'missing command: %s\n' "$command" >&2; exit 1; }; done
[[ -n ${CODEX_BASELINE_BENCHMARK_API_KEY:-} ]] || { printf '%s\n' 'CODEX_BASELINE_BENCHMARK_API_KEY is required' >&2; exit 1; }
OUTPUT=${OUTPUT:-"$CB_SOURCE_ROOT/behavior-results/routing-$(date -u '+%Y%m%dT%H%M%SZ')"}
[[ ! -e $OUTPUT ]] || { printf 'output exists: %s\n' "$OUTPUT" >&2; exit 1; }
mkdir -p -- "$OUTPUT"
TEMP=$(mktemp -d "${TMPDIR:-/tmp}/codex-baseline-routing.XXXXXX")
trap cleanup EXIT
mkdir -p -- "$TEMP/home/.codex" "$TEMP/home/.agents" "$TEMP/repo"
mkdir -p -- "$TEMP/git-home/empty-template"
env -i HOME="$TEMP/git-home" XDG_CONFIG_HOME="$TEMP/git-home/config" PATH="$PATH" LC_ALL=C \
  GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
  git -C "$TEMP/repo" -c core.hooksPath=/dev/null -c init.templateDir="$TEMP/git-home/empty-template" init -q

HOME="$TEMP/home" CODEX_HOME="$TEMP/home/.codex" AGENTS_HOME="$TEMP/home/.agents" \
  "$CB_SOURCE_ROOT/scripts/codex-baseline.sh" install --acknowledge-unverified-source >"$OUTPUT/install.log"
rm -rf -- "$TEMP/home/.codex/codex-baseline/runtime" "$TEMP/home/.local/bin/codex-baseline"
cat >"$TEMP/home/.codex/config.toml" <<'EOF'
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
codex_path=$(realpath -e -- "$(command -v codex)")
[[ $codex_path == /* && -f $codex_path && ! -L $codex_path && -x $codex_path ]] || { printf 'unsafe Codex executable: %s\n' "$codex_path" >&2; exit 1; }
: >"$OUTPUT/results.jsonl"

for ((repetition=1; repetition<=REPETITIONS; repetition++)); do
  while IFS= read -r case_json; do
    id=$(jq -r '.id' <<<"$case_json")
    task=$(jq -r '.task' <<<"$case_json")
    expected_workflow=$(jq -r '.workflow' <<<"$case_json")
    expected_risk=$(jq -r '.high_risk' <<<"$case_json")
    expected_skill=$(jq -r '.skill // empty' <<<"$case_json")
    last="$OUTPUT/$id-r$repetition.json"
    events="$OUTPUT/$id-r$repetition.jsonl"
    prompt="Classify this hypothetical engineering request under the installed Codex Baseline. Do not perform the task, use tools, read files, or alter the repository. Return only the schema response. Select a baseline skill only if its description directly matches. Request: $task"
    args=(exec --json --ephemeral --strict-config --ignore-rules --skip-git-repo-check --output-schema /routing-output.schema.json)
    [[ -z $MODEL ]] || args+=(-m "$MODEL")
    set +e
    rm -f -- "$TEMP/home/last-routing.json"
    timeout --foreground --signal=TERM --kill-after=10 "$TIMEOUT_SECONDS" \
      env -i OPENAI_API_KEY="$CODEX_BASELINE_BENCHMARK_API_KEY" \
      bwrap --unshare-all --share-net --unshare-user --disable-userns --die-with-parent --new-session --cap-drop ALL \
      --ro-bind /usr /usr --symlink usr/bin /bin --symlink usr/lib /lib --symlink usr/lib64 /lib64 \
      --dir /etc --ro-bind-try /etc/ssl /etc/ssl --ro-bind-try /etc/resolv.conf /etc/resolv.conf \
      --ro-bind-try /etc/hosts /etc/hosts --ro-bind-try /etc/nsswitch.conf /etc/nsswitch.conf \
      --proc /proc --dev /dev --tmpfs /tmp --dir /worker-home --dir /opt \
      --bind "$TEMP/home" /worker-home --ro-bind "$TEMP/repo" /repo \
      --ro-bind "$codex_path" /opt/codex --ro-bind "$CB_SOURCE_ROOT/tests/routing/output.schema.json" /routing-output.schema.json \
      --setenv HOME /worker-home --setenv CODEX_HOME /worker-home/.codex --setenv AGENTS_HOME /worker-home/.agents \
      --setenv PATH /usr/bin:/bin --setenv LANG C.UTF-8 --setenv LC_ALL C.UTF-8 \
      --chdir /repo /opt/codex "${args[@]}" -C /repo -o /worker-home/last-routing.json "$prompt" \
      </dev/null >"$events" 2>"$OUTPUT/$id-r$repetition.stderr"
    process_exit=$?
    set -e
    if [[ -f $TEMP/home/last-routing.json && ! -L $TEMP/home/last-routing.json ]]; then
      cp -- "$TEMP/home/last-routing.json" "$last"
    fi
    if LC_ALL=C grep -Eaq \
      '(sk-[A-Za-z0-9_-]{20,}|-----BEGIN ([A-Z ]+ )?PRIVATE KEY-----|eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,})' \
      "$events" "$last" "$OUTPUT/$id-r$repetition.stderr" 2>/dev/null; then
      printf 'possible credential material detected in routing artifact: %s r%d\n' "$id" "$repetition" >&2
      exit 1
    fi
    pass=false
    if [[ $process_exit -eq 0 && -f $last ]] && jq -e --arg workflow "$expected_workflow" --argjson risk "$expected_risk" --arg skill "$expected_skill" '
      .workflow == $workflow and .high_risk == $risk and
      (if $skill == "" then (.selected_skills | length) == 0 else (.selected_skills | index($skill)) != null end)
    ' "$last" >/dev/null 2>&1; then pass=true; fi
    [[ -f $last ]] || printf 'null\n' >"$last"
    jq -nc --arg id "$id" --argjson repetition "$repetition" --argjson pass "$pass" --argjson process_exit "$process_exit" \
      --arg expected_workflow "$expected_workflow" --argjson expected_risk "$expected_risk" --arg expected_skill "$expected_skill" \
      --slurpfile actual "${last:-/dev/null}" \
      '{schema:1,id:$id,repetition:$repetition,pass:$pass,process_exit:$process_exit,expected:{workflow:$expected_workflow,high_risk:$expected_risk,skill:(if $expected_skill=="" then null else $expected_skill end)},actual:($actual[0] // null)}' \
      >>"$OUTPUT/results.jsonl"
    printf '%s r%d pass=%s\n' "$id" "$repetition" "$pass"
  done < <(jq -c '.cases[]' "$CB_SOURCE_ROOT/tests/routing/cases.json")
done

jq -s '{schema:1,runs:length,passes:(map(select(.pass))|length),by_case:(group_by(.id)|map({id:.[0].id,runs:length,passes:(map(select(.pass))|length)}))}' \
  "$OUTPUT/results.jsonl" >"$OUTPUT/summary.json"
cat "$OUTPUT/summary.json"
