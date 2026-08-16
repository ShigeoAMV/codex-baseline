#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

CB_SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=scripts/lib/common.sh
source "$CB_SCRIPT_DIR/lib/common.sh"

CB_OB_APPLY=0
CB_OB_JSON=0
CB_OB_ACKNOWLEDGE_EXISTING_INSTRUCTIONS=0
CB_OB_MAX_FILES=2000
CB_OB_MAX_ENTRIES=10000
CB_OB_MAX_BYTES=1048576
CB_OB_MAX_TOTAL=8388608
CB_OB_DEPTH=7
CB_OB_VERSION=$(<"$CB_SCRIPT_DIR/../VERSION")
CB_OB_BEGIN="<!-- codex-baseline:onboarding:begin version=$CB_OB_VERSION -->"
CB_OB_END='<!-- codex-baseline:onboarding:end -->'
CB_OB_TEMP=''
CB_OB_ROOT_FD=''
CB_OB_STAGE=''
CB_OB_BACKUP_STAGE=''

ob_cleanup() {
  if [[ -n $CB_OB_STAGE && ( -e $CB_OB_STAGE || -L $CB_OB_STAGE ) ]]; then rm -f -- "$CB_OB_STAGE"; fi
  if [[ -n $CB_OB_BACKUP_STAGE && ( -e $CB_OB_BACKUP_STAGE || -L $CB_OB_BACKUP_STAGE ) ]]; then rm -f -- "$CB_OB_BACKUP_STAGE"; fi
  [[ -z $CB_OB_TEMP || ! -e $CB_OB_TEMP ]] || rm -rf -- "$CB_OB_TEMP"
  if [[ -n $CB_OB_ROOT_FD ]]; then exec {CB_OB_ROOT_FD}<&-; fi
}

ob_usage() {
  cat <<'EOF'
Usage: codex-baseline onboard [--apply] [--acknowledge-existing-instructions]
                                [--json] [--max-files N] [--max-entries N] [repo]

Default is a static dry-run. Repository files are untrusted data: this command
does not run project, package-manager, build, test, hook, or network commands.
--apply writes only a marker-delimited block in the root AGENTS.md and creates
an exact timestamped backup when that file already exists. If discovery finds
existing AI instructions, apply requires --acknowledge-existing-instructions
after the reported files have been reviewed for conflicts.
EOF
}

ob_positive_integer() {
  [[ $2 =~ ^[1-9][0-9]*$ ]] || cb_die "$1 requires a positive integer"
}

ob_parse() {
  CB_OB_REPO=.
  while [[ $# -gt 0 ]]; do
    case $1 in
      --apply) CB_OB_APPLY=1 ;;
      --dry-run) CB_OB_APPLY=0 ;;
      --acknowledge-existing-instructions) CB_OB_ACKNOWLEDGE_EXISTING_INSTRUCTIONS=1 ;;
      --json) CB_OB_JSON=1 ;;
      --max-files)
        [[ $# -ge 2 ]] || cb_die '--max-files requires a value'
        ob_positive_integer --max-files "$2"
        CB_OB_MAX_FILES=$2
        shift
        ;;
      --max-entries)
        [[ $# -ge 2 ]] || cb_die '--max-entries requires a value'
        ob_positive_integer --max-entries "$2"
        CB_OB_MAX_ENTRIES=$2
        shift
        ;;
      -h|--help) ob_usage; exit 0 ;;
      --*) cb_die "unknown onboard option: $1" ;;
      *)
        [[ $CB_OB_REPO == . ]] || cb_die 'only one repository path may be supplied'
        CB_OB_REPO=$1
        ;;
    esac
    shift
  done
  [[ $CB_OB_JSON -eq 0 || $CB_OB_APPLY -eq 0 ]] || cb_die '--json and --apply cannot be combined'
}

ob_is_sensitive_path() {
  local rel=$1 base
  base=$(basename -- "$rel")
  case $rel in
    .git/*|*/.git/*|node_modules/*|*/node_modules/*|vendor/*|*/vendor/*|dist/*|*/dist/*|build/*|*/build/*|.venv/*|*/.venv/*) return 0 ;;
  esac
  case $base in
    .env|.env.*|*.pem|*.p12|*.pfx|id_rsa|id_ed25519|credentials*|auth.json|session*|*.key|*.kdbx) return 0 ;;
  esac
  return 1
}

ob_assert_root_identity() {
  local cursor canonical identity
  [[ -d $CB_OB_ROOT_PATH && ! -L $CB_OB_ROOT_PATH ]] || cb_die "repository root changed or became linked: $CB_OB_ROOT_PATH"
  canonical=$(realpath -e -- "$CB_OB_ROOT_PATH")
  [[ $canonical == "$CB_OB_ROOT_PATH" ]] || cb_die "repository ancestor changed or became linked: $CB_OB_ROOT_PATH"
  identity=$(stat -Lc '%d:%i' -- "$CB_OB_ROOT_PATH")
  [[ $identity == "$CB_OB_ROOT_ID" ]] || cb_die "repository root identity changed during onboarding: $CB_OB_ROOT_PATH"
  [[ $(stat -Lc '%d:%i' -- "$CB_OB_ROOT") == "$CB_OB_ROOT_ID" ]] || cb_die 'repository directory handle identity changed unexpectedly'
  cursor=$CB_OB_ROOT_PATH
  while [[ $cursor != / ]]; do
    [[ ! -L $cursor ]] || cb_die "repository path contains a symbolic-link ancestor: $cursor"
    cursor=$(dirname -- "$cursor")
  done
}

ob_collect() {
  local input=$CB_OB_REPO entry rel base top size count=0 entries=0 total=0 links=0 skipped_sensitive=0 skipped_large=0 file
  [[ -d $input && ! -L $input ]] || cb_die "repository must be a real directory, not a link: $input"
  CB_OB_ROOT_PATH=$(realpath -e -- "$input")
  [[ $CB_OB_ROOT_PATH != / ]] || cb_die 'refusing to onboard the filesystem root'
  trap ob_cleanup EXIT
  CB_OB_ROOT_ID=$(stat -Lc '%d:%i' -- "$CB_OB_ROOT_PATH")
  exec {CB_OB_ROOT_FD}<"$CB_OB_ROOT_PATH"
  CB_OB_ROOT="/proc/self/fd/$CB_OB_ROOT_FD"
  [[ -d $CB_OB_ROOT ]] || cb_die 'this platform cannot provide an anchored repository directory handle'
  ob_assert_root_identity
  CB_OB_TEMP=$(mktemp -d "${TMPDIR:-/tmp}/codex-baseline-onboard.XXXXXX")
  : >"$CB_OB_TEMP/files"
  : >"$CB_OB_TEMP/manifests"
  : >"$CB_OB_TEMP/ai"
  : >"$CB_OB_TEMP/ci"
  : >"$CB_OB_TEMP/docs"
  : >"$CB_OB_TEMP/quality"
  : >"$CB_OB_TEMP/tests"
  : >"$CB_OB_TEMP/deployment"
  : >"$CB_OB_TEMP/generated"
  : >"$CB_OB_TEMP/source-roots"
  : >"$CB_OB_TEMP/sensitive-areas"
  : >"$CB_OB_TEMP/warnings"
  while IFS= read -r -d '' entry; do
    entries=$((entries + 1))
    [[ $entries -le $CB_OB_MAX_ENTRIES ]] || cb_die "entry visit limit exceeded ($CB_OB_MAX_ENTRIES); narrow the repository or raise --max-entries deliberately"
    rel=${entry#"$CB_OB_ROOT"/}
    if printf '%s' "$rel" | LC_ALL=C grep -q '[[:cntrl:]]'; then
      printf '%s\n' 'path with control characters skipped' >>"$CB_OB_TEMP/warnings"
      continue
    fi
    if [[ -L $entry ]]; then
      links=$((links + 1))
      continue
    fi
    [[ ! -d $entry ]] || continue
    [[ -f $entry ]] || continue
    if ob_is_sensitive_path "$rel"; then
      skipped_sensitive=$((skipped_sensitive + 1))
      continue
    fi
    size=$(stat -c '%s' -- "$entry")
    if [[ $size -gt $CB_OB_MAX_BYTES || $((total + size)) -gt $CB_OB_MAX_TOTAL ]]; then
      skipped_large=$((skipped_large + 1))
      continue
    fi
    count=$((count + 1))
    [[ $count -le $CB_OB_MAX_FILES ]] || cb_die "file limit exceeded ($CB_OB_MAX_FILES); narrow the repository or raise --max-files deliberately"
    total=$((total + size))
    printf '%s\n' "$rel" >>"$CB_OB_TEMP/files"
    base=$(basename -- "$rel")
    case $base in
      package.json|pnpm-lock.yaml|yarn.lock|package-lock.json|Cargo.toml|Cargo.lock|go.mod|go.sum|pyproject.toml|poetry.lock|uv.lock|requirements.txt|Gemfile|composer.json|pom.xml|build.gradle|build.gradle.kts|Makefile|CMakeLists.txt|Dockerfile|docker-compose.yml|compose.yml) printf '%s\n' "$rel" >>"$CB_OB_TEMP/manifests" ;;
      AGENTS.md|AGENTS.override.md|CLAUDE.md|GEMINI.md|copilot-instructions.md) printf '%s\n' "$rel" >>"$CB_OB_TEMP/ai" ;;
    esac
    case $rel in .codex/*|*/.codex/*|.agents/*|*/.agents/*) printf '%s\n' "$rel" >>"$CB_OB_TEMP/ai" ;; esac
    case $base in README|README.*|CONTRIBUTING|CONTRIBUTING.*|SECURITY.md|ARCHITECTURE.md|architecture.md|ADR.md) printf '%s\n' "$rel" >>"$CB_OB_TEMP/docs" ;; esac
    case $rel in docs/architecture/*|docs/decisions/*|docs/adr/*|doc/architecture/*) printf '%s\n' "$rel" >>"$CB_OB_TEMP/docs" ;; esac
    case $base in .eslintrc|.eslintrc.*|eslint.config.*|.prettierrc|.prettierrc.*|prettier.config.*|tsconfig*.json|jsconfig*.json|ruff.toml|mypy.ini|pytest.ini|tox.ini|.golangci.*|rustfmt.toml|clippy.toml|.editorconfig) printf '%s\n' "$rel" >>"$CB_OB_TEMP/quality" ;; esac
    case $rel in test/*|tests/*|spec/*|specs/*|__tests__/*|*/test/*|*/tests/*|*/__tests__/*) printf '%s\n' "$rel" >>"$CB_OB_TEMP/tests" ;; esac
    case $base in Dockerfile|docker-compose.yml|compose.yml|azure-pipelines.yml|Jenkinsfile) printf '%s\n' "$rel" >>"$CB_OB_TEMP/deployment" ;; esac
    case $rel in .github/workflows/*|.gitlab-ci.yml|.gitlab-ci/*|.circleci/*|deploy/*|deployment/*|infra/*|terraform/*|k8s/*|kubernetes/*|helm/*) printf '%s\n' "$rel" >>"$CB_OB_TEMP/deployment" ;; esac
    case $base in *.generated.*|*.g.*|*.pb.*|package-lock.json|yarn.lock|pnpm-lock.yaml|Cargo.lock|go.sum) printf '%s\n' "$rel" >>"$CB_OB_TEMP/generated" ;; esac
    if [[ $rel == */* ]]; then
      top=${rel%%/*}
      case $top in src|app|apps|lib|libs|packages|services|cmd|internal|server|client|frontend|backend|web|api) printf '%s\n' "$top" >>"$CB_OB_TEMP/source-roots" ;; esac
    fi
    case $rel in
      .github/workflows/*|.gitlab-ci.yml|.gitlab-ci/*|Jenkinsfile|azure-pipelines.yml|.circleci/*) printf '%s\n' "$rel" >>"$CB_OB_TEMP/ci" ;;
    esac
    case $rel in
      *auth*|*security*|*secret*|*crypto*|*migration*|*deploy*|*terraform*|*infra*) printf '%s\n' "$rel" >>"$CB_OB_TEMP/sensitive-areas" ;;
    esac
  done < <(find -H "$CB_OB_ROOT" -xdev -mindepth 1 -maxdepth "$CB_OB_DEPTH" \
    \( -type d \( -name .git -o -name node_modules -o -name vendor -o -name dist -o -name build -o -name .venv \) -prune -print0 \) -o -print0)
  CB_OB_COUNT=$count
  CB_OB_ENTRIES=$entries
  CB_OB_TOTAL=$total
  CB_OB_LINKS=$links
  CB_OB_SKIPPED_SENSITIVE=$skipped_sensitive
  CB_OB_SKIPPED_LARGE=$skipped_large
  CB_OB_GIT_DETECTED=false
  [[ ( -d $CB_OB_ROOT/.git || -f $CB_OB_ROOT/.git ) && ! -L $CB_OB_ROOT/.git ]] && CB_OB_GIT_DETECTED=true
  for file in files manifests ai ci docs quality tests deployment generated source-roots sensitive-areas warnings; do
    LC_ALL=C sort -u -o "$CB_OB_TEMP/$file" "$CB_OB_TEMP/$file"
  done
}

ob_add_command() {
  local value=$1
  [[ $value =~ ^[A-Za-z0-9][A-Za-z0-9._:/@+-]*(\ [A-Za-z0-9][A-Za-z0-9._:/@+*-]*)*$ ]] || return 0
  printf '%s\n' "$value" >>"$CB_OB_TEMP/commands.raw"
}

ob_validated_file() {
  local rel=$1
  LC_ALL=C grep -Fqx -- "$rel" "$CB_OB_TEMP/files"
}

ob_infer_commands() {
  local package key
  : >"$CB_OB_TEMP/commands.raw"
  if ob_validated_file package.json; then
    package="$CB_OB_TEMP/package.json"
    cp -P -- "$CB_OB_ROOT/package.json" "$package"
    [[ -f $package && ! -L $package && $(stat -c '%s' -- "$package") -le $CB_OB_MAX_BYTES ]] || \
      cb_die 'package.json changed to an unsafe object during static discovery'
    if command -v jq >/dev/null 2>&1; then
      while IFS= read -r key; do
        [[ $key =~ ^[A-Za-z0-9:_-]{1,64}$ ]] || continue
        ob_add_command "npm run $key"
      done < <(jq -r '.scripts? | if type == "object" then keys[] else empty end' "$package" 2>/dev/null || true)
    else
      while IFS= read -r key; do
        [[ $key =~ ^[A-Za-z0-9:_-]{1,64}$ ]] || continue
        ob_add_command "npm run $key"
      done < <(awk '
        /"scripts"[[:space:]]*:/ { in_scripts=1; next }
        in_scripts && /^[[:space:]]*}/ { exit }
        in_scripts && match($0, /"[A-Za-z0-9:_-]+"[[:space:]]*:/) {
          value=substr($0, RSTART, RLENGTH); sub(/^[[:space:]]*"/, "", value); sub(/"[[:space:]]*:$/, "", value); print value
        }
      ' "$package")
    fi
  fi
  ob_validated_file Cargo.toml && { ob_add_command 'cargo check'; ob_add_command 'cargo test'; ob_add_command 'cargo fmt --check'; }
  ob_validated_file go.mod && { ob_add_command 'go test ./...'; ob_add_command 'go vet ./...'; }
  ob_validated_file pyproject.toml && { ob_add_command 'pytest'; ob_add_command 'ruff check .'; }
  ob_validated_file Makefile && ob_add_command 'make test'
  LC_ALL=C sort -u "$CB_OB_TEMP/commands.raw" >"$CB_OB_TEMP/commands"
}

ob_parallel_statement() {
  local kind=$1 subject=$2 status=$3 evidence=$4
  [[ $kind =~ ^[a-z_]+$ && $status =~ ^(declared|inferred|unknown)$ ]] || cb_die 'invalid parallelism-map statement'
  [[ ! -f $CB_OB_TEMP/parallelism-map.raw || $(grep -c "^${kind}"$'\t' "$CB_OB_TEMP/parallelism-map.raw" || true) -lt 64 ]] || return 0
  printf '%s\t%s\t%s\t%s\n' "$kind" "$subject" "$status" "$evidence" >>"$CB_OB_TEMP/parallelism-map.raw"
}

ob_build_parallelism_map() {
  local value kind line
  local -a required_kinds=(source_root package_boundary api_boundary generated_ownership write_conflict shared_cache shared_build_output shared_port shared_database shared_fixture test_shard write_safe)
  : >"$CB_OB_TEMP/parallelism-map.raw"
  : >"$CB_OB_TEMP/parallelism-map"
  if [[ -s $CB_OB_TEMP/source-roots ]]; then
    while IFS= read -r value; do ob_parallel_statement source_root "$value" inferred "$value"; done <"$CB_OB_TEMP/source-roots"
  else
    ob_parallel_statement source_root '*' unknown 'no bounded source-root signal'
  fi
  if grep -Eq '^(package\.json|Cargo\.toml|go\.mod|pyproject\.toml)$' "$CB_OB_TEMP/manifests"; then
    value=$(grep -E '^(package\.json|Cargo\.toml|go\.mod|pyproject\.toml)$' "$CB_OB_TEMP/manifests" | LC_ALL=C sort -u | head -n 1)
    ob_parallel_statement package_boundary '.' inferred "$value"
  else
    ob_parallel_statement package_boundary '*' unknown 'no bounded package/workspace manifest signal'
  fi
  ob_parallel_statement api_boundary '*' unknown 'no explicit bounded API boundary declaration'
  if [[ -s $CB_OB_TEMP/generated ]]; then
    while IFS= read -r value; do
      ob_parallel_statement generated_ownership "$value" inferred "$value"
      ob_parallel_statement write_conflict "$value" inferred "$value"
    done <"$CB_OB_TEMP/generated"
  else
    ob_parallel_statement generated_ownership '*' unknown 'no generated ownership signal'
    ob_parallel_statement write_conflict '*' unknown 'no bounded write-conflict signal'
  fi
  for kind in shared_cache shared_build_output shared_port shared_database shared_fixture test_shard write_safe; do
    ob_parallel_statement "$kind" '*' unknown "no bounded ${kind//_/ } declaration"
  done
  LC_ALL=C sort -u -o "$CB_OB_TEMP/parallelism-map.raw" "$CB_OB_TEMP/parallelism-map.raw"
  # Reserve one statement for every public-contract category before spending
  # the remaining budget on additional evidence from noisy repositories.
  for kind in "${required_kinds[@]}"; do
    line=$(grep -m 1 "^${kind}"$'\t' "$CB_OB_TEMP/parallelism-map.raw") || cb_die "parallelism map is missing required category: $kind"
    printf '%s\n' "$line" >>"$CB_OB_TEMP/parallelism-map"
  done
  while IFS= read -r line; do
    [[ $(wc -l <"$CB_OB_TEMP/parallelism-map") -lt 64 ]] || break
    grep -Fqx -- "$line" "$CB_OB_TEMP/parallelism-map" || printf '%s\n' "$line" >>"$CB_OB_TEMP/parallelism-map"
  done <"$CB_OB_TEMP/parallelism-map.raw"
  LC_ALL=C sort -u -o "$CB_OB_TEMP/parallelism-map" "$CB_OB_TEMP/parallelism-map"
}

ob_json_parallelism_map() {
  local kind subject status evidence separator=''
  printf '{"statements":['
  while IFS=$'\t' read -r kind subject status evidence; do
    printf '%s{"kind":"%s","subject":"%s","status":"%s","evidence":["%s"]}' \
      "$separator" "$kind" "$(cb_json_escape "$subject")" "$status" "$(cb_json_escape "$evidence")"
    separator=,
  done <"$CB_OB_TEMP/parallelism-map"
  printf ']}'
}

ob_render_parallelism_map() {
  local kind subject status evidence emitted=0
  printf '\n%s\n' '## Parallel execution map (static evidence only)'
  while IFS=$'\t' read -r kind subject status evidence; do
    [[ $status != unknown && ${#subject} -le 240 && $subject =~ ^[A-Za-z0-9._][A-Za-z0-9._/-]*$ ]] || continue
    printf -- '- %s%s%s: %s (%s; evidence %s%s%s)\n' '`' "$kind" '`' "$subject" "$status" '`' "$evidence" '`'
    emitted=$((emitted + 1))
    [[ $emitted -lt 12 ]] || break
  done <"$CB_OB_TEMP/parallelism-map"
  [[ $emitted -gt 0 ]] || printf '%s\n' '- No safe parallel boundary was established by static discovery.'
  printf '%s\n' '- Unknown write isolation means one parent writer; unknown test isolation means serial tests.'
}

ob_print_list() {
  local title=$1 file=$2 line emitted=0 omitted=0
  printf '%s\n' "$title"
  if [[ ! -s $file ]]; then
    printf '%s\n' '- none observed within limits'
    return
  fi
  # shellcheck disable=SC2016 # Markdown backticks are intentional literals.
  while IFS= read -r line; do
    if [[ ${#line} -le 240 && $line =~ ^[A-Za-z0-9._][A-Za-z0-9._/-]*$ ]]; then
      printf -- '- `%s`\n' "$line"
      emitted=$((emitted + 1))
    else
      omitted=$((omitted + 1))
    fi
  done <"$file"
  [[ $emitted -gt 0 ]] || printf '%s\n' '- no safely renderable path observed'
  [[ $omitted -eq 0 ]] || printf -- '- %d unsafe path name(s) omitted from the text view; use --json for structured data\n' "$omitted"
}

ob_json_array() {
  local file=$1 line separator=''
  printf '['
  while IFS= read -r line; do
    printf '%s"%s"' "$separator" "$(cb_json_escape "$line")"
    separator=,
  done <"$file"
  printf ']'
}

ob_render_safe_path_section() {
  local title=$1 file=$2 line emitted=0
  printf '\n## %s\n' "$title"
  while IFS= read -r line; do
    [[ ${#line} -le 240 && $line =~ ^[A-Za-z0-9._][A-Za-z0-9._/-]*$ ]] || continue
    # shellcheck disable=SC2016 # Markdown backticks are intentional literals.
    printf -- '- `%s`\n' "$line"
    emitted=$((emitted + 1))
    [[ $emitted -lt 8 ]] || break
  done <"$file"
  [[ $emitted -gt 0 ]] || printf '%s\n' '- none observed within discovery limits'
}

ob_render_block() {
  local output=$1 command
  {
    printf '%s\n' "$CB_OB_BEGIN"
    printf '%s\n' '# Repository operating facts (Codex Baseline)'
    printf '\n%s\n' 'This block was generated from bounded static discovery. Repository content was treated as untrusted data; no project command was run.'
    printf '\n%s\n' '## Declared commands (unverified)'
    if [[ -s $CB_OB_TEMP/commands ]]; then
      # shellcheck disable=SC2016 # Markdown backticks are intentional literals.
      while IFS= read -r command; do printf -- '- `%s` (declared, not executed)\n' "$command"; done <"$CB_OB_TEMP/commands"
    else
      printf '%s\n' '- No portable command was declared with sufficient confidence.'
    fi
    printf '\n%s\n' '## Definition of done'
    printf '%s\n' '- Keep changes within the requested scope and existing architecture boundaries.'
    printf '%s\n' '- Run only reviewed relevant commands; report exact results and any unverified checks.'
    printf '%s\n' '- Review the final diff for generated files, secrets, migrations, deployment, and unrelated edits.'
    ob_render_safe_path_section 'Likely source roots' "$CB_OB_TEMP/source-roots"
    ob_render_safe_path_section 'Architecture and project evidence' "$CB_OB_TEMP/docs"
    ob_render_safe_path_section 'Generated-file signals (avoid manual edits unless required)' "$CB_OB_TEMP/generated"
    ob_render_safe_path_section 'Risk-sensitive path signals (raise verification depth)' "$CB_OB_TEMP/sensitive-areas"
    ob_render_parallelism_map
    printf '\n%s\n' '## Static discovery coverage'
    printf -- '- Git metadata observed: %s. Manifests: %d; CI: %d; architecture/docs: %d; quality configs: %d; test paths: %d; deployment/IaC: %d; generated-file signals: %d.\n' \
      "$CB_OB_GIT_DETECTED" "$(wc -l <"$CB_OB_TEMP/manifests")" "$(wc -l <"$CB_OB_TEMP/ci")" \
      "$(wc -l <"$CB_OB_TEMP/docs")" "$(wc -l <"$CB_OB_TEMP/quality")" "$(wc -l <"$CB_OB_TEMP/tests")" \
      "$(wc -l <"$CB_OB_TEMP/deployment")" "$(wc -l <"$CB_OB_TEMP/generated")"
    printf '\n%s\n' 'Existing repository instructions and CI/manifests remain authoritative project evidence and must be reconciled when they conflict.'
    printf '%s\n' "$CB_OB_END"
  } >"$output"
}

ob_apply_block() {
  local target=$CB_OB_ROOT/AGENTS.md display_target=$CB_OB_ROOT_PATH/AGENTS.md block=$1 stage backup='' backup_name='' snapshot=$CB_OB_TEMP/agents.preimage
  local source=/dev/null starts ends start_line end_line before_hash=absent after_hash test_outside moved_root backup_stage
  ob_assert_root_identity
  [[ ! -L $target ]] || cb_die "refusing linked AGENTS.md: $target"
  if [[ -e $target && ! -f $target ]]; then cb_die "AGENTS.md is not a regular file: $target"; fi
  if [[ -f $target ]]; then
    cp -P -- "$target" "$snapshot"
    [[ -f $snapshot && ! -L $snapshot ]] || cb_die "AGENTS.md became unsafe while snapshotting: $target"
    before_hash=$(cb_sha256_file "$snapshot")
    [[ -f $target && ! -L $target && $(cb_sha256_file "$target") == "$before_hash" ]] || cb_die "AGENTS.md changed during snapshot: $target"
    source=$snapshot
  fi
  starts=$(grep -c '^<!-- codex-baseline:onboarding:begin version=[^>]* -->$' "$source" 2>/dev/null || true)
  ends=$(grep -c '^<!-- codex-baseline:onboarding:end -->$' "$source" 2>/dev/null || true)
  [[ $starts -le 1 && $ends -le 1 && $starts -eq $ends ]] || cb_die "malformed onboarding markers in $target"
  stage=$(mktemp "$CB_OB_ROOT/.codex-baseline-onboard.XXXXXX")
  CB_OB_STAGE=$stage
  if [[ $starts -eq 0 ]]; then
    [[ $before_hash == absent ]] || cp -- "$source" "$stage"
    if [[ -s $stage ]]; then
      [[ $(tail -c 1 "$stage" | wc -l) -eq 1 ]] || printf '\n' >>"$stage"
      printf '\n' >>"$stage"
    fi
    cat -- "$block" >>"$stage"
  else
    start_line=$(grep -n '^<!-- codex-baseline:onboarding:begin version=[^>]* -->$' "$source" | cut -d: -f1)
    end_line=$(grep -n '^<!-- codex-baseline:onboarding:end -->$' "$source" | cut -d: -f1)
    [[ $end_line -ge $start_line ]] || cb_die "invalid onboarding marker order in $target"
    : >"$stage"
    [[ $start_line -le 1 ]] || head -n "$((start_line - 1))" -- "$source" >>"$stage"
    cat -- "$block" >>"$stage"
    tail -n "+$((end_line + 1))" -- "$source" >>"$stage"
  fi
  [[ $before_hash == absent ]] || chmod --reference="$source" "$stage"
  ob_assert_root_identity
  [[ ! -L $target ]] || cb_die "AGENTS.md became a link during apply: $target"
  after_hash=$(cb_sha256_file "$stage")
  if [[ $before_hash != absent && $after_hash == "$before_hash" ]]; then
    rm -f -- "$stage"
    CB_OB_STAGE=''
    printf 'onboarding block is already current: %s\n' "$display_target"
    return 0
  fi
  if [[ ${CODEX_BASELINE_TESTING:-0} == 1 && ${CODEX_BASELINE_TEST_ONBOARD_ROOT_SWAP:-0} == 1 ]]; then
    test_outside=${CODEX_BASELINE_TEST_ONBOARD_ROOT_SWAP_TARGET:-}
    [[ -d $test_outside && ! -L $test_outside ]] || cb_die 'root-swap test target must be an ordinary directory'
    test_outside=$(realpath -e -- "$test_outside")
    [[ $test_outside != / ]] || cb_die 'root-swap test target cannot be the filesystem root'
    moved_root="$CB_OB_ROOT_PATH.codex-baseline-test-original"
    [[ ! -e $moved_root && ! -L $moved_root ]] || cb_die "root-swap test collision: $moved_root"
    mv -T -- "$CB_OB_ROOT_PATH" "$moved_root"
    ln -s -- "$test_outside" "$CB_OB_ROOT_PATH"
  fi
  ob_assert_root_identity
  if [[ $before_hash == absent ]]; then
    [[ ! -e $target && ! -L $target ]] || cb_die "AGENTS.md appeared during apply: $target"
    ln -- "$stage" "$target" || cb_die "AGENTS.md appeared during atomic create: $target"
    rm -f -- "$stage"
    CB_OB_STAGE=''
  else
    [[ -f $target && $(cb_sha256_file "$target") == "$before_hash" ]] || cb_die "AGENTS.md changed during apply: $target"
    backup_name="AGENTS.md.codex-baseline-backup.$(date -u '+%Y%m%dT%H%M%SZ').$$"
    backup="$CB_OB_ROOT/$backup_name"
    [[ ! -e $backup ]] || cb_die "backup collision: $backup"
    backup_stage=$(mktemp "$CB_OB_ROOT/.codex-baseline-backup-stage.XXXXXX")
    CB_OB_BACKUP_STAGE=$backup_stage
    cp -p -- "$snapshot" "$backup_stage"
    [[ -f $backup_stage && ! -L $backup_stage && $(cb_sha256_file "$backup_stage") == "$before_hash" ]] || cb_die "backup staging verification failed: $backup_stage"
    ln -- "$backup_stage" "$backup" || cb_die "backup appeared during atomic create: $backup"
    rm -f -- "$backup_stage"
    CB_OB_BACKUP_STAGE=''
    [[ -f $backup && ! -L $backup && $(cb_sha256_file "$backup") == "$before_hash" ]] || cb_die "backup verification failed: $backup"
    if [[ ${CODEX_BASELINE_TESTING:-0} == 1 && ${CODEX_BASELINE_TEST_ONBOARD_RACE:-0} == 1 ]]; then
      printf '%s\n' 'concurrent-test-edit' >>"$target"
    fi
    ob_assert_root_identity
    [[ -f $target && ! -L $target && $(cb_sha256_file "$target") == "$before_hash" ]] || cb_die "AGENTS.md changed before atomic replace: $target"
    mv -T -- "$stage" "$target"
    CB_OB_STAGE=''
  fi
  ob_assert_root_identity
  printf 'onboarding block applied: %s\n' "$display_target"
  [[ -z $backup_name ]] || printf 'backup: %s/%s\n' "$CB_OB_ROOT_PATH" "$backup_name"
}

ob_report() {
  local block=$CB_OB_TEMP/block.md root_agents=absent conflict=false requires_ack=false
  ob_render_block "$block"
  [[ -f $CB_OB_ROOT/AGENTS.md ]] && root_agents=present
  if [[ -s $CB_OB_TEMP/ai ]]; then
    conflict=true
    requires_ack=true
    if [[ $(wc -l <"$CB_OB_TEMP/ai") -eq 1 ]] && grep -Fqx 'AGENTS.md' "$CB_OB_TEMP/ai" && cmp -s "$CB_OB_ROOT/AGENTS.md" "$block"; then
      requires_ack=false
    fi
  fi
  if [[ $CB_OB_JSON -eq 1 ]]; then
    printf '{"schema":2,"contract":"codex-baseline-onboarding/v2","platform":"unix","mode":"%s","repository":"%s","entries_visited":%d,"files":%d,"bytes":%d,"links_skipped":%d,"sensitive_skipped":%d,"large_skipped":%d,"root_agents":"%s","existing_instructions":%s,"existing_instructions_require_ack":%s,"existing_instructions_acknowledged":%s,"git_detected":%s,"project_commands_executed":false' \
      "$([[ $CB_OB_APPLY -eq 1 ]] && printf apply || printf dry-run)" "$(cb_json_escape "$CB_OB_ROOT_PATH")" "$CB_OB_ENTRIES" "$CB_OB_COUNT" "$CB_OB_TOTAL" "$CB_OB_LINKS" "$CB_OB_SKIPPED_SENSITIVE" "$CB_OB_SKIPPED_LARGE" "$root_agents" "$conflict" "$requires_ack" "$([[ $CB_OB_ACKNOWLEDGE_EXISTING_INSTRUCTIONS -eq 1 ]] && printf true || printf false)" "$CB_OB_GIT_DETECTED"
    for list in commands manifests ai ci docs quality tests deployment generated source-roots sensitive-areas warnings; do
      printf ',"%s":' "${list//-/_}"
      ob_json_array "$CB_OB_TEMP/$list"
    done
    printf ',"parallelism_map":'
    ob_json_parallelism_map
    printf '}\n'
  else
    printf 'Repository: %s\nMode: %s\nEntries visited: %d; static files inspected: %d (%d bytes)\nSkipped: %d links, %d sensitive paths, %d oversized/budgeted files\nProject commands executed: none\n\n' \
      "$CB_OB_ROOT_PATH" "$([[ $CB_OB_APPLY -eq 1 ]] && printf apply || printf dry-run)" "$CB_OB_ENTRIES" "$CB_OB_COUNT" "$CB_OB_TOTAL" "$CB_OB_LINKS" "$CB_OB_SKIPPED_SENSITIVE" "$CB_OB_SKIPPED_LARGE"
    ob_print_list 'Manifests and build descriptors:' "$CB_OB_TEMP/manifests"
    printf '\n'
    ob_print_list 'Existing AI instructions (review for conflicts):' "$CB_OB_TEMP/ai"
    printf 'Existing-instruction acknowledgement: %s\n' "$([[ $CB_OB_ACKNOWLEDGE_EXISTING_INSTRUCTIONS -eq 1 ]] && printf supplied || printf not-supplied)"
    printf '\n'
    ob_print_list 'CI descriptors:' "$CB_OB_TEMP/ci"
    printf '\n'
    ob_print_list 'Architecture and project documentation:' "$CB_OB_TEMP/docs"
    printf '\n'
    ob_print_list 'Test, lint, format, and type-check signals:' <(LC_ALL=C sort -u "$CB_OB_TEMP/tests" "$CB_OB_TEMP/quality")
    printf '\n'
    ob_print_list 'Deployment, container, and infrastructure signals:' "$CB_OB_TEMP/deployment"
    printf '\n'
    ob_print_list 'Likely source roots:' "$CB_OB_TEMP/source-roots"
    printf '\n'
    ob_print_list 'Generated-file signals:' "$CB_OB_TEMP/generated"
    printf '\n'
    ob_print_list 'Sensitive/risk areas by path name:' "$CB_OB_TEMP/sensitive-areas"
    printf '\nProposed managed block:\n\n'
    cat -- "$block"
  fi
  if [[ $CB_OB_APPLY -eq 1 ]]; then
    if [[ $requires_ack == true && $CB_OB_ACKNOWLEDGE_EXISTING_INSTRUCTIONS -ne 1 ]]; then
      cb_die 'existing AI instructions require --acknowledge-existing-instructions after conflict review; no repository file was changed'
    fi
    ob_apply_block "$block"
  elif [[ $CB_OB_JSON -eq 0 ]]; then
    printf '\ndry-run: no repository files changed\n'
  fi
}

main() {
  ob_parse "$@"
  ob_collect
  ob_infer_commands
  ob_build_parallelism_map
  ob_report
}

main "$@"
