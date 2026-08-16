#!/bin/sh
# shellcheck shell=bash

# Enter Bash through a fixed privileged-mode bootstrap. Bash privileged mode
# ignores BASH_ENV, inherited shell functions, SHELLOPTS, BASHOPTS, CDPATH and
# GLOBIGNORE during startup. The script drops that mode immediately afterwards;
# it is a startup hygiene boundary, not an OS privilege request.
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

# A wrapper-dispatched live benchmark reaches this dispatcher before the
# benchmark runner can scrub its environment. Retain only a non-exported shell
# value and remove every recognized API-key variable before path discovery or
# any external helper. The value is re-exported only for the final exec into the
# separately bootstrapped benchmark entrypoint.
CB_DISPATCH_BENCHMARK_KEY=${CODEX_BASELINE_BENCHMARK_API_KEY-}
export -n CB_DISPATCH_BENCHMARK_KEY 2>/dev/null || true
unset CODEX_BASELINE_BENCHMARK_API_KEY OPENAI_API_KEY CODEX_API_KEY

CB_SCRIPT_DIR=$(cd -- "$(/usr/bin/dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
CB_SOURCE_ROOT=$(cd -- "$CB_SCRIPT_DIR/.." && pwd -P)
# shellcheck source=scripts/lib/common.sh
source "$CB_SCRIPT_DIR/lib/common.sh"

CB_DRY_RUN=0
CB_JSON=0
CB_ACKNOWLEDGE_UNVERIFIED_SOURCE=0
CB_ACTIVE_TX=''
CB_LOCK_HELD=0
CB_TX_ROOT=''
CB_DRY_TX_ROOT=''
CB_NEW_TX=''
CB_MUTATION_COUNT=0
CB_VERSION='unknown'
CB_VERIFIED_SOURCE_ROOT=''
CB_TEMP_PATHS=()
CB_UPDATE_CHECK=0
CB_UPDATE_REMOTE=0
CB_UPDATE_LOCAL=0
CB_UPDATE_OFFLINE=''
CB_UPDATE_METADATA_URL='https://github.com/ShigeoAMV/codex-baseline/releases/latest/download/codex-baseline-update-v1.txt'
CB_UPDATE_MAX_ARCHIVE_BYTES=67108864
CB_UPDATE_MAX_CONTENT_BYTES=134217728
CB_UPDATE_MAX_RAW_TAR_BYTES=138412032
CB_UPDATE_TEMP_ROOT=''
CB_OPTIMIZE_MODE=check
CB_OPTIMIZE_APPLY=0
CB_OPTIMIZE_SPEED=keep
CB_CONFIG_PLAN_CHANGE=0

cb_usage() {
  cat <<'EOF'
Usage: codex-baseline <command> [options]

Commands:
  install [--dry-run] [--acknowledge-unverified-source]
                            Install from this reviewed local source tree
  update [--check|--remote|--local|--offline ARCHIVE] [--dry-run]
         [--acknowledge-unverified-source]
                            Check/apply the latest stable release; a checkout
                            remains local by default, installed runtime remote
  doctor [--json]           Inspect installation, Codex, paths, and conflicts
  optimize [--check|--restore] [--speed keep|standard|fast|ultrafast]
           [--dry-run|--apply] [--json]
                            Inspect or transactionally manage allowlisted Codex
                            agent-cap and explicit speed keys
  rollback [--dry-run]      Restore the state before the current transaction
  uninstall [--dry-run]     Remove only baseline-owned content
  onboard [options] [repo]  Perform bounded static repository discovery
  benchmark [options]       Run the maintained evaluation harness
  help                      Show this help

Global mutation rules: only installed-runtime update/--remote performs a bounded
public release fetch. No auth/session access occurs, dry-run shows targets, live
drift is a conflict, and every applied operation records a backup transaction
under CODEX_HOME/codex-baseline/state.
EOF
}

cb_print_source_provenance() {
  local root=$1 payload_hash=$2 acquisition=${3:-local-checkout}
  # Lifecycle provenance is payload-manifest based. Never ask checkout-owned Git
  # metadata for informational revision/dirty fields: status/content conversion
  # may execute repository-local filters or helpers before acknowledgement.
  printf 'source-origin: %s\nsource-revision: %s\nsource-dirty: %s\nsource-trust: unverified-source (unsigned-local-source)\nsource-acquisition: %s\nsource-payload-sha256: %s\n' \
    "$root" unversioned unknown "$acquisition" "$payload_hash"
}

cb_freeze_verified_source() {
  local source=$1 expected_manifest_hash=$2 expected_payload_hash=$3 snapshot version payload_hash manifest_hash
  snapshot=$(mktemp -d "${TMPDIR:-/tmp}/codex-baseline-source.XXXXXX")
  cb_register_temp "$snapshot"

  if [[ ${CODEX_BASELINE_TESTING:-0} == 1 && ${CODEX_BASELINE_TEST_MUTATE_SOURCE_AFTER_VERIFY:-0} == 1 ]]; then
    printf '\nsource-race-test\n' >>"$source/baseline/global/AGENTS.block.md"
  fi

  mkdir -p -- "$snapshot/scripts/lib"
  cp -p -- "$source/VERSION" "$snapshot/VERSION"
  cp -a -- "$source/baseline" "$snapshot/baseline"
  cp -p -- \
    "$source/scripts/codex-baseline.sh" "$source/scripts/codex-baseline.ps1" \
    "$source/scripts/onboard.sh" "$source/scripts/onboard.ps1" \
    "$source/scripts/benchmark.sh" "$source/scripts/benchmark.ps1" \
    "$snapshot/scripts/"
  cp -p -- "$source/scripts/lib/common.sh" "$source/scripts/lib/evaluation.sh" "$snapshot/scripts/lib/"
  cp -a -- "$source/benchmarks" "$snapshot/benchmarks"
  find -P "$snapshot" -type d -exec chmod 0755 {} +
  find -P "$snapshot" -type f -exec chmod 0644 {} +
  find -P "$snapshot/scripts" -type f -name '*.sh' -exec chmod 0755 {} +

  version=$(cb_verify_source_manifest "$snapshot")
  manifest_hash=$(cb_sha256_file "$snapshot/baseline/manifest.json")
  payload_hash=$(sed -n 's/^  "payload_hash": "\([0-9a-f]\{64\}\)",$/\1/p' "$snapshot/baseline/manifest.json")
  [[ $manifest_hash == "$expected_manifest_hash" ]] || cb_die 'source manifest changed while creating the verified snapshot'
  [[ $payload_hash == "$expected_payload_hash" ]] || cb_die 'source payload changed while creating the verified snapshot'
  [[ $version == "$CB_VERSION" ]] || cb_die 'source version changed while creating the verified snapshot'
  CB_VERIFIED_SOURCE_ROOT=$snapshot
}

cb_init_paths() {
  CB_HOME=${HOME:?HOME must be set}
  CB_CODEX_HOME=${CODEX_HOME:-"$CB_HOME/.codex"}
  CB_AGENTS_HOME=${AGENTS_HOME:-"$CB_HOME/.agents"}
  CB_ROOT="$CB_CODEX_HOME/codex-baseline"
  CB_STATE_ROOT="$CB_ROOT/state"
  CB_TX_ROOT=${CB_TX_ROOT:-$CB_STATE_ROOT}
  CB_RUNTIME="$CB_ROOT/runtime"
  CB_LOCK="$CB_STATE_ROOT/lock"
  CB_CURRENT="$CB_STATE_ROOT/current"
  CB_PENDING="$CB_STATE_ROOT/pending"
  CB_CONFIG_STATE="$CB_STATE_ROOT/config"
  CB_CONFIG_CURRENT="$CB_CONFIG_STATE/current"
  CB_CONFIG_PENDING="$CB_CONFIG_STATE/pending"
  CB_CONFIG_TX_ROOT="$CB_CONFIG_STATE/transactions"
  CB_COMPOSITE_ROOT="$CB_CONFIG_STATE/composite"
  CB_COMPOSITE_PENDING="$CB_CONFIG_STATE/composite-pending"
  CB_CONFIG_FILE="$CB_CODEX_HOME/config.toml"
  [[ $CB_HOME == /* && $CB_HOME != / && $CB_HOME != *$'\n'* && $CB_HOME != *$'\t'* ]] || cb_die "HOME must be a safe absolute directory: $CB_HOME"
  cb_assert_safe_root "$CB_CODEX_HOME"
  cb_assert_safe_root "$CB_AGENTS_HOME"
}

cb_init_mutation_roots() {
  cb_safe_mkdir_path "$CB_CODEX_HOME"
  cb_safe_mkdir_path "$CB_AGENTS_HOME"
  cb_assert_target_under "$CB_STATE_ROOT" "$CB_CODEX_HOME"
  cb_safe_mkdir_path "$CB_STATE_ROOT"
}

cb_register_temp() {
  CB_TEMP_PATHS+=("$1")
}

cb_cleanup_temps() {
  local path base
  for path in "${CB_TEMP_PATHS[@]}"; do
    [[ -n $path && $path != / ]] || continue
    base=$(basename -- "$path")
    case $base in
      codex-baseline-*) rm -rf -- "$path" ;;
      *) cb_err "refusing unexpected temporary cleanup path: $path" ;;
    esac
  done
  CB_TEMP_PATHS=()
}

cb_update_temp_root() {
  local mode owner root
  if [[ -n $CB_UPDATE_TEMP_ROOT ]]; then
    [[ -d $CB_UPDATE_TEMP_ROOT && ! -L $CB_UPDATE_TEMP_ROOT ]] || cb_die 'private update staging root changed unexpectedly'
    return
  fi
  [[ -d /tmp && ! -L /tmp ]] || cb_die 'remote/offline update requires an ordinary /tmp directory'
  mode=$(stat -c '%a' -- /tmp)
  owner=$(stat -c '%u' -- /tmp)
  [[ $mode =~ ^[0-7]{3,4}$ && ( $owner == 0 || $owner == "$EUID" ) ]] || cb_die '/tmp ownership or mode is unsafe for update staging'
  (( (8#$mode & 0022) == 0 || (8#$mode & 01000) != 0 )) || cb_die 'writable /tmp must have the sticky bit for update staging'
  root=$(mktemp -d /tmp/codex-baseline-update.XXXXXX)
  chmod 0700 -- "$root"
  [[ -d $root && ! -L $root && $(stat -c '%u' -- "$root") == "$EUID" && $(stat -c '%a' -- "$root") == 700 ]] || cb_die 'cannot establish a private update staging root'
  CB_UPDATE_TEMP_ROOT=$root
  cb_register_temp "$root"
}

cb_semver_valid() {
  [[ $1 =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]
}

cb_semver_compare() {
  local left=$1 right=$2 left_major left_minor left_patch right_major right_minor right_patch
  if ! cb_semver_valid "$left" || ! cb_semver_valid "$right"; then
    cb_die 'version comparison requires stable MAJOR.MINOR.PATCH values'
  fi
  IFS=. read -r left_major left_minor left_patch <<<"$left"
  IFS=. read -r right_major right_minor right_patch <<<"$right"
  if (( 10#$left_major != 10#$right_major )); then
    (( 10#$left_major > 10#$right_major )) && printf '1' || printf '%s' '-1'
  elif (( 10#$left_minor != 10#$right_minor )); then
    (( 10#$left_minor > 10#$right_minor )) && printf '1' || printf '%s' '-1'
  elif (( 10#$left_patch != 10#$right_patch )); then
    (( 10#$left_patch > 10#$right_patch )) && printf '1' || printf '%s' '-1'
  else
    printf '0'
  fi
}

cb_update_url_allowed() {
  [[ $1 =~ ^https://(github\.com|release-assets\.githubusercontent\.com|objects\.githubusercontent\.com)/[^[:space:]\\]*$ ]]
}

cb_fetch_update_url() {
  local url=$1 output=$2 maximum=$3 curl_path current headers body status location curl_status redirects=0 update_temp
  curl_path=$(command -v curl 2>/dev/null || true)
  [[ $curl_path == /* && -f $curl_path && ! -L $curl_path ]] || cb_die 'remote update requires an ordinary absolute curl executable'
  cb_update_temp_root
  update_temp=$CB_UPDATE_TEMP_ROOT
  current=$url
  while :; do
    cb_update_url_allowed "$current" || cb_die "update redirect host or scheme is not allowed: $current"
    headers="$update_temp/headers-$redirects"
    body="$update_temp/body-$redirects"
    set +e
    status=$(
      unset GH_TOKEN GITHUB_TOKEN OPENAI_API_KEY CODEX_API_KEY CODEX_BASELINE_BENCHMARK_API_KEY
      ulimit -f $(( (maximum + 511) / 512 ))
      "$curl_path" --disable --silent --show-error --fail-with-body \
        --proto '=https' --connect-timeout 10 --max-time 60 --max-redirs 0 \
        --request GET --dump-header "$headers" --output "$body" \
        --write-out '%{http_code}' "$current"
    )
    curl_status=$?
    set -e
    [[ $curl_status -eq 0 || $status =~ ^30[12378]$ ]] || cb_die "update download failed for $current"
    [[ -f $body && ! -L $body && $(stat -c '%s' -- "$body") -le $maximum ]] || cb_die 'update response exceeded its byte limit'
    if [[ $status == 200 ]]; then
      mv -- "$body" "$output"
      return 0
    fi
    (( redirects < 3 )) || cb_die 'update download exceeded three redirects'
    location=$(awk 'BEGIN { IGNORECASE=1 } /^Location:/ { sub(/^[^:]*:[[:space:]]*/, ""); sub(/\r$/, ""); print }' "$headers")
    [[ -n $location && $(grep -ci '^location:' "$headers") -eq 1 ]] || cb_die 'update redirect has no unique Location header'
    cb_update_url_allowed "$location" || cb_die "update redirect host or scheme is not allowed: $location"
    current=$location
    redirects=$((redirects + 1))
  done
}

cb_copy_update_input() {
  local source=$1 output=$2 maximum=$3 copy_status fd identity captured_hash pre_copy_hash post_copy_hash replacement error=''
  [[ -f $source && ! -L $source ]] || cb_die "update input is not an ordinary file: $source"
  exec {fd}<"$source" || cb_die 'cannot open update input for freezing'
  [[ -f /proc/self/fd/$fd && ! -L $source ]] || error='update input changed before it could be frozen'
  if [[ -z $error ]]; then
    identity=$(stat -Lc '%d:%i' -- "/proc/self/fd/$fd")
    [[ $(stat -Lc '%d:%i' -- "$source") == "$identity" ]] || error='update input identity changed before it could be frozen'
  fi
  if [[ -z $error && $(stat -Lc '%s' -- "/proc/self/fd/$fd") -gt $maximum ]]; then error='update input exceeded its byte limit before it could be frozen'; fi
  if [[ -z $error ]]; then
    if command -v sha256sum >/dev/null 2>&1; then
      pre_copy_hash=$(head -c $((maximum + 1)) -- "/proc/self/fd/$fd" | sha256sum | awk '{print $1}')
    else
      pre_copy_hash=$(head -c $((maximum + 1)) -- "/proc/self/fd/$fd" | shasum -a 256 | awk '{print $1}')
    fi
  fi
  if [[ -z $error && ${CODEX_BASELINE_TESTING:-0} == 1 && ${CODEX_BASELINE_TEST_MUTATE_UPDATE_INPUT:-0} == 1 ]]; then
    replacement=${CODEX_BASELINE_TEST_MUTATE_UPDATE_INPUT_PATH:-}
    [[ -f $replacement && ! -L $replacement ]] || cb_die 'test update-input replacement is not an ordinary file'
    cp --reflink=never -- "$replacement" "$source"
  fi
  if [[ -z $error && ${CODEX_BASELINE_TESTING:-0} == 1 && ${CODEX_BASELINE_TEST_SUBSTITUTE_UPDATE_INPUT:-0} == 1 ]]; then
    mv -- "$source" "$source.original"
    cp --reflink=never -- "$source.original" "$source"
  fi
  if [[ ${CODEX_BASELINE_TESTING:-0} == 1 && ${CODEX_BASELINE_TEST_GROW_UPDATE_INPUT:-0} == 1 ]]; then
    truncate -s $((maximum + 1)) -- "$source"
  fi
  if [[ -z $error ]]; then
    set +e
    head -c $((maximum + 1)) <&$fd >"$output"
    copy_status=$?
    set -e
    [[ $copy_status -eq 0 && -f $output && ! -L $output ]] || error='cannot freeze update input'
  fi
  if [[ -z $error && $(stat -c '%s' -- "$output") -gt $maximum ]]; then error='update input exceeded its byte limit while it was frozen'; fi
  if [[ -z $error && ( ! -f $source || -L $source || $(stat -Lc '%d:%i' -- "$source") != "$identity" ) ]]; then
    error='update input identity changed while it was frozen'
  fi
  if [[ -z $error && $(stat -Lc '%s' -- "/proc/self/fd/$fd") -gt $maximum ]]; then error='update input exceeded its byte limit while it was frozen'; fi
  if [[ -z $error ]]; then
    captured_hash=$(cb_sha256_file "$output")
    if command -v sha256sum >/dev/null 2>&1; then
      post_copy_hash=$(head -c $((maximum + 1)) -- "/proc/self/fd/$fd" | sha256sum | awk '{print $1}')
    else
      post_copy_hash=$(head -c $((maximum + 1)) -- "/proc/self/fd/$fd" | shasum -a 256 | awk '{print $1}')
    fi
    [[ $pre_copy_hash == "$captured_hash" && $captured_hash == "$post_copy_hash" ]] || error='update input changed while it was frozen'
  fi
  exec {fd}<&-
  [[ -z $error ]] || cb_die "$error"
}

cb_read_update_descriptor() {
  local descriptor=$1 byte_count last_byte
  local -a lines
  byte_count=$(stat -c '%s' -- "$descriptor")
  [[ $byte_count -gt 0 && $byte_count -le 16384 ]] || cb_die 'update descriptor size is invalid'
  last_byte=$(od -An -tuC -j $((byte_count - 1)) -N 1 "$descriptor" | tr -d ' ')
  [[ $last_byte == 10 ]] || cb_die 'update descriptor must end with LF'
  if LC_ALL=C grep -n '[^ -~]' "$descriptor" >/dev/null; then cb_die 'update descriptor contains non-ASCII or control bytes'; fi
  mapfile -t lines <"$descriptor"
  [[ ${#lines[@]} -eq 10 ]] || cb_die 'update descriptor must contain exactly ten lines'
  [[ ${lines[0]} == 'contract=codex-baseline-update/v1' ]] || cb_die 'update descriptor contract is unsupported'
  CB_UPDATE_VERSION=${lines[1]#version=}
  CB_UPDATE_TAG=${lines[2]#tag=}
  CB_UPDATE_TRUST=${lines[3]#trust=}
  CB_UPDATE_TAR_NAME=${lines[4]#tar_name=}
  CB_UPDATE_TAR_BYTES=${lines[5]#tar_bytes=}
  CB_UPDATE_TAR_SHA256=${lines[6]#tar_sha256=}
  CB_UPDATE_ZIP_NAME=${lines[7]#zip_name=}
  CB_UPDATE_ZIP_BYTES=${lines[8]#zip_bytes=}
  CB_UPDATE_ZIP_SHA256=${lines[9]#zip_sha256=}
  [[ ${lines[1]} == "version=$CB_UPDATE_VERSION" && ${lines[2]} == "tag=$CB_UPDATE_TAG" && \
     ${lines[3]} == "trust=$CB_UPDATE_TRUST" && ${lines[4]} == "tar_name=$CB_UPDATE_TAR_NAME" && \
     ${lines[5]} == "tar_bytes=$CB_UPDATE_TAR_BYTES" && ${lines[6]} == "tar_sha256=$CB_UPDATE_TAR_SHA256" && \
     ${lines[7]} == "zip_name=$CB_UPDATE_ZIP_NAME" && ${lines[8]} == "zip_bytes=$CB_UPDATE_ZIP_BYTES" && \
     ${lines[9]} == "zip_sha256=$CB_UPDATE_ZIP_SHA256" ]] || cb_die 'update descriptor field order or names are invalid'
  cb_semver_valid "$CB_UPDATE_VERSION" || cb_die 'update descriptor version is not stable MAJOR.MINOR.PATCH'
  [[ $CB_UPDATE_TAG == "v$CB_UPDATE_VERSION" && $CB_UPDATE_TRUST == unsigned-github-release ]] || cb_die 'update descriptor version/tag/trust binding is invalid'
  [[ $CB_UPDATE_TAR_NAME == "codex-baseline-$CB_UPDATE_VERSION.tar.gz" && \
     $CB_UPDATE_ZIP_NAME == "codex-baseline-$CB_UPDATE_VERSION.zip" ]] || cb_die 'update descriptor asset name is invalid'
  [[ $CB_UPDATE_TAR_BYTES =~ ^[1-9][0-9]*$ && $CB_UPDATE_TAR_BYTES -le $CB_UPDATE_MAX_ARCHIVE_BYTES && \
     $CB_UPDATE_ZIP_BYTES =~ ^[1-9][0-9]*$ && $CB_UPDATE_ZIP_BYTES -le $CB_UPDATE_MAX_ARCHIVE_BYTES ]] || cb_die 'update descriptor asset size is invalid'
  [[ $CB_UPDATE_TAR_SHA256 =~ ^[0-9a-f]{64}$ && $CB_UPDATE_ZIP_SHA256 =~ ^[0-9a-f]{64}$ ]] || cb_die 'update descriptor asset SHA-256 is invalid'
}

cb_validate_update_path() {
  local path=$1 trimmed segment base upper depth
  [[ $path =~ ^[A-Za-z0-9._/-]+$ && $path != /* && $path != *'//' ]] || cb_die "unsafe update archive path: $path"
  trimmed=${path%/}
  [[ -n $trimmed && ${#trimmed} -le 240 ]] || cb_die "update archive path length is invalid: $path"
  IFS=/ read -r -a CB_UPDATE_PATH_PARTS <<<"$trimmed"
  depth=${#CB_UPDATE_PATH_PARTS[@]}
  (( depth <= 8 )) || cb_die "update archive path is too deep: $path"
  for segment in "${CB_UPDATE_PATH_PARTS[@]}"; do
    [[ -n $segment && $segment != . && $segment != .. && $segment != *: && $segment != *':'* && $segment != *'.' && $segment != *' ' ]] || cb_die "unsafe update archive path segment: $path"
    base=${segment%%.*}
    upper=${base^^}
    case $upper in CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9]) cb_die "Windows device name is forbidden in update archive: $path" ;; esac
    [[ ${segment,,} != .git ]] || cb_die "Git metadata is forbidden in update archive: $path"
  done
}

cb_validate_raw_tar_headers() {
  local raw=$1 raw_bytes offset=0 type size_field size advance headers=0
  if ! command -v dd >/dev/null 2>&1 || ! command -v od >/dev/null 2>&1; then
    cb_die 'tar.gz update requires coreutils dd and od'
  fi
  raw_bytes=$(stat -c '%s' -- "$raw")
  (( raw_bytes > 0 && raw_bytes <= CB_UPDATE_MAX_RAW_TAR_BYTES && raw_bytes % 512 == 0 )) || cb_die 'update archive raw tar size is invalid'
  while (( offset + 512 <= raw_bytes )); do
    type=$(od -An -tuC -j $((offset + 156)) -N 1 -- "$raw" | tr -d ' ')
    size_field=$(dd if="$raw" bs=1 skip=$((offset + 124)) count=12 status=none | tr -d '\000 ')
    if [[ -z $size_field && $type == 0 ]]; then
      offset=$((offset + 512))
      continue
    fi
    [[ $type == 0 || $type == 48 || $type == 53 ]] || cb_die 'PAX, GNU, sparse, linked, or special tar headers are forbidden'
    [[ $size_field =~ ^[0-7]{1,11}$ ]] || cb_die 'update archive tar header size is not canonical octal'
    size=$((8#$size_field))
    [[ $type != 53 || $size -eq 0 ]] || cb_die 'update archive directory header has content'
    advance=$((512 + ((size + 511) / 512) * 512))
    offset=$((offset + advance))
    (( offset <= raw_bytes )) || cb_die 'update archive tar header exceeds the raw stream'
    headers=$((headers + 1))
  done
  (( headers > 0 && offset == raw_bytes )) || cb_die 'update archive raw tar structure is invalid'
}

cb_validate_and_extract_tar() {
  local archive=$1 expected_version=${2:-} extract_root=$3 listing verbose raw gzip_status count=0 total=0 line kind name size root='' duplicate folded update_temp
  local -A case_seen=()
  command -v gzip >/dev/null 2>&1 || cb_die 'tar.gz update requires gzip'
  command -v tar >/dev/null 2>&1 || cb_die 'tar.gz update requires tar'
  tar --version 2>/dev/null | grep -q 'GNU tar' || cb_die 'tar.gz update requires GNU tar'
  cb_update_temp_root
  update_temp=$CB_UPDATE_TEMP_ROOT
  raw="$update_temp/raw.tar"
  listing="$update_temp/listing"
  verbose="$update_temp/verbose"
  set +e
  ( ulimit -f $(( (CB_UPDATE_MAX_RAW_TAR_BYTES + 1023) / 1024 )); gzip -cd -- "$archive" >"$raw" ) 2>/dev/null
  gzip_status=$?
  set -e
  [[ $gzip_status -eq 0 && $(stat -c '%s' -- "$raw") -le $CB_UPDATE_MAX_RAW_TAR_BYTES ]] || cb_die 'update archive gzip stream is invalid or exceeds the raw tar limit'
  cb_validate_raw_tar_headers "$raw"
  tar --list --file "$raw" --quoting-style=escape >"$listing" || cb_die 'cannot list update archive'
  tar --list --verbose --numeric-owner --file "$raw" --quoting-style=escape >"$verbose" || cb_die 'cannot inspect update archive types'
  [[ $(wc -l <"$listing") -eq $(wc -l <"$verbose") ]] || cb_die 'update archive inventory/type listing disagrees'
  duplicate=$(LC_ALL=C sort "$listing" | uniq -d | head -n 1)
  [[ -z $duplicate ]] || cb_die "duplicate update archive member: $duplicate"
  while IFS= read -r line && IFS= read -r name <&3; do
    count=$((count + 1))
    (( count <= 512 )) || cb_die 'update archive contains too many entries'
    kind=${line:0:1}
    [[ $kind == - || $kind == d ]] || cb_die "linked or special update archive member is forbidden: $name"
    [[ $(awk '{print NF}' <<<"$line") -eq 6 && $(awk '{print $6}' <<<"$line") == "$name" ]] || cb_die 'update archive verbose inventory is not canonical'
    cb_validate_update_path "$name"
    folded=${name,,}
    [[ -z ${case_seen[$folded]+x} ]] || cb_die "case-colliding update archive member: $name"
    case_seen[$folded]=1
    if [[ -z $root ]]; then root=${name%%/*}; fi
    [[ ${name%%/*} == "$root" ]] || cb_die 'update archive must contain one top-level source root'
    if [[ $kind == - ]]; then
      size=$(awk '{print $3}' <<<"$line")
      [[ $size =~ ^[0-9]+$ ]] || cb_die "update archive member size is invalid: $name"
      total=$((total + size))
      (( total <= CB_UPDATE_MAX_CONTENT_BYTES )) || cb_die 'update archive uncompressed content exceeds 128 MiB'
    fi
  done <"$verbose" 3<"$listing"
  (( count > 0 )) || cb_die 'update archive is empty'
  [[ $root =~ ^codex-baseline-((0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*))$ ]] || cb_die 'update archive root has an invalid version'
  CB_UPDATE_ARCHIVE_VERSION=${BASH_REMATCH[1]}
  [[ -z $expected_version || $CB_UPDATE_ARCHIVE_VERSION == "$expected_version" ]] || cb_die 'update descriptor and archive root version disagree'
  mkdir -p -- "$extract_root"
  tar --extract --file "$raw" --directory "$extract_root" --no-same-owner --no-same-permissions --delay-directory-restore || cb_die 'cannot extract update archive'
  CB_UPDATE_SOURCE_ROOT="$extract_root/$root"
  [[ -d $CB_UPDATE_SOURCE_ROOT && ! -L $CB_UPDATE_SOURCE_ROOT ]] || cb_die 'extracted update source root is unsafe'
  if find -P "$CB_UPDATE_SOURCE_ROOT" -mindepth 1 ! -type f ! -type d -print -quit | grep -q .; then cb_die 'extracted update source contains a linked or special object'; fi
}

cb_verify_update_source_inventory() {
  local root=$1 expected actual version line path update_temp
  version=$(cb_verify_source_manifest "$root")
  cb_update_temp_root
  update_temp=$CB_UPDATE_TEMP_ROOT
  expected="$update_temp/expected-inventory"
  actual="$update_temp/actual-inventory"
  printf '%s\n' baseline/manifest.json >"$expected"
  while IFS= read -r line; do
    path=$(sed -n 's/^    {"path": "\([A-Za-z0-9._\/-]*\)", "bytes": [0-9][0-9]*, "sha256": "[0-9a-f][0-9a-f]*"}[,]*$/\1/p' <<<"$line")
    [[ -n $path ]] || cb_die 'cannot derive update inventory from source manifest'
    printf '%s\n' "$path" >>"$expected"
  done < <(grep '^    {"path": ' "$root/baseline/manifest.json")
  find -P "$root" -type f -printf '%P\n' | LC_ALL=C sort >"$actual"
  LC_ALL=C sort -u -o "$expected" "$expected"
  cmp -s "$expected" "$actual" || cb_die 'update archive file inventory differs from manifest payload plus manifest'
  printf '%s' "$version"
}

cb_release_lock() {
  if [[ $CB_LOCK_HELD -eq 1 && -d $CB_LOCK ]]; then
    rm -f -- "$CB_LOCK/pid" "$CB_LOCK/proc_start"
    rmdir -- "$CB_LOCK" 2>/dev/null || true
  fi
  CB_LOCK_HELD=0
}

cb_process_start() {
  local pid=$1
  if [[ -r /proc/$pid/stat ]]; then
    awk '{print $22}' "/proc/$pid/stat"
  else
    printf 'unknown'
  fi
}

cb_acquire_lock() {
  local pid start recorded_pid recorded_start
  cb_safe_mkdir_path "$CB_STATE_ROOT"
  [[ ! -L $CB_LOCK ]] || cb_die "operation lock is a symbolic link: $CB_LOCK"
  if mkdir -- "$CB_LOCK" 2>/dev/null; then
    cb_write_field "$CB_LOCK/pid" "$$"
    cb_write_field "$CB_LOCK/proc_start" "$(cb_process_start "$$")"
    CB_LOCK_HELD=1
    return
  fi
  recorded_pid=$(cb_read_field "$CB_LOCK/pid")
  recorded_start=$(cb_read_field "$CB_LOCK/proc_start")
  if [[ $recorded_pid =~ ^[0-9]+$ ]] && kill -0 "$recorded_pid" 2>/dev/null; then
    start=$(cb_process_start "$recorded_pid")
    if [[ $recorded_start == unknown || $start == "$recorded_start" ]]; then
      cb_die "another baseline operation holds the lock (pid $recorded_pid)"
    fi
  fi
  cb_err 'recovering stale operation lock'
  rm -f -- "$CB_LOCK/pid" "$CB_LOCK/proc_start"
  rmdir -- "$CB_LOCK" || cb_die "cannot recover stale lock: $CB_LOCK"
  mkdir -- "$CB_LOCK" || cb_die 'cannot acquire recovered lock'
  cb_write_field "$CB_LOCK/pid" "$$"
  cb_write_field "$CB_LOCK/proc_start" "$(cb_process_start "$$")"
  CB_LOCK_HELD=1
}

cb_require_tx_id() {
  [[ $1 =~ ^[0-9]{8}T[0-9]{6}Z-[0-9]+-[0-9]+$ ]] || cb_die "invalid transaction id: $1"
}

cb_require_scalar_file() {
  local path=$1 label=$2 lines bytes
  [[ -f $path && ! -L $path ]] || cb_die "missing or unsafe transaction field $label: $path"
  lines=$(wc -l <"$path")
  bytes=$(wc -c <"$path")
  [[ $lines -eq 1 && $bytes -le 4096 ]] || cb_die "transaction field is not a bounded scalar ($label): $path"
}

cb_valid_hash() {
  [[ $1 == absent || $1 =~ ^[0-9a-f]{64}$ ]]
}

cb_expected_object() {
  local id=$1
  CB_EXPECTED_TARGET_ALT=''
  case $id in
    00) CB_EXPECTED_KIND=block; CB_EXPECTED_ROOT=$CB_CODEX_HOME; CB_EXPECTED_TARGET=$CB_CODEX_HOME/AGENTS.md; CB_EXPECTED_TARGET_ALT=$CB_CODEX_HOME/AGENTS.override.md; CB_EXPECTED_SOURCE=baseline/global/AGENTS.block.md ;;
    10) CB_EXPECTED_KIND=tree; CB_EXPECTED_ROOT=$CB_AGENTS_HOME; CB_EXPECTED_TARGET=$CB_AGENTS_HOME/skills/codex-baseline-repo-onboarding; CB_EXPECTED_SOURCE=baseline/skills/codex-baseline-repo-onboarding ;;
    11) CB_EXPECTED_KIND=tree; CB_EXPECTED_ROOT=$CB_AGENTS_HOME; CB_EXPECTED_TARGET=$CB_AGENTS_HOME/skills/codex-baseline-deep-work; CB_EXPECTED_SOURCE=baseline/skills/codex-baseline-deep-work ;;
    12) CB_EXPECTED_KIND=tree; CB_EXPECTED_ROOT=$CB_AGENTS_HOME; CB_EXPECTED_TARGET=$CB_AGENTS_HOME/skills/codex-baseline-conformance-review; CB_EXPECTED_SOURCE=baseline/skills/codex-baseline-conformance-review ;;
    13) CB_EXPECTED_KIND=tree; CB_EXPECTED_ROOT=$CB_AGENTS_HOME; CB_EXPECTED_TARGET=$CB_AGENTS_HOME/skills/codex-baseline-retrospective; CB_EXPECTED_SOURCE=baseline/skills/codex-baseline-retrospective ;;
    20) CB_EXPECTED_KIND='file'; CB_EXPECTED_ROOT=$CB_CODEX_HOME; CB_EXPECTED_TARGET=$CB_CODEX_HOME/agents/codex-baseline-reviewer.toml; CB_EXPECTED_SOURCE=baseline/agents/codex-baseline-reviewer.toml ;;
    30) CB_EXPECTED_KIND=tree; CB_EXPECTED_ROOT=$CB_CODEX_HOME; CB_EXPECTED_TARGET=$CB_RUNTIME; CB_EXPECTED_SOURCE=runtime ;;
    31) CB_EXPECTED_KIND='file'; CB_EXPECTED_ROOT=$CB_HOME; CB_EXPECTED_TARGET=$CB_HOME/.local/bin/codex-baseline; CB_EXPECTED_SOURCE=generated-wrapper ;;
    *) cb_die "unexpected transaction object id: $id" ;;
  esac
}

cb_validate_object_contract() {
  local tx=$1 obj=$2 id kind target root desired previous desired_present previous_existed change status previous_kind
  local field value stage old parent base expected_prefix source
  id=$(basename -- "$obj")
  [[ $id =~ ^(00|10|11|12|13|20|30|31)$ && -d $obj && ! -L $obj ]] || cb_die "unsafe transaction object: $obj"
  while IFS= read -r -d '' entry; do
    field=$(basename -- "$entry")
    case $field in
      kind|target|root|desired_hash|desired_present|source|status|previous_hash|previous_kind|previous_existed|previous_managed_existed|previous_file_hash|change|stage|old|backup|backup_file|backup_hash|desired_file_hash|installed_hash|installed_file_hash|restore_source|restore_mode) ;;
      *) cb_die "unexpected transaction object field: $entry" ;;
    esac
    [[ ! -L $entry ]] || cb_die "symbolic transaction object entry is not allowed: $entry"
  done < <(find -P "$obj" -mindepth 1 -maxdepth 1 -print0 | LC_ALL=C sort -z)
  cb_expected_object "$id"
  for field in kind target root desired_hash desired_present source status previous_hash previous_kind previous_existed change; do
    cb_require_scalar_file "$obj/$field" "$id/$field"
  done
  kind=$(cb_read_field "$obj/kind")
  target=$(cb_read_field "$obj/target")
  root=$(cb_read_field "$obj/root")
  desired=$(cb_read_field "$obj/desired_hash")
  desired_present=$(cb_read_field "$obj/desired_present")
  previous=$(cb_read_field "$obj/previous_hash")
  previous_kind=$(cb_read_field "$obj/previous_kind")
  previous_existed=$(cb_read_field "$obj/previous_existed")
  change=$(cb_read_field "$obj/change")
  status=$(cb_read_field "$obj/status")
  source=$(cb_read_field "$obj/source")
  [[ $kind == "$CB_EXPECTED_KIND" && $root == "$CB_EXPECTED_ROOT" ]] || cb_die "transaction object contract mismatch: $obj"
  [[ $target == "$CB_EXPECTED_TARGET" || ( -n $CB_EXPECTED_TARGET_ALT && $target == "$CB_EXPECTED_TARGET_ALT" ) ]] || cb_die "unexpected managed target in transaction: $target"
  [[ $source == "$CB_EXPECTED_SOURCE" || $source =~ ^rollback:[0-9]{8}T[0-9]{6}Z-[0-9]+-[0-9]+/$id$ ]] || cb_die "unexpected transaction source label: $source"
  cb_assert_target_under "$target" "$root"
  [[ $desired_present =~ ^[01]$ && $previous_existed =~ ^[01]$ && $change =~ ^[01]$ ]] || cb_die "invalid boolean transaction field: $obj"
  if ! cb_valid_hash "$desired" || ! cb_valid_hash "$previous"; then cb_die "invalid transaction hash: $obj"; fi
  case $previous_kind in absent|file|tree|block) ;; *) cb_die "invalid previous kind in transaction: $obj" ;; esac
  case $status in planned|prepared|ready|moving-old|old-moved|new-moved|committed|unchanged|rolled-back) ;; *) cb_die "invalid object status in transaction: $obj" ;; esac
  if [[ $kind == block ]]; then
    cb_require_scalar_file "$obj/previous_managed_existed" "$id/previous_managed_existed"
    [[ $(cb_read_field "$obj/previous_managed_existed") =~ ^[01]$ ]] || cb_die "invalid previous-managed flag: $obj"
    cb_require_scalar_file "$obj/previous_file_hash" "$id/previous_file_hash"
    cb_valid_hash "$(cb_read_field "$obj/previous_file_hash")" || cb_die "invalid previous physical hash: $obj"
    if [[ $change == 1 && $desired_present == 1 ]]; then
      case $status in
        prepared|ready|moving-old|old-moved|new-moved|committed)
          cb_require_scalar_file "$obj/desired_file_hash" "$id/desired_file_hash"
          cb_valid_hash "$(cb_read_field "$obj/desired_file_hash")" || cb_die "invalid desired physical hash: $obj"
          ;;
      esac
    fi
  fi
  for field in installed_hash installed_file_hash desired_file_hash backup_hash; do
    if [[ -e $obj/$field || -L $obj/$field ]]; then
      cb_require_scalar_file "$obj/$field" "$id/$field"
      value=$(cb_read_field "$obj/$field")
      cb_valid_hash "$value" || cb_die "invalid optional transaction hash: $obj/$field"
    fi
  done
  parent=$(dirname -- "$target")
  if [[ -e $obj/stage || -L $obj/stage ]]; then
    cb_require_scalar_file "$obj/stage" "$id/stage"
    stage=$(cb_read_field "$obj/stage")
    base=$(basename -- "$stage")
    expected_prefix=".codex-baseline-stage-$tx-$id"
    [[ $(dirname -- "$stage") == "$parent" && ( $base == "$expected_prefix.delete" || $base == "$expected_prefix".[A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9] ) ]] || cb_die "invalid transaction stage path: $stage"
    cb_assert_target_under "$stage" "$root"
  fi
  if [[ -e $obj/old || -L $obj/old ]]; then
    cb_require_scalar_file "$obj/old" "$id/old"
    old=$(cb_read_field "$obj/old")
    base=$(basename -- "$old")
    expected_prefix=".codex-baseline-old-$tx-$id"
    [[ $(dirname -- "$old") == "$parent" && $base == "$expected_prefix".[A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9] ]] || cb_die "invalid transaction old path: $old"
    cb_assert_target_under "$old" "$root"
  fi
}

cb_validate_tx() {
  local tx=$1 expected_state=${2:-} transaction_root=${3:-$CB_TX_ROOT} dir state operation parent entry rollback_target result_current
  local obj id restore_mode restore_source expected_source rollback_parent source_operation object_status
  local actual_ids expected_ids
  cb_require_tx_id "$tx"
  dir="$transaction_root/transactions/$tx"
  [[ $(dirname -- "$dir") == "$transaction_root/transactions" && -d $dir && ! -L $dir ]] || cb_die "unsafe or missing transaction directory: $dir"
  while IFS= read -r -d '' entry; do
    case $(basename -- "$entry") in
      schema|operation|version|created_utc|parent|state|objects|rollback_target|result_current) ;;
      *) cb_die "unexpected transaction field: $entry" ;;
    esac
    [[ ! -L $entry ]] || cb_die "symbolic transaction entry is not allowed: $entry"
  done < <(find -P "$dir" -mindepth 1 -maxdepth 1 -print0 | LC_ALL=C sort -z)
  for entry in schema operation version created_utc parent state; do cb_require_scalar_file "$dir/$entry" "$tx/$entry"; done
  [[ $(cb_read_field "$dir/schema") == "$CB_SCHEMA" ]] || cb_die "unsupported transaction schema: $tx"
  operation=$(cb_read_field "$dir/operation")
  case $operation in install|update|rollback|uninstall) ;; *) cb_die "invalid transaction operation: $tx" ;; esac
  state=$(cb_read_field "$dir/state")
  case $state in planned|prepared|committing|recovering|committed|rolled-back) ;; *) cb_die "invalid transaction state: $tx" ;; esac
  [[ -z $expected_state || $state == "$expected_state" ]] || cb_die "transaction $tx is not $expected_state"
  parent=$(cb_read_field "$dir/parent")
  [[ $(cb_read_field "$dir/version") =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || cb_die "invalid transaction version: $tx"
  [[ $(cb_read_field "$dir/created_utc") =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || cb_die "invalid transaction timestamp: $tx"
  if [[ -n $parent ]]; then
    cb_require_tx_id "$parent"
    [[ $parent != "$tx" ]] || cb_die "transaction cannot parent itself: $tx"
    [[ -d $CB_STATE_ROOT/transactions/$parent && ! -L $CB_STATE_ROOT/transactions/$parent ]] || cb_die "transaction parent is missing: $parent"
    cb_require_scalar_file "$CB_STATE_ROOT/transactions/$parent/state" "$parent/state"
    [[ $(cb_read_field "$CB_STATE_ROOT/transactions/$parent/state") == committed ]] || cb_die "transaction parent is not committed: $parent"
  fi
  [[ -d $dir/objects && ! -L $dir/objects ]] || cb_die "transaction object directory is unsafe: $tx"
  actual_ids=''
  while IFS= read -r -d '' entry; do
    [[ -d $entry && ! -L $entry ]] || cb_die "unexpected entry in transaction objects: $entry"
    if [[ -n $actual_ids ]]; then actual_ids+=','; fi
    actual_ids+=$(basename -- "$entry")
    cb_validate_object_contract "$tx" "$entry"
  done < <(find -P "$dir/objects" -mindepth 1 -maxdepth 1 -print0 | LC_ALL=C sort -z)
  if [[ $operation == install || $operation == update ]]; then
    [[ $actual_ids == '00,10,11,12,13,20,30,31' ]] || cb_die "transaction has an incomplete object inventory: $tx"
  fi
  if [[ $state == committed ]]; then
    while IFS= read -r -d '' obj; do
      object_status=$(cb_read_field "$obj/status")
      case $object_status in committed|unchanged) ;; *) cb_die "committed transaction contains incomplete object state: $obj" ;; esac
      if [[ $(cb_read_field "$obj/change") == 1 ]]; then
        [[ $object_status == committed ]] || cb_die "committed transaction change/status mismatch: $obj"
      else
        [[ $object_status == unchanged ]] || cb_die "committed transaction change/status mismatch: $obj"
      fi
    done < <(find -P "$dir/objects" -mindepth 1 -maxdepth 1 -type d -print0 | LC_ALL=C sort -z)
  fi
  for entry in rollback_target result_current; do
    if [[ -e $dir/$entry || -L $dir/$entry ]]; then
      cb_require_scalar_file "$dir/$entry" "$tx/$entry"
      value=$(cb_read_field "$dir/$entry")
      if [[ -n $value ]]; then cb_require_tx_id "$value"; fi
    fi
  done
  rollback_target=$(cb_read_field "$dir/rollback_target")
  result_current=$(cb_read_field "$dir/result_current")
  if [[ $operation == rollback || $operation == uninstall ]]; then
    [[ -n $rollback_target && $parent == "$rollback_target" ]] || cb_die "rollback transaction target/parent mismatch: $tx"
    cb_require_tx_id "$rollback_target"
    [[ -d $CB_STATE_ROOT/transactions/$rollback_target && ! -L $CB_STATE_ROOT/transactions/$rollback_target ]] || cb_die "rollback source transaction is missing: $rollback_target"
    source_operation=$(cb_read_field "$CB_STATE_ROOT/transactions/$rollback_target/operation")
    [[ $source_operation == install || $source_operation == update ]] || cb_die "rollback source transaction has an invalid operation: $rollback_target"
    cb_validate_tx "$rollback_target" committed "$CB_STATE_ROOT"
    rollback_parent=$(cb_read_field "$CB_STATE_ROOT/transactions/$rollback_target/parent")
    [[ $result_current == "$rollback_parent" ]] || cb_die "rollback result-current mismatch: $tx"
    if [[ $operation == uninstall ]]; then
      expected_ids='00,10,11,12,13,20,30,31'
    else
      expected_ids=''
      while IFS= read -r -d '' obj; do
        [[ $(cb_read_field "$obj/status") == committed ]] || continue
        if [[ -n $expected_ids ]]; then expected_ids+=','; fi
        expected_ids+=$(basename -- "$obj")
      done < <(find -P "$CB_STATE_ROOT/transactions/$rollback_target/objects" -mindepth 1 -maxdepth 1 -type d -print0 | LC_ALL=C sort -z)
    fi
    [[ -n $expected_ids && $actual_ids == "$expected_ids" ]] || cb_die "rollback transaction has an incomplete object inventory: $tx"
    while IFS= read -r -d '' obj; do
      id=$(basename -- "$obj")
      cb_require_scalar_file "$obj/restore_mode" "$id/restore_mode"
      cb_require_scalar_file "$obj/restore_source" "$id/restore_source"
      restore_mode=$(cb_read_field "$obj/restore_mode")
      restore_source=$(cb_read_field "$obj/restore_source")
      case $restore_mode in
        delete) expected_source=:delete ;;
        remove-block) expected_source=:remove-block ;;
        full-file) expected_source="$CB_STATE_ROOT/transactions/$rollback_target/objects/$id/backup_file" ;;
        restore) expected_source="$CB_STATE_ROOT/transactions/$rollback_target/objects/$id/backup" ;;
        *) cb_die "invalid restore mode in transaction: $obj" ;;
      esac
      [[ $restore_source == "$expected_source" ]] || cb_die "invalid restore source in transaction: $obj"
    done < <(find -P "$dir/objects" -mindepth 1 -maxdepth 1 -type d -print0 | LC_ALL=C sort -z)
  else
    [[ -z $rollback_target && -z $result_current ]] || cb_die "unexpected rollback metadata: $tx"
  fi
}

cb_read_tx_pointer() {
  local path=$1 value
  value=$(cb_read_field "$path")
  [[ -z $value ]] || cb_require_tx_id "$value"
  printf '%s' "$value"
}

cb_tx_dir() {
  cb_require_tx_id "$1"
  printf '%s/transactions/%s' "$CB_TX_ROOT" "$1"
}

cb_live_tx_dir() {
  cb_require_tx_id "$1"
  printf '%s/transactions/%s' "$CB_STATE_ROOT" "$1"
}

cb_set_tx_state() {
  case $2 in planned|prepared|committing|recovering|committed|rolled-back|no-op|dry-run) ;; *) cb_die "invalid transaction state transition target: $2" ;; esac
  cb_write_field "$(cb_tx_dir "$1")/state" "$2"
}

cb_new_tx() {
  local operation=$1 id dir parent
  id=$(date -u '+%Y%m%dT%H%M%SZ')-$$-$RANDOM
  dir=$(cb_tx_dir "$id")
  cb_safe_mkdir_path "$dir/objects"
  cb_write_field "$dir/schema" "$CB_SCHEMA"
  cb_write_field "$dir/operation" "$operation"
  cb_write_field "$dir/version" "$CB_VERSION"
  cb_write_field "$dir/created_utc" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  parent=$(cb_current_tx)
  cb_write_field "$dir/parent" "$parent"
  cb_set_tx_state "$id" planned
  CB_ACTIVE_TX=$id
  CB_NEW_TX=$id
}

cb_discard_tx() {
  local tx=$1 dir parent
  [[ $tx =~ ^[0-9]{8}T[0-9]{6}Z-[0-9]+-[0-9]+$ ]] || cb_die "invalid transaction id: $tx"
  dir=$(cb_tx_dir "$tx")
  parent=$(dirname -- "$dir")
  [[ $parent == "$CB_TX_ROOT/transactions" ]] || cb_die "transaction path escaped state root: $dir"
  rm -rf -- "$dir"
  cb_sync_file "$parent"
}

cb_current_tx() {
  cb_read_tx_pointer "$CB_CURRENT"
}

cb_find_current_object() {
  local target=$1 current obj object_target
  current=$(cb_current_tx)
  [[ -n $current && -d $(cb_live_tx_dir "$current")/objects ]] || return 1
  for obj in "$(cb_live_tx_dir "$current")"/objects/*; do
    [[ -d $obj ]] || continue
    object_target=$(cb_read_field "$obj/target")
    if [[ $object_target == "$target" ]]; then
      printf '%s' "$obj"
      return 0
    fi
  done
  return 1
}

cb_live_hash() {
  local kind=$1 target=$2
  if [[ $kind == block ]]; then
    cb_block_hash "$target"
    return
  fi
  case $(cb_kind "$target") in
    absent) printf 'absent' ;;
    file) [[ $kind == file ]] || cb_die "object kind conflict at $target"; cb_sha256_file "$target" ;;
    tree) [[ $kind == tree ]] || cb_die "object kind conflict at $target"; cb_tree_hash "$target" ;;
    *) cb_die "unsafe object at managed target: $target" ;;
  esac
}

cb_fault_after_mutation() {
  local label=$1 requested=${CODEX_BASELINE_TEST_CRASH_AFTER:-}
  CB_MUTATION_COUNT=$((CB_MUTATION_COUNT + 1))
  if [[ ${CODEX_BASELINE_TESTING:-0} == 1 && $requested =~ ^[0-9]+$ && $CB_MUTATION_COUNT -eq $requested ]]; then
    cb_err "test fault injection after mutation $CB_MUTATION_COUNT ($label)"
    kill -KILL "$$"
  fi
}

cb_create_object() {
  local tx=$1 id=$2 kind=$3 target=$4 desired=$5 source_label=$6 root=$7 desired_present=${8:-1}
  local obj current_obj installed live existed previous_hash previous_kind
  obj="$(cb_tx_dir "$tx")/objects/$id"
  cb_safe_mkdir_path "$obj"
  cb_write_field "$obj/kind" "$kind"
  cb_write_field "$obj/target" "$target"
  cb_write_field "$obj/root" "$root"
  cb_write_field "$obj/desired_hash" "$desired"
  cb_write_field "$obj/desired_present" "$desired_present"
  cb_write_field "$obj/source" "$source_label"
  cb_write_field "$obj/status" planned
  live=$(cb_live_hash "$kind" "$target")
  previous_hash=$live
  previous_kind=$(cb_kind "$target")
  [[ $kind == block ]] && previous_kind=block
  existed=1
  [[ -e $target || -L $target ]] || existed=0
  if [[ $kind == block ]]; then
    if [[ $live == absent ]]; then
      cb_write_field "$obj/previous_managed_existed" 0
    else
      cb_write_field "$obj/previous_managed_existed" 1
    fi
    if [[ $existed == 1 ]]; then
      [[ -f $target && ! -L $target ]] || cb_die "guidance target is not a regular file: $target"
      cb_write_field "$obj/previous_file_hash" "$(cb_sha256_file "$target")"
    else
      cb_write_field "$obj/previous_file_hash" absent
    fi
  fi
  cb_write_field "$obj/previous_hash" "$previous_hash"
  cb_write_field "$obj/previous_kind" "$previous_kind"
  cb_write_field "$obj/previous_existed" "$existed"
  if current_obj=$(cb_find_current_object "$target"); then
    installed=$(cb_read_field "$current_obj/installed_hash")
    [[ $live == "$installed" ]] || cb_die "managed content drifted; refusing to overwrite: $target"
  elif [[ $kind == block ]]; then
    [[ $live == absent ]] || cb_die "unowned baseline marker exists: $target"
  elif [[ $live != absent ]]; then
    cb_die "unowned target exists: $target"
  fi
  if [[ $live == "$desired" ]]; then
    cb_write_field "$obj/change" 0
  else
    cb_write_field "$obj/change" 1
  fi
}

cb_select_agents_file() {
  local override="$CB_CODEX_HOME/AGENTS.override.md" normal="$CB_CODEX_HOME/AGENTS.md"
  if [[ -s $override && -s $normal ]]; then
    cb_die "both non-empty global AGENTS.override.md and AGENTS.md exist; choose the intended active file before install"
  fi
  if [[ -s $override ]]; then
    printf '%s' "$override"
  else
    printf '%s' "$normal"
  fi
}

cb_build_runtime() {
  local output=$1 source_root=$2
  mkdir -p -- "$output/scripts/lib"
  cp -- "$source_root/VERSION" "$output/VERSION"
  cp -a -- "$source_root/baseline" "$output/baseline"
  cp -p -- \
    "$source_root/scripts/codex-baseline.sh" "$source_root/scripts/codex-baseline.ps1" \
    "$source_root/scripts/onboard.sh" "$source_root/scripts/onboard.ps1" \
    "$source_root/scripts/benchmark.sh" "$source_root/scripts/benchmark.ps1" \
    "$output/scripts/"
  cp -p -- "$source_root/scripts/lib/common.sh" "$source_root/scripts/lib/evaluation.sh" "$output/scripts/lib/"
  if [[ -d $source_root/benchmarks ]]; then
    cp -a -- "$source_root/benchmarks" "$output/benchmarks"
  fi
}

cb_installed_tree_hash() {
  local source=$1 tmp digest
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/codex-baseline-hash.XXXXXX")
  mkdir -- "$tmp/tree"
  chmod --reference="$source" "$tmp/tree"
  cp -a -- "$source/." "$tmp/tree/"
  digest=$(cb_tree_hash "$tmp/tree")
  rm -rf -- "$tmp"
  printf '%s' "$digest"
}

cb_render_wrapper() {
  local output=$1
  cat >"$output" <<'EOF'
#!/bin/sh
set -eu
codex_home=${CODEX_HOME:-"${HOME:?HOME must be set}/.codex"}
exec "$codex_home/codex-baseline/runtime/scripts/codex-baseline.sh" "$@"
EOF
  chmod 0755 "$output"
}

cb_stage_source_object() {
  local obj=$1 source=$2 kind=$3 stage
  stage=$(cb_read_field "$obj/stage")
  case $kind in
    file) [[ -f $stage && ! -L $stage ]] || cb_die "unsafe reserved stage: $stage"; cp -p -- "$source" "$stage" ;;
    tree) [[ -d $stage && ! -L $stage ]] || cb_die "unsafe reserved stage: $stage"; chmod --reference="$source" "$stage"; cp -a -- "$source/." "$stage/" ;;
    *) cb_die "cannot stage source kind: $kind" ;;
  esac
}

cb_prepare_backup() {
  local obj=$1 kind target existed backup previous_file_hash
  kind=$(cb_read_field "$obj/kind")
  target=$(cb_read_field "$obj/target")
  existed=$(cb_read_field "$obj/previous_existed")
  backup="$obj/backup"
  [[ $existed == 1 ]] || return 0
  if [[ $kind == block ]]; then
    previous_file_hash=$(cb_read_field "$obj/previous_file_hash")
    [[ $(cb_sha256_file "$target") == "$previous_file_hash" ]] || cb_die "guidance file changed before backup: $target"
    cp -p -- "$target" "$obj/backup_file"
    [[ $(cb_sha256_file "$obj/backup_file") == "$previous_file_hash" ]] || cb_die "guidance backup verification failed: $target"
    if [[ $(cb_read_field "$obj/previous_managed_existed") == 1 ]]; then
      cb_extract_block "$target" "$backup" || cb_die "expected previous managed block in $target"
    else
      cb_write_field "$obj/backup_hash" absent
      return
    fi
  elif [[ $kind == file ]]; then
    cp -p -- "$target" "$backup"
  elif [[ $kind == tree ]]; then
    mkdir -- "$backup"
    chmod --reference="$target" "$backup"
    cp -a -- "$target/." "$backup/"
  fi
  cb_write_field "$obj/backup_hash" "$(cb_object_hash "$kind" "$backup")"
}

cb_prepare_object() {
  local obj=$1 source=$2 kind target root parent stage old desired_block desired_present stage_mode=${4:-managed}
  local tx id stage_template old_template
  kind=$(cb_read_field "$obj/kind")
  target=$(cb_read_field "$obj/target")
  root=$(cb_read_field "$obj/root")
  desired_present=$(cb_read_field "$obj/desired_present")
  parent=$(dirname -- "$target")
  id=$(basename -- "$obj")
  tx=$(basename -- "$(dirname -- "$(dirname -- "$obj")")")
  cb_safe_mkdir_parent "$target" "$root"
  stage_template="$parent/.codex-baseline-stage-$tx-$id.XXXXXX"
  old_template="$parent/.codex-baseline-old-$tx-$id.XXXXXX"
  if [[ $desired_present == 0 ]]; then
    stage="$parent/.codex-baseline-stage-$tx-$id.delete"
    [[ ! -e $stage && ! -L $stage ]] || cb_die "staging collision near $target"
  elif [[ $kind == tree ]]; then
    stage=$(mktemp -d "$stage_template")
  else
    stage=$(mktemp "$stage_template")
  fi
  old=$(mktemp "$old_template")
  rm -f -- "$old"
  [[ ! -e $old && ! -L $old ]] || cb_die "old-path reservation failed near $target"
  cb_write_field "$obj/stage" "$stage"
  cb_write_field "$obj/old" "$old"
  cb_prepare_backup "$obj"
  if [[ $desired_present == 0 ]]; then
    [[ $kind != block || $(cb_read_field "$obj/desired_hash") == absent ]] || cb_die "invalid block deletion plan: $target"
    cb_write_field "$obj/status" prepared
    return 0
  fi
  case $kind in
    block)
      if [[ $stage_mode == full-file ]]; then
        [[ -f $stage && ! -L $stage ]] || cb_die "unsafe reserved stage: $stage"
        cp -p -- "$source" "$stage"
      elif [[ $source == :remove-block ]]; then
        cb_remove_block "$target" "$stage"
      else
        desired_block=$source
        cb_replace_block "$target" "$desired_block" "$stage"
      fi
      [[ ! -f $target || -L $target ]] || chmod --reference="$target" "$stage"
      ;;
    file|tree) cb_stage_source_object "$obj" "$source" "$kind" ;;
    *) cb_die "unsupported prepare kind: $kind" ;;
  esac
  [[ $(cb_live_hash "$kind" "$stage") == "$(cb_read_field "$obj/desired_hash")" ]] || cb_die "staged hash mismatch for $target"
  if [[ $kind == block ]]; then cb_write_field "$obj/desired_file_hash" "$(cb_sha256_file "$stage")"; fi
  cb_write_field "$obj/status" prepared
}

cb_path_absent() {
  [[ ! -e $1 && ! -L $1 ]]
}

cb_path_matches_previous() {
  local obj=$1 path=$2 kind existed previous previous_file
  kind=$(cb_read_field "$obj/kind")
  existed=$(cb_read_field "$obj/previous_existed")
  if [[ $existed == 0 ]]; then cb_path_absent "$path"; return; fi
  if [[ $kind == block ]]; then
    [[ -f $path && ! -L $path ]] || return 1
    previous=$(cb_read_field "$obj/previous_hash")
    previous_file=$(cb_read_field "$obj/previous_file_hash")
    [[ $(cb_sha256_file "$path") == "$previous_file" && $(cb_block_hash "$path") == "$previous" ]]
  else
    [[ $(cb_live_hash "$kind" "$path") == "$(cb_read_field "$obj/previous_hash")" ]]
  fi
}

cb_path_matches_desired() {
  local obj=$1 path=$2 kind desired_present desired desired_file
  kind=$(cb_read_field "$obj/kind")
  desired_present=$(cb_read_field "$obj/desired_present")
  if [[ $desired_present == 0 ]]; then cb_path_absent "$path"; return; fi
  desired=$(cb_read_field "$obj/desired_hash")
  if [[ $kind == block ]]; then
    [[ -f $path && ! -L $path ]] || return 1
    desired_file=$(cb_read_field "$obj/desired_file_hash")
    [[ -n $desired_file && $(cb_sha256_file "$path") == "$desired_file" && $(cb_block_hash "$path") == "$desired" ]]
  else
    [[ $(cb_live_hash "$kind" "$path") == "$desired" ]]
  fi
}

cb_recovery_preflight_object() {
  local obj=$1 status target root old stage recovery_new existed target_state old_state recovery_state
  status=$(cb_read_field "$obj/status")
  target=$(cb_read_field "$obj/target")
  root=$(cb_read_field "$obj/root")
  existed=$(cb_read_field "$obj/previous_existed")
  case $status in
    planned|unchanged)
      return
      ;;
    rolled-back)
      if [[ -e $obj/stage || -L $obj/stage ]]; then
        stage=$(cb_read_field "$obj/stage")
        old=$(cb_read_field "$obj/old")
        recovery_new="$stage.recovery-new"
        if ! cb_path_absent "$stage" || ! cb_path_absent "$old" || ! cb_path_absent "$recovery_new"; then
          cb_die "rolled-back object retains transaction paths: $obj"
        fi
      fi
      return
      ;;
  esac
  stage=$(cb_read_field "$obj/stage")
  old=$(cb_read_field "$obj/old")
  recovery_new="$stage.recovery-new"
  cb_assert_target_under "$target" "$root"
  cb_assert_target_under "$stage" "$root"
  cb_assert_target_under "$old" "$root"
  cb_assert_target_under "$recovery_new" "$root"
  case $status in
    prepared|ready)
      cb_path_absent "$old" || cb_die "unexpected recovery preimage before commit: $old"
      cb_path_absent "$recovery_new" || cb_die "unexpected recovery scratch before commit: $recovery_new"
      cb_path_matches_previous "$obj" "$target" || cb_die "live preimage changed before recovery: $target"
      if [[ $(cb_read_field "$obj/desired_present") == 1 ]]; then
        cb_path_matches_desired "$obj" "$stage" || cb_die "staged desired object is corrupt: $stage"
      else
        cb_path_absent "$stage" || cb_die "deletion plan has unexpected stage: $stage"
      fi
      return
      ;;
    moving-old)
      cb_path_absent "$recovery_new" || cb_die "unexpected recovery scratch while moving old target: $target"
      if cb_path_absent "$old"; then
        cb_path_matches_previous "$obj" "$target" || cb_die "missing or corrupt live preimage: $target"
      else
        [[ $existed == 1 ]] || cb_die "unexpected old object for previously absent target: $target"
        cb_path_matches_previous "$obj" "$old" || cb_die "corrupt recovery preimage: $old"
        cb_path_absent "$target" || cb_die "ambiguous target while moving old object: $target"
      fi
      return
      ;;
  esac

  target_state=other
  if cb_path_absent "$target"; then target_state=absent
  elif cb_path_matches_desired "$obj" "$target"; then target_state=desired
  elif [[ $existed == 1 ]] && cb_path_matches_previous "$obj" "$target"; then target_state=previous
  fi
  old_state=other
  if cb_path_absent "$old"; then old_state=absent
  elif [[ $existed == 1 ]] && cb_path_matches_previous "$obj" "$old"; then old_state=previous
  fi
  recovery_state=other
  if cb_path_absent "$recovery_new"; then recovery_state=absent
  elif cb_path_matches_desired "$obj" "$recovery_new"; then recovery_state=desired
  fi
  [[ $old_state != other ]] || cb_die "corrupt recovery preimage: $old"
  [[ $target_state != other ]] || cb_die "unverifiable live object during recovery: $target"
  [[ $recovery_state != other ]] || cb_die "corrupt recovery scratch: $recovery_new"
  [[ $target_state != desired || $recovery_state == absent ]] || cb_die "duplicate desired state during recovery: $target"
  [[ $target_state != previous || $old_state == absent ]] || cb_die "duplicate preimage during recovery: $target"
  if [[ $existed == 1 ]]; then
    [[ $target_state == previous || $old_state == previous ]] || cb_die "recovery preimage is missing: $target"
  else
    [[ $old_state == absent && $target_state != previous ]] || cb_die "unexpected recovery preimage: $target"
  fi
}

cb_restore_object_now() {
  local obj=$1 status target root old stage existed recovery_new
  status=$(cb_read_field "$obj/status")
  target=$(cb_read_field "$obj/target")
  root=$(cb_read_field "$obj/root")
  old=$(cb_read_field "$obj/old")
  stage=$(cb_read_field "$obj/stage")
  existed=$(cb_read_field "$obj/previous_existed")
  case $status in
    planned|unchanged|rolled-back)
      cb_write_field "$obj/status" rolled-back
      return
      ;;
  esac
  recovery_new="$stage.recovery-new"
  case $status in
    moving-old)
      if ! cb_path_absent "$old"; then mv -T -- "$old" "$target"; fi
      ;;
    old-moved|new-moved|committed)
      if cb_path_matches_desired "$obj" "$target"; then
        cb_path_absent "$recovery_new" || cb_die "recovery scratch collision: $recovery_new"
        mv -T -- "$target" "$recovery_new"
      fi
      if [[ $existed == 1 ]] && ! cb_path_matches_previous "$obj" "$target"; then
        cb_path_absent "$target" || cb_die "target is not empty before preimage restore: $target"
        mv -T -- "$old" "$target"
      fi
      ;;
  esac
  cb_path_absent "$recovery_new" || cb_remove_internal "$recovery_new" "$root"
  cb_path_absent "$stage" || cb_remove_internal "$stage" "$root"
  cb_path_absent "$old" || cb_remove_internal "$old" "$root"
  cb_sync_parent "$target"
  cb_write_field "$obj/status" rolled-back
}

cb_recover_tx() {
  local tx=$1 dir obj prior_current
  cb_validate_tx "$tx"
  dir=$(cb_tx_dir "$tx")
  while IFS= read -r -d '' obj; do cb_recovery_preflight_object "$obj"; done \
    < <(find -P "$dir/objects" -mindepth 1 -maxdepth 1 -type d -print0 | LC_ALL=C sort -zr)
  cb_set_tx_state "$tx" recovering
  while IFS= read -r -d '' obj; do cb_restore_object_now "$obj"; done \
    < <(find -P "$dir/objects" -mindepth 1 -maxdepth 1 -type d -print0 | LC_ALL=C sort -zr)
  prior_current=$(cb_read_field "$dir/parent")
  if [[ -n $prior_current ]]; then
    cb_write_field "$CB_CURRENT" "$prior_current"
  else
    rm -f -- "$CB_CURRENT"
    cb_sync_parent "$CB_CURRENT"
  fi
  cb_set_tx_state "$tx" rolled-back
  rm -f -- "$CB_PENDING"
  cb_sync_parent "$CB_PENDING"
}

cb_recover_pending() {
  local pending
  pending=$(cb_read_tx_pointer "$CB_PENDING")
  [[ -n $pending ]] || return 0
  cb_err "recovering incomplete transaction $pending"
  cb_recover_tx "$pending"
}

cb_on_exit() {
  local code=$?
  trap - EXIT
  if [[ $code -ne 0 && -n $CB_ACTIVE_TX && -f $CB_PENDING ]]; then
    cb_err "operation failed; recovering transaction $CB_ACTIVE_TX"
    cb_recover_tx "$CB_ACTIVE_TX" || cb_err "automatic recovery failed; run doctor before another mutation"
  fi
  if [[ $code -ne 0 && -n ${CB_CONFIG_PENDING:-} && -f $CB_CONFIG_PENDING ]]; then
    cb_err 'operation failed; recovering config transaction'
    cb_config_recover_pending || cb_err 'automatic config recovery failed; run doctor before another mutation'
  fi
  if [[ $code -ne 0 && -n ${CB_COMPOSITE_PENDING:-} && -f $CB_COMPOSITE_PENDING ]]; then
    cb_err 'operation failed; reconciling composite core/config transaction'
    cb_composite_recover_pending || cb_err 'automatic composite recovery failed; run doctor before another mutation'
  fi
  cb_release_lock
  cb_cleanup_temps
  exit "$code"
}

cb_commit_object() {
  local obj=$1 kind target root stage old existed live desired desired_present tx previous_file desired_file
  kind=$(cb_read_field "$obj/kind")
  target=$(cb_read_field "$obj/target")
  root=$(cb_read_field "$obj/root")
  stage=$(cb_read_field "$obj/stage")
  old=$(cb_read_field "$obj/old")
  existed=$(cb_read_field "$obj/previous_existed")
  desired=$(cb_read_field "$obj/desired_hash")
  desired_present=$(cb_read_field "$obj/desired_present")
  tx=$(basename -- "$(dirname -- "$(dirname -- "$obj")")")
  cb_validate_object_contract "$tx" "$obj"
  cb_assert_target_under "$target" "$root"
  cb_path_absent "$old" || cb_die "old path appeared before commit: $old"
  if [[ $desired_present == 1 ]]; then
    cb_path_matches_desired "$obj" "$stage" || cb_die "stage changed before commit: $stage"
  else
    cb_path_absent "$stage" || cb_die "unexpected deletion stage before commit: $stage"
  fi
  if [[ ${CODEX_BASELINE_TESTING:-0} == 1 && ${CODEX_BASELINE_TEST_EDIT_AGENTS_BEFORE_COMMIT:-0} == 1 && $kind == block ]]; then
    printf '%s\n' 'concurrent-test-edit' >>"$target"
    unset CODEX_BASELINE_TEST_EDIT_AGENTS_BEFORE_COMMIT
  fi
  live=$(cb_live_hash "$kind" "$target")
  [[ $live == "$(cb_read_field "$obj/previous_hash")" ]] || cb_die "target changed during transaction: $target"
  if [[ $kind == block ]]; then
    previous_file=$(cb_read_field "$obj/previous_file_hash")
    [[ $existed == 0 && $previous_file == absent ]] || \
      [[ -f $target && ! -L $target && $(cb_sha256_file "$target") == "$previous_file" ]] || \
      cb_die "guidance file changed during transaction: $target"
  fi
  cb_write_field "$obj/status" moving-old
  if [[ $existed == 1 ]]; then
    cb_path_absent "$old" || cb_die "old path appeared during commit: $old"
    mv -T -- "$target" "$old"
    cb_sync_parent "$target"
    cb_fault_after_mutation "moved-old:$target"
  fi
  cb_write_field "$obj/status" old-moved
  if [[ $desired_present == 1 ]]; then
    cb_assert_target_under "$target" "$root"
    cb_path_absent "$target" || cb_die "target appeared before desired move: $target"
    cb_path_matches_desired "$obj" "$stage" || cb_die "stage changed before desired move: $stage"
    mv -T -- "$stage" "$target"
    cb_sync_file "$target"
    cb_sync_parent "$target"
    cb_fault_after_mutation "moved-new:$target"
  fi
  cb_write_field "$obj/status" new-moved
  [[ $(cb_live_hash "$kind" "$target") == "$desired" ]] || cb_die "committed hash mismatch: $target"
  if [[ $kind == block && $desired_present == 1 ]]; then
    desired_file=$(cb_read_field "$obj/desired_file_hash")
    [[ $(cb_sha256_file "$target") == "$desired_file" ]] || cb_die "committed guidance file hash mismatch: $target"
  fi
  cb_write_field "$obj/installed_hash" "$desired"
  if [[ $kind == block && -f $target && ! -L $target ]]; then
    cb_write_field "$obj/installed_file_hash" "$(cb_sha256_file "$target")"
  fi
  cb_write_field "$obj/status" committed
}

cb_cleanup_old_paths() {
  local dir=$1 obj old_path root
  for obj in "$dir"/objects/*; do
    [[ -d $obj && -f $obj/old ]] || continue
    old_path=$(cb_read_field "$obj/old")
    root=$(cb_read_field "$obj/root")
    [[ ! -e $old_path && ! -L $old_path ]] || cb_remove_internal "$old_path" "$root"
  done
}

cb_begin_operation() {
  if [[ $CB_DRY_RUN -eq 1 ]]; then
    [[ ! -f $CB_PENDING ]] || cb_die 'an incomplete transaction requires recovery before dry-run'
    [[ ! -f $CB_CONFIG_PENDING ]] || cb_die 'an incomplete config transaction requires recovery before dry-run'
    [[ ! -f $CB_COMPOSITE_PENDING ]] || cb_die 'an incomplete composite transaction requires recovery before dry-run'
    CB_DRY_TX_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/codex-baseline-dry.XXXXXX")
    cb_register_temp "$CB_DRY_TX_ROOT"
    CB_TX_ROOT="$CB_DRY_TX_ROOT/state"
    cb_safe_mkdir_path "$CB_TX_ROOT/transactions"
  else
    cb_init_mutation_roots
    cb_acquire_lock
    cb_recover_pending
    cb_config_recover_pending
    cb_composite_recover_pending
    if [[ -n $(cb_current_tx) ]]; then cb_validate_tx "$(cb_current_tx)" committed "$CB_STATE_ROOT"; fi
  fi
}

cb_global_guidance_source() {
  local root=$1 status source
  status=$(sed -n 's/^  "status": "\([A-Za-z0-9.]*\)"$/\1/p' "$root/baseline/release-status.json")
  if [[ $status == stable ]]; then
    source="$root/baseline/global/AGENTS.stable.block.md"
  elif [[ $status =~ ^rc\.[1-9][0-9]*$ ]]; then
    source="$root/baseline/global/AGENTS.block.md"
  else
    cb_die 'release status is missing or unsupported while selecting global guidance'
  fi
  [[ -f $source && ! -L $source ]] || cb_die 'release-specific global guidance is missing or unsafe'
  printf '%s' "$source"
}

cb_install_like() {
  local operation=$1 source_root=${2:-$CB_SOURCE_ROOT} acquisition=${3:-local-checkout}
  local version payload_hash manifest_hash verified_root guidance_source tx dir agents_file block_tmp runtime_tmp wrapper_tmp obj changed=0 current current_version pause_attempt fresh_install=0
  version=$(cb_verify_source_manifest "$source_root")
  payload_hash=$(sed -n 's/^  "payload_hash": "\([0-9a-f]\{64\}\)",$/\1/p' "$source_root/baseline/manifest.json")
  manifest_hash=$(cb_sha256_file "$source_root/baseline/manifest.json")
  cb_print_source_provenance "$source_root" "$payload_hash" "$acquisition"
  if [[ $CB_DRY_RUN -eq 0 && $CB_ACKNOWLEDGE_UNVERIFIED_SOURCE -ne 1 ]]; then
    cb_die 'unsigned local source requires --acknowledge-unverified-source before mutation'
  fi
  CB_VERSION=$version
  cb_freeze_verified_source "$source_root" "$manifest_hash" "$payload_hash"
  verified_root=$CB_VERIFIED_SOURCE_ROOT
  guidance_source=$(cb_global_guidance_source "$verified_root")
  cb_init_paths
  if [[ $operation == install && $CB_DRY_RUN -eq 0 && ! -e $CB_CURRENT && ! -L $CB_CURRENT && \
        ! -e $CB_PENDING && ! -L $CB_PENDING && ! -e $CB_CONFIG_PENDING && ! -L $CB_CONFIG_PENDING && \
        ! -e $CB_COMPOSITE_PENDING && ! -L $CB_COMPOSITE_PENDING ]]; then
    cb_config_auto_install_cap '' preflight
  fi
  if [[ $acquisition == unsigned-github-release && ${CODEX_BASELINE_TESTING:-0} == 1 && \
        -n ${CODEX_BASELINE_TEST_UPDATE_PAUSE_BEFORE_LOCK:-} ]]; then
    [[ -d $CODEX_BASELINE_TEST_UPDATE_PAUSE_BEFORE_LOCK && ! -L $CODEX_BASELINE_TEST_UPDATE_PAUSE_BEFORE_LOCK ]] || cb_die 'update pause fixture directory is unsafe'
    printf 'ready\n' >"$CODEX_BASELINE_TEST_UPDATE_PAUSE_BEFORE_LOCK/ready"
    for (( pause_attempt=0; pause_attempt < 600; pause_attempt++ )); do
      [[ ! -f $CODEX_BASELINE_TEST_UPDATE_PAUSE_BEFORE_LOCK/continue ]] || break
      sleep 0.05
    done
    [[ -f $CODEX_BASELINE_TEST_UPDATE_PAUSE_BEFORE_LOCK/continue ]] || cb_die 'timed out waiting for concurrent update fixture'
  fi
  cb_begin_operation
  current=$(cb_current_tx)
  [[ -n $current ]] || fresh_install=1
  if [[ $acquisition == unsigned-github-release && $CB_DRY_RUN -eq 0 ]]; then
    current=$(cb_current_tx)
    if [[ -n $current ]]; then
      current_version=$(cb_read_field "$(cb_tx_dir "$current")/version")
      [[ $(cb_semver_compare "$version" "$current_version") -ge 0 ]] || cb_die "remote update would downgrade installed $current_version to $version"
    fi
  fi
  # Repeat the complete, non-mutating config preflight while holding the
  # Baseline lock. The earlier check guarantees predictable failures leave no
  # managed state; this check closes the interval in which config.toml could
  # have changed before any core transaction is created.
  if [[ $operation == install && $fresh_install -eq 1 && $CB_DRY_RUN -eq 0 ]]; then
    cb_config_auto_install_cap '' preflight
  fi
  cb_new_tx "$operation"
  tx=$CB_NEW_TX
  dir=$(cb_tx_dir "$tx")
  agents_file=$(cb_select_agents_file)
  block_tmp=$(mktemp "${TMPDIR:-/tmp}/codex-baseline-rendered.XXXXXX")
  runtime_tmp=$(mktemp -d "${TMPDIR:-/tmp}/codex-baseline-runtime.XXXXXX")
  wrapper_tmp=$(mktemp "${TMPDIR:-/tmp}/codex-baseline-wrapper.XXXXXX")
  cb_register_temp "$block_tmp"
  cb_register_temp "$runtime_tmp"
  cb_register_temp "$wrapper_tmp"
  cb_render_managed_block "$guidance_source" "$version" "$block_tmp"
  cb_build_runtime "$runtime_tmp" "$verified_root"
  cb_render_wrapper "$wrapper_tmp"

  cb_create_object "$tx" 00 block "$agents_file" "$(cb_sha256_file "$block_tmp")" 'baseline/global/AGENTS.block.md' "$CB_CODEX_HOME"
  cb_create_object "$tx" 10 tree "$CB_AGENTS_HOME/skills/codex-baseline-repo-onboarding" "$(cb_installed_tree_hash "$verified_root/baseline/skills/codex-baseline-repo-onboarding")" 'baseline/skills/codex-baseline-repo-onboarding' "$CB_AGENTS_HOME"
  cb_create_object "$tx" 11 tree "$CB_AGENTS_HOME/skills/codex-baseline-deep-work" "$(cb_installed_tree_hash "$verified_root/baseline/skills/codex-baseline-deep-work")" 'baseline/skills/codex-baseline-deep-work' "$CB_AGENTS_HOME"
  cb_create_object "$tx" 12 tree "$CB_AGENTS_HOME/skills/codex-baseline-conformance-review" "$(cb_installed_tree_hash "$verified_root/baseline/skills/codex-baseline-conformance-review")" 'baseline/skills/codex-baseline-conformance-review' "$CB_AGENTS_HOME"
  cb_create_object "$tx" 13 tree "$CB_AGENTS_HOME/skills/codex-baseline-retrospective" "$(cb_installed_tree_hash "$verified_root/baseline/skills/codex-baseline-retrospective")" 'baseline/skills/codex-baseline-retrospective' "$CB_AGENTS_HOME"
  cb_create_object "$tx" 20 file "$CB_CODEX_HOME/agents/codex-baseline-reviewer.toml" "$(cb_sha256_file "$verified_root/baseline/agents/codex-baseline-reviewer.toml")" 'baseline/agents/codex-baseline-reviewer.toml' "$CB_CODEX_HOME"
  cb_create_object "$tx" 30 tree "$CB_RUNTIME" "$(cb_tree_hash "$runtime_tmp")" runtime "$CB_CODEX_HOME"
  cb_create_object "$tx" 31 file "$CB_HOME/.local/bin/codex-baseline" "$(cb_sha256_file "$wrapper_tmp")" generated-wrapper "$CB_HOME"

  for obj in "$dir"/objects/*; do
    if [[ $(cb_read_field "$obj/change") == 1 ]]; then
      changed=1
      printf '%s: %s\n' "$operation" "$(cb_read_field "$obj/target")"
    fi
  done
  if [[ $changed -eq 0 ]]; then
    printf 'codex-baseline %s is already installed; no changes\n' "$version"
    cb_set_tx_state "$tx" no-op
    cb_discard_tx "$tx"
    cb_cleanup_temps
    CB_ACTIVE_TX=''
    return
  fi
  if [[ $operation == install && $fresh_install -eq 1 ]]; then
    if [[ $CB_DRY_RUN -eq 1 ]]; then
      cb_config_auto_install_cap "$tx" preview
      [[ $CB_CONFIG_PLAN_CHANGE -eq 0 ]] || printf '%s\n' "install: $CB_CONFIG_FILE (absent agent cap -> 6)"
    else
      cb_composite_begin install '' "$tx"
    fi
  fi
  if [[ $CB_DRY_RUN -eq 1 ]]; then
    printf 'dry-run: no files changed\n'
    cb_set_tx_state "$tx" dry-run
    cb_cleanup_temps
    CB_ACTIVE_TX=''
    return
  fi

  [[ -f $CB_PENDING ]] || cb_write_field "$CB_PENDING" "$tx"
  for obj in "$dir"/objects/*; do
    [[ $(cb_read_field "$obj/change") == 1 ]] || {
      cb_write_field "$obj/installed_hash" "$(cb_read_field "$obj/desired_hash")"
      cb_write_field "$obj/status" unchanged
      continue
    }
    case $(basename "$obj") in
      00) cb_prepare_object "$obj" "$block_tmp" block ;;
      10) cb_prepare_object "$obj" "$verified_root/baseline/skills/codex-baseline-repo-onboarding" tree ;;
      11) cb_prepare_object "$obj" "$verified_root/baseline/skills/codex-baseline-deep-work" tree ;;
      12) cb_prepare_object "$obj" "$verified_root/baseline/skills/codex-baseline-conformance-review" tree ;;
      13) cb_prepare_object "$obj" "$verified_root/baseline/skills/codex-baseline-retrospective" tree ;;
      20) cb_prepare_object "$obj" "$verified_root/baseline/agents/codex-baseline-reviewer.toml" file ;;
      30) cb_prepare_object "$obj" "$runtime_tmp" tree ;;
      31) cb_prepare_object "$obj" "$wrapper_tmp" file ;;
    esac
  done
  cb_set_tx_state "$tx" prepared
  cb_set_tx_state "$tx" committing
  for obj in "$dir"/objects/*; do
    [[ $(cb_read_field "$obj/change") == 1 ]] || continue
    cb_commit_object "$obj"
  done
  cb_write_field "$CB_CURRENT" "$tx"
  cb_set_tx_state "$tx" committed
  rm -f -- "$CB_PENDING"
  cb_sync_parent "$CB_PENDING"
  cb_cleanup_old_paths "$dir"
  cb_composite_recover_pending
  cb_cleanup_temps
  CB_ACTIVE_TX=''
  printf 'installed codex-baseline %s (transaction %s)\n' "$version" "$tx"
}

cb_plan_rollback_object() {
  local tx=$1 current_obj=$2 id kind target root desired previous_existed previous_managed
  local desired_present=1 source mode installed_file_hash live_file_hash exact_file=0
  id=$(basename -- "$current_obj")
  kind=$(cb_read_field "$current_obj/kind")
  target=$(cb_read_field "$current_obj/target")
  root=$(cb_read_field "$current_obj/root")
  desired=$(cb_read_field "$current_obj/previous_hash")
  previous_existed=$(cb_read_field "$current_obj/previous_existed")
  source="$current_obj/backup"
  mode=restore
  if [[ $kind == block && -f $target && ! -L $target ]]; then
    installed_file_hash=$(cb_read_field "$current_obj/installed_file_hash")
    live_file_hash=$(cb_sha256_file "$target")
    [[ -n $installed_file_hash && $live_file_hash == "$installed_file_hash" ]] && exact_file=1
  fi
  if [[ $previous_existed == 0 && ( $kind != block || $exact_file -eq 1 ) ]]; then
    desired_present=0
    desired=absent
    source=:delete
    mode=delete
  elif [[ $kind == block ]]; then
    if [[ $exact_file -eq 1 && -f $current_obj/backup_file && ! -L $current_obj/backup_file ]]; then
      [[ $(cb_sha256_file "$current_obj/backup_file") == "$(cb_read_field "$current_obj/previous_file_hash")" ]] || \
        cb_die "rollback whole-file backup is corrupt: $current_obj/backup_file"
      source="$current_obj/backup_file"
      mode=full-file
    else
      previous_managed=$(cb_read_field "$current_obj/previous_managed_existed")
    fi
    if [[ ${previous_managed:-1} == 0 ]]; then
      desired=absent
      source=:remove-block
      mode=remove-block
    elif [[ $exact_file -eq 0 ]]; then
      [[ -f $source && ! -L $source && $(cb_block_hash "$source") == "$(cb_read_field "$current_obj/backup_hash")" ]] || \
        cb_die "rollback block backup is corrupt: $source"
    fi
  fi
  if [[ $desired_present == 1 && $source != :remove-block ]]; then
    case $kind in
      file) [[ -f $source && ! -L $source ]] || cb_die "rollback backup is missing: $source" ;;
      tree) [[ -d $source && ! -L $source ]] || cb_die "rollback backup is missing: $source" ;;
      block) [[ -f $source && ! -L $source ]] || cb_die "rollback block backup is missing: $source" ;;
    esac
    if [[ $kind == file || $kind == tree ]]; then
      [[ $(cb_object_hash "$kind" "$source") == "$(cb_read_field "$current_obj/backup_hash")" && \
         $(cb_read_field "$current_obj/backup_hash") == "$(cb_read_field "$current_obj/previous_hash")" ]] || \
        cb_die "rollback backup is corrupt: $source"
    fi
  fi
  cb_create_object "$tx" "$id" "$kind" "$target" "$desired" "rollback:$(basename "$(dirname "$(dirname "$current_obj")")")/$id" "$root" "$desired_present"
  cb_write_field "$(cb_tx_dir "$tx")/objects/$id/restore_source" "$source"
  cb_write_field "$(cb_tx_dir "$tx")/objects/$id/restore_mode" "$mode"
}

cb_rollback_once() {
  local operation=$1 current current_dir parent tx dir current_obj obj changed=0 source kind
  current=$(cb_current_tx)
  if [[ -z $current ]]; then
    printf 'codex-baseline is not installed; no changes\n'
    return 2
  fi
  current_dir=$(cb_live_tx_dir "$current")
  cb_validate_tx "$current" committed "$CB_STATE_ROOT"
  parent=$(cb_read_field "$current_dir/parent")
  cb_new_tx "$operation"
  tx=$CB_NEW_TX
  dir=$(cb_tx_dir "$tx")
  cb_write_field "$dir/rollback_target" "$current"
  cb_write_field "$dir/result_current" "$parent"
  for current_obj in "$current_dir"/objects/*; do
    [[ -d $current_obj && $(cb_read_field "$current_obj/status") == committed ]] || continue
    cb_plan_rollback_object "$tx" "$current_obj"
  done
  for obj in "$dir"/objects/*; do
    [[ -d $obj ]] || continue
    if [[ $(cb_read_field "$obj/change") == 1 ]]; then
      changed=1
      printf '%s: %s\n' "$operation" "$(cb_read_field "$obj/target")"
    fi
  done
  [[ $changed -eq 1 ]] || cb_die "transaction $current has no reversible changes"
  if [[ $CB_DRY_RUN -eq 1 ]]; then
    printf 'dry-run: would restore transaction %s; no files changed\n' "$current"
    cb_cleanup_temps
    CB_ACTIVE_TX=''
    return 0
  fi
  cb_write_field "$CB_PENDING" "$tx"
  for obj in "$dir"/objects/*; do
    [[ -d $obj && $(cb_read_field "$obj/change") == 1 ]] || continue
    source=$(cb_read_field "$obj/restore_source")
    kind=$(cb_read_field "$obj/kind")
    if [[ $(cb_read_field "$obj/restore_mode") == full-file ]]; then
      cb_prepare_object "$obj" "$source" "$kind" full-file
    else
      cb_prepare_object "$obj" "$source" "$kind"
    fi
  done
  cb_set_tx_state "$tx" prepared
  cb_set_tx_state "$tx" committing
  for obj in "$dir"/objects/*; do
    [[ -d $obj && $(cb_read_field "$obj/change") == 1 ]] || continue
    cb_commit_object "$obj"
  done
  if [[ -n $parent ]]; then
    cb_write_field "$CB_CURRENT" "$parent"
  else
    rm -f -- "$CB_CURRENT"
    cb_sync_parent "$CB_CURRENT"
  fi
  cb_set_tx_state "$tx" committed
  rm -f -- "$CB_PENDING"
  cb_sync_parent "$CB_PENDING"
  cb_cleanup_old_paths "$dir"
  CB_ACTIVE_TX=''
  printf 'restored state before transaction %s (recovery transaction %s)\n' "$current" "$tx"
  return 0
}

cb_rollback() {
  local core parent config_dir config_core
  CB_VERSION=$(<"$CB_SOURCE_ROOT/VERSION")
  cb_init_paths
  cb_begin_operation
  core=$(cb_current_tx)
  if [[ -z $core ]]; then
    printf 'codex-baseline is not installed; no changes\n'
    return 0
  fi
  parent=$(cb_read_field "$(cb_tx_dir "$core")/parent")
  if [[ $CB_DRY_RUN -eq 1 ]]; then
    config_dir=$(cb_config_current_dir_or_empty)
    if [[ -n $config_dir ]]; then
      config_core=$(cb_read_field "$config_dir/core_tx")
      if [[ $config_core == "$core" ]]; then cb_config_restore rollback "$core" || true; fi
    fi
  else
    cb_composite_begin rollback "$core" "$parent"
  fi
  cb_rollback_once rollback || {
    local code=$?
    [[ $code -eq 2 ]] && return 0
    return "$code"
  }
  [[ $CB_DRY_RUN -eq 1 ]] || cb_composite_recover_pending
}

cb_config_key_path() {
  case $1 in
    agents_enabled) printf 'agents.enabled' ;;
    agents_max) printf 'agents.max_concurrent_threads_per_session' ;;
    service_tier) printf 'service_tier' ;;
    features_fast_mode) printf 'features.fast_mode' ;;
    *) cb_die "unknown managed config key: $1" ;;
  esac
}

cb_config_key_type() {
  case $1 in
    agents_enabled|features_fast_mode) printf 'boolean' ;;
    agents_max) printf 'integer' ;;
    service_tier) printf 'enum' ;;
    *) cb_die "unknown managed config key: $1" ;;
  esac
}

cb_config_assert_path() {
  local target=$CB_CONFIG_FILE links owner size
  cb_assert_target_under "$target" "$CB_CODEX_HOME"
  [[ ! -L $target ]] || cb_die "config.toml is a symbolic link: $target"
  if [[ -e $target ]]; then
    [[ -f $target ]] || cb_die "config.toml is not a regular file: $target"
    links=$(stat -Lc '%h' -- "$target")
    owner=$(stat -Lc '%u' -- "$target")
    size=$(stat -Lc '%s' -- "$target")
    [[ $links == 1 ]] || cb_die 'config.toml hard links are not supported'
    [[ $owner == "$EUID" ]] || cb_die 'config.toml must be owned by the current user'
    [[ $size -le 1048576 ]] || cb_die 'config.toml exceeds the 1 MiB optimizer limit'
  fi
}

cb_config_capture_metadata() {
  local path=$1 label=$2 acl xattrs
  cb_require_command getfacl
  cb_require_command getfattr
  [[ -f $path && ! -L $path ]] || cb_die "$label is not an ordinary config artifact: $path"
  CB_CONFIG_META_UID=$(stat -Lc '%u' -- "$path")
  CB_CONFIG_META_GID=$(stat -Lc '%g' -- "$path")
  CB_CONFIG_META_MODE=$(stat -Lc '%a' -- "$path")
  acl=$(getfacl -cp -- "$path" 2>/dev/null || cb_die "cannot inspect $label ACL")
  if grep -Eq '^(default:|user:[^:]|group:[^:]|mask:)' <<<"$acl"; then
    cb_die "$label has an extended ACL that cannot be preserved safely"
  fi
  xattrs=$(getfattr --absolute-names -m - -d --encoding=hex -- "$path" 2>/dev/null | sed '/^#/d;/^[[:space:]]*$/d') || cb_die "cannot inspect $label extended attributes"
  [[ -z $xattrs ]] || cb_die "$label has extended attributes that cannot be preserved safely"
  CB_CONFIG_META_ACL_STATE='base-only'
  CB_CONFIG_META_XATTR_STATE='none'
}

cb_config_assert_mutation_metadata() {
  local parent_acl
  cb_require_command getfacl
  cb_require_command getfattr
  if [[ -d $CB_CODEX_HOME ]]; then
    parent_acl=$(getfacl -cp -- "$CB_CODEX_HOME" 2>/dev/null || cb_die 'cannot inspect CODEX_HOME default ACL')
    if grep -Eq '^default:' <<<"$parent_acl"; then
      cb_die 'CODEX_HOME has a default ACL that cannot be preserved safely for config.toml'
    fi
  fi
  if [[ -e $CB_CONFIG_FILE ]]; then
    cb_config_capture_metadata "$CB_CONFIG_FILE" 'config.toml'
    [[ $CB_CONFIG_META_UID == "$EUID" ]] || cb_die 'config.toml must be owned by the current user'
  fi
}

cb_config_assert_metadata_matches() {
  local path=$1 expected_uid=$2 expected_gid=$3 expected_mode=$4 expected_acl=$5 expected_xattrs=$6 label=$7
  cb_config_validate_artifact "$path" "$label"
  cb_config_capture_metadata "$path" "$label"
  [[ $CB_CONFIG_META_UID == "$expected_uid" && $CB_CONFIG_META_GID == "$expected_gid" && \
     $CB_CONFIG_META_MODE == "$expected_mode" && $CB_CONFIG_META_ACL_STATE == "$expected_acl" && \
     $CB_CONFIG_META_XATTR_STATE == "$expected_xattrs" ]] || cb_die "$label metadata does not match the recovery journal"
}

cb_config_test_edit_before_rename() {
  [[ ${CODEX_BASELINE_TESTING:-0} == 1 && ${CODEX_BASELINE_TEST_EDIT_CONFIG_BEFORE_RENAME:-0} == 1 ]] || return 0
  if [[ -e $CB_CONFIG_FILE ]]; then
    printf '\n%s\n' 'concurrent-config-test-edit = true' >>"$CB_CONFIG_FILE"
  else
    printf '%s\n' 'concurrent-config-test-edit = true' >"$CB_CONFIG_FILE"
  fi
  unset CODEX_BASELINE_TEST_EDIT_CONFIG_BEFORE_RENAME
}

cb_config_reject_quoted_definition() {
  local content=$1 key=$2 kind=$3 rest=''
  if [[ $content == "\"$key\""* ]]; then
    rest=${content#"\"$key\""}
  elif [[ $content == "'$key'"* ]]; then
    rest=${content#"'$key'"}
  else
    return 0
  fi
  case $kind in
    root)
      [[ ! $rest =~ ^[[:space:]]*(\.|=) ]] || cb_die 'dotted, quoted, or inline definitions of managed TOML paths are unsupported'
      ;;
    key)
      [[ ! $rest =~ ^[[:space:]]*= ]] || cb_die 'quoted managed or activation keys are unsupported for safe config decisions'
      ;;
    *) cb_die 'internal quoted config-definition classifier error' ;;
  esac
}

cb_config_scan() {
  local input=$1 index line content trimmed table='' key token id bom='' cr='' has_line_ending=0
  declare -gA CB_CFG_INDEX=() CB_CFG_TOKEN=() CB_CFG_TABLE_HEADER=() CB_CFG_LINE_TABLE=()
  declare -ga CB_CFG_LINES=()
  CB_CFG_FINAL_NEWLINE=0
  CB_CFG_DEFAULT_CR=''
  CB_CFG_EOL_SET=0
  if [[ -e $input ]]; then
    [[ -f $input && ! -L $input ]] || cb_die "unsafe config candidate: $input"
    cb_require_command iconv
    cb_require_command od
    iconv -f UTF-8 -t UTF-8 "$input" >/dev/null 2>&1 || cb_die 'config.toml is not valid UTF-8'
    od -An -v -tu1 -- "$input" | awk '
      { for (i = 1; i <= NF; i++) { byte = $i + 0; if (byte == 0 || (previous == 13 && byte != 10)) exit 1; previous = byte } }
      END { if (previous == 13) exit 1 }
    ' || cb_die 'config.toml contains NUL or an unsupported lone-CR line ending'
    if [[ -s $input && $(od -An -tuC -j $(( $(stat -c '%s' -- "$input") - 1 )) -N 1 "$input" | tr -d ' ') == 10 ]]; then
      CB_CFG_FINAL_NEWLINE=1
    fi
    mapfile -t CB_CFG_LINES <"$input"
  fi
  for ((index=0; index<${#CB_CFG_LINES[@]}; index++)); do
    line=${CB_CFG_LINES[$index]}
    content=$line; bom=''; cr=''
    if [[ $index -eq 0 && $content == $'\xEF\xBB\xBF'* ]]; then bom=$'\xEF\xBB\xBF'; content=${content#$'\xEF\xBB\xBF'}; fi
    if [[ $content == *$'\r' ]]; then cr=$'\r'; content=${content%$'\r'}; fi
    has_line_ending=0
    if (( index + 1 < ${#CB_CFG_LINES[@]} || CB_CFG_FINAL_NEWLINE == 1 )); then has_line_ending=1; fi
    if [[ $CB_CFG_EOL_SET -eq 0 && $has_line_ending -eq 1 ]]; then CB_CFG_DEFAULT_CR=$cr; CB_CFG_EOL_SET=1; fi
    [[ $content != *"'''"* && $content != *'"""'* ]] || cb_die 'multiline TOML strings are unsupported for safe key patching'
    trimmed=${content#"${content%%[!$' \t']*}"}
    CB_CFG_LINE_TABLE[$index]=$table
    if [[ -z $trimmed || $trimmed == \#* ]]; then continue; fi
    if [[ $trimmed =~ ^\[([A-Za-z0-9_-]+)\][[:space:]]*(#.*)?$ ]]; then
      table=${BASH_REMATCH[1]}
      CB_CFG_LINE_TABLE[$index]=$table
      if [[ $table == agents || $table == features ]]; then
        [[ -z ${CB_CFG_TABLE_HEADER[$table]+x} ]] || cb_die "duplicate [$table] table in config.toml"
        CB_CFG_TABLE_HEADER[$table]=$index
      fi
      continue
    fi
    if [[ $trimmed == \[* ]]; then
      if [[ $trimmed == *agents* || $trimmed == *features* ]]; then cb_die 'ambiguous quoted, dotted, array, or malformed managed TOML table'; fi
      table=other
      CB_CFG_LINE_TABLE[$index]=$table
      continue
    fi
    cb_config_reject_quoted_definition "$trimmed" agents root
    cb_config_reject_quoted_definition "$trimmed" features root
    if [[ $trimmed =~ ^(agents|features)[[:space:]]*(\.|=) ]]; then
      cb_die 'dotted, quoted, or inline definitions of managed TOML paths are unsupported'
    fi
    if [[ $table == '' ]]; then
      cb_config_reject_quoted_definition "$trimmed" service_tier key
    elif [[ $table == agents ]]; then
      cb_config_reject_quoted_definition "$trimmed" enabled key
      cb_config_reject_quoted_definition "$trimmed" max_concurrent_threads_per_session key
      cb_config_reject_quoted_definition "$trimmed" max_threads key
    elif [[ $table == features ]]; then
      cb_config_reject_quoted_definition "$trimmed" fast_mode key
      cb_config_reject_quoted_definition "$trimmed" multi_agent key
    fi
    key=''; id=''
    if [[ $table == '' && $trimmed =~ ^service_tier[[:space:]]*= ]]; then key=service_tier; id=service_tier
    elif [[ $table == agents && $trimmed =~ ^enabled[[:space:]]*= ]]; then key=enabled; id=agents_enabled
    elif [[ $table == agents && $trimmed =~ ^max_concurrent_threads_per_session[[:space:]]*= ]]; then key=max_concurrent_threads_per_session; id=agents_max
    elif [[ $table == agents && $trimmed =~ ^max_threads[[:space:]]*= ]]; then key=max_threads; id=agents_legacy_max
    elif [[ $table == features && $trimmed =~ ^fast_mode[[:space:]]*= ]]; then key=fast_mode; id=features_fast_mode
    elif [[ $table == features && $trimmed =~ ^multi_agent[[:space:]]*= ]]; then key=multi_agent; id=features_multi_agent
    fi
    [[ -n $id ]] || continue
    if [[ $content =~ ^([[:space:]]*)$key([[:space:]]*=[[:space:]]*)(true|false|[0-9]+|\"[A-Za-z0-9_-]+\")([[:space:]]*(#.*)?)$ ]]; then
      token=${BASH_REMATCH[3]}
      [[ -z ${CB_CFG_INDEX[$id]+x} ]] || cb_die "duplicate managed key: $id"
      case $id:$token in
        agents_enabled:true|agents_enabled:false|features_fast_mode:true|features_fast_mode:false|features_multi_agent:true|features_multi_agent:false|agents_max:[0-9]*|agents_legacy_max:[0-9]*|service_tier:\"[A-Za-z0-9_-]*\") ;;
        *) cb_die "managed key has an unsupported scalar type: $id" ;;
      esac
      if [[ $id == agents_max || $id == agents_legacy_max ]] && [[ ! $token =~ ^(0|[1-9][0-9]{0,5})$ ]]; then
        cb_die "managed key has an unsupported integer token: $id"
      fi
      CB_CFG_INDEX[$id]=$index
      CB_CFG_TOKEN[$id]=$token
    else
      cb_die "managed key uses ambiguous or unsupported TOML syntax: $id"
    fi
  done
}

cb_config_write_lines() {
  local output=$1 final=$2 array_name=$3 index count value newline
  declare -n lines_ref=$array_name
  : >"$output"
  count=${#lines_ref[@]}
  for ((index=0; index<count; index++)); do
    value=${lines_ref[$index]}; newline=0
    if (( index + 1 < count || final == 1 )); then newline=1; fi
    if [[ $newline -eq 0 && $value == *$'\r' ]]; then value=${value%$'\r'}; fi
    printf '%s' "$value" >>"$output"
    if [[ $newline -eq 1 ]]; then printf '\n' >>"$output"; fi
  done
}

cb_config_patch_one() {
  local input=$1 output=$2 id=$3 desired=$4 index found='' content bom='' cr='' key scope insert_at=-1 table_header=-1 line
  local -a result=()
  cb_config_scan "$input"
  found=${CB_CFG_INDEX[$id]-}
  case $id in
    agents_enabled) scope=agents; key=enabled ;;
    agents_max) scope=agents; key=max_concurrent_threads_per_session ;;
    service_tier) scope=''; key=service_tier ;;
    features_fast_mode) scope=features; key=fast_mode ;;
    *) cb_die "unknown patch key: $id" ;;
  esac
  if [[ -n $found ]]; then
    for ((index=0; index<${#CB_CFG_LINES[@]}; index++)); do
      line=${CB_CFG_LINES[$index]}
      if [[ $index -ne $found ]]; then result+=("$line"); continue; fi
      [[ $desired != __ABSENT__ ]] || continue
      content=$line; bom=''; cr=''
      if [[ $index -eq 0 && $content == $'\xEF\xBB\xBF'* ]]; then bom=$'\xEF\xBB\xBF'; content=${content#$'\xEF\xBB\xBF'}; fi
      if [[ $content == *$'\r' ]]; then cr=$'\r'; content=${content%$'\r'}; fi
      [[ $content =~ ^([[:space:]]*)$key([[:space:]]*=[[:space:]]*)(true|false|[0-9]+|\"[A-Za-z0-9_-]+\")([[:space:]]*(#.*)?)$ ]] || cb_die "cannot safely rewrite managed key: $id"
      result+=("$bom${BASH_REMATCH[1]}$key${BASH_REMATCH[2]}$desired${BASH_REMATCH[4]}$cr")
    done
    cb_config_write_lines "$output" "$CB_CFG_FINAL_NEWLINE" result
    return
  fi
  if [[ $desired == __ABSENT__ ]]; then cp -- "$input" "$output"; return; fi
  line="$key = $desired"
  if [[ -z $scope ]]; then
    insert_at=${#CB_CFG_LINES[@]}
    for ((index=0; index<${#CB_CFG_LINES[@]}; index++)); do
      content=${CB_CFG_LINES[$index]#$'\xEF\xBB\xBF'}
      content=${content%$'\r'}; content=${content#"${content%%[!$' \t']*}"}
      if [[ $content == \[* ]]; then insert_at=$index; break; fi
    done
  elif [[ -n ${CB_CFG_TABLE_HEADER[$scope]+x} ]]; then
    table_header=${CB_CFG_TABLE_HEADER[$scope]}; insert_at=${#CB_CFG_LINES[@]}
    for ((index=table_header+1; index<${#CB_CFG_LINES[@]}; index++)); do
      if [[ ${CB_CFG_LINE_TABLE[$index]-} != "$scope" ]]; then insert_at=$index; break; fi
    done
  else
    result=("${CB_CFG_LINES[@]}")
    if [[ ${#result[@]} -gt 0 && ${result[-1]} != *$'\r' && -n $CB_CFG_DEFAULT_CR ]]; then result[-1]+=$'\r'; fi
    if [[ ${#result[@]} -gt 0 && -n ${result[-1]%$'\r'} ]]; then result+=("$CB_CFG_DEFAULT_CR"); fi
    result+=("[$scope]$CB_CFG_DEFAULT_CR")
    if [[ $CB_CFG_FINAL_NEWLINE -eq 1 ]]; then line+="$CB_CFG_DEFAULT_CR"; fi
    result+=("$line")
    cb_config_write_lines "$output" "$CB_CFG_FINAL_NEWLINE" result
    return
  fi
  if (( insert_at < ${#CB_CFG_LINES[@]} )); then
    line+="$CB_CFG_DEFAULT_CR"
  elif [[ ${#CB_CFG_LINES[@]} -gt 0 && ${CB_CFG_LINES[-1]} != *$'\r' && -n $CB_CFG_DEFAULT_CR ]]; then
    CB_CFG_LINES[-1]+=$'\r'
    if [[ $CB_CFG_FINAL_NEWLINE -eq 1 ]]; then line+="$CB_CFG_DEFAULT_CR"; fi
  elif [[ $CB_CFG_FINAL_NEWLINE -eq 1 ]]; then line+="$CB_CFG_DEFAULT_CR"
  fi
  for ((index=0; index<=${#CB_CFG_LINES[@]}; index++)); do
    if [[ $index -eq $insert_at ]]; then result+=("$line"); fi
    if [[ $index -lt ${#CB_CFG_LINES[@]} ]]; then result+=("${CB_CFG_LINES[$index]}"); fi
  done
  cb_config_write_lines "$output" "$CB_CFG_FINAL_NEWLINE" result
}

cb_config_remove_empty_created_table() {
  local input=$1 output=$2 scope=$3 separator_added=$4 header end index content meaningful=0
  local -a result=()
  cb_config_scan "$input"
  header=${CB_CFG_TABLE_HEADER[$scope]-}
  if [[ -z $header ]]; then cp -- "$input" "$output"; return; fi
  end=${#CB_CFG_LINES[@]}
  for ((index=header+1; index<${#CB_CFG_LINES[@]}; index++)); do
    if [[ ${CB_CFG_LINE_TABLE[$index]-} != "$scope" ]]; then end=$index; break; fi
    content=${CB_CFG_LINES[$index]%$'\r'}; content=${content#"${content%%[!$' \t']*}"}
    # A comment inside a Baseline-created table is independent user content.
    # Keep the table once any non-blank line remains after managed keys leave.
    if [[ -n $content ]]; then meaningful=1; fi
  done
  if [[ $meaningful -eq 1 ]]; then cp -- "$input" "$output"; return; fi
  for ((index=0; index<${#CB_CFG_LINES[@]}; index++)); do
    if (( index >= header && index < end )); then continue; fi
    if [[ $separator_added == 1 && $index -eq $((header - 1)) && -z ${CB_CFG_LINES[$index]%$'\r'} ]]; then continue; fi
    result+=("${CB_CFG_LINES[$index]}")
  done
  cb_config_write_lines "$output" "$CB_CFG_FINAL_NEWLINE" result
}

cb_config_validate_candidate() {
  local candidate=$1 temp codex_candidate codex_path status before_hash after_hash before_identity after_identity cursor owner mode link_owner
  if [[ ${CODEX_BASELINE_TESTING:-0} == 1 && ${CODEX_BASELINE_TEST_SKIP_CONFIG_VALIDATION:-0} == 1 ]]; then return 0; fi
  cb_require_command realpath
  codex_candidate=$(type -P codex 2>/dev/null || true)
  [[ $codex_candidate == /* && ! $codex_candidate == *$'\n'* && ! $codex_candidate == *$'\r'* ]] ||
    cb_die 'config mutation requires an absolute Codex executable path'
  if [[ -L $codex_candidate ]]; then
    link_owner=$(stat -c '%u' -- "$codex_candidate") || cb_die 'cannot inspect Codex executable link ownership'
    [[ $link_owner == 0 || $link_owner == "$EUID" ]] || cb_die 'Codex executable link has an unexpected owner'
  fi
  codex_path=$(realpath -e -- "$codex_candidate") || cb_die 'cannot resolve Codex executable'
  [[ $codex_path == /* && -f $codex_path && ! -L $codex_path && -x $codex_path ]] ||
    cb_die 'resolved Codex executable is not an ordinary executable file'
  for cursor in "$(dirname -- "$codex_candidate")" "$(dirname -- "$codex_path")"; do
    while [[ $cursor != / ]]; do
      cursor=$(realpath -e -- "$cursor") || cb_die 'cannot resolve Codex executable ancestry'
      owner=$(stat -Lc '%u' -- "$cursor") || cb_die 'cannot inspect Codex executable ancestry owner'
      mode=$(stat -Lc '%a' -- "$cursor") || cb_die 'cannot inspect Codex executable ancestry mode'
      [[ $owner == 0 || $owner == "$EUID" ]] || cb_die 'Codex executable ancestry has an unexpected owner'
      [[ $((8#$mode & 0022)) -eq 0 ]] || cb_die 'Codex executable ancestry is group/other writable'
      cursor=$(dirname -- "$cursor")
    done
  done
  owner=$(stat -Lc '%u' -- "$codex_path") || cb_die 'cannot inspect resolved Codex executable owner'
  mode=$(stat -Lc '%a' -- "$codex_path") || cb_die 'cannot inspect resolved Codex executable mode'
  [[ $owner == 0 || $owner == "$EUID" ]] || cb_die 'resolved Codex executable has an unexpected owner'
  [[ $((8#$mode & 0022)) -eq 0 ]] || cb_die 'resolved Codex executable is group/other writable'
  before_hash=$(cb_sha256_file "$codex_path")
  before_identity=$(stat -Lc '%d:%i:%h' -- "$codex_path") || cb_die 'cannot inspect resolved Codex executable identity'
  temp=$(mktemp -d "${TMPDIR:-/tmp}/codex-baseline-config-validate.XXXXXX")
  cb_register_temp "$temp"
  mkdir -- "$temp/sqlite"
  cp -- "$candidate" "$temp/config.toml"
  set +e
  env -i HOME="$temp" CODEX_HOME="$temp" CODEX_SQLITE_HOME="$temp/sqlite" PATH=/usr/bin:/bin LANG=C.UTF-8 LC_ALL=C.UTF-8 \
    "$codex_path" --strict-config --version >/dev/null 2>&1
  status=$?
  set -e
  if [[ ${CODEX_BASELINE_TESTING:-0} == 1 && ${CODEX_BASELINE_TEST_SWAP_CODEX_AFTER_VALIDATION:-0} == 1 ]]; then
    printf '\n# codex-baseline executable swap fixture\n' >>"$codex_path"
  fi
  after_hash=$(cb_sha256_file "$codex_path")
  after_identity=$(stat -Lc '%d:%i:%h' -- "$codex_path") || cb_die 'cannot re-inspect resolved Codex executable identity'
  [[ $before_hash == "$after_hash" && $before_identity == "$after_identity" ]] ||
    cb_die 'Codex executable changed during isolated config validation'
  [[ $status -eq 0 ]] || cb_die 'Codex rejected the isolated candidate config'
}

cb_config_tx_dir() {
  cb_require_tx_id "$1"
  printf '%s/%s' "$CB_CONFIG_TX_ROOT" "$1"
}

cb_config_current_tx() {
  cb_read_tx_pointer "$CB_CONFIG_CURRENT"
}

cb_config_current_dir() {
  local current
  current=$(cb_config_current_tx)
  [[ -n $current ]] || return 1
  cb_config_validate_tx "$current" committed
  printf '%s' "$(cb_config_tx_dir "$current")"
}

cb_config_current_dir_or_empty() {
  if [[ ! -e $CB_CONFIG_CURRENT && ! -L $CB_CONFIG_CURRENT ]]; then return 0; fi
  cb_config_current_dir
}

cb_config_validate_artifact() {
  local path=$1 label=$2 links owner
  [[ ! -L $path ]] || cb_die "symbolic config transaction $label is not allowed: $path"
  [[ -f $path ]] || cb_die "config transaction $label is not an ordinary file: $path"
  links=$(stat -Lc '%h' -- "$path")
  owner=$(stat -Lc '%u' -- "$path")
  [[ $links == 1 ]] || cb_die "config transaction $label has an unsafe link count: $path"
  [[ $owner == "$EUID" ]] || cb_die "config transaction $label is not owned by the current user: $path"
  [[ $(stat -Lc '%s' -- "$path") -le 1048576 ]] || cb_die "config transaction $label exceeds its size limit: $path"
}

cb_config_validate_token() {
  local id=$1 token=$2 label=$3
  case $id in
    agents_enabled|features_fast_mode)
      [[ $token == true || $token == false ]] || cb_die "invalid boolean token in $label"
      ;;
    agents_max)
      [[ $token =~ ^(0|[1-9][0-9]{0,5})$ ]] || cb_die "invalid integer token in $label"
      ;;
    service_tier)
      [[ $token =~ ^\"[a-z][a-z0-9_-]{0,31}\"$ ]] || cb_die "invalid enum token in $label"
      ;;
    *) cb_die "unknown managed config key in $label: $id" ;;
  esac
}

cb_config_valid_unix_id() {
  local value=$1
  [[ $value =~ ^(0|[1-9][0-9]{0,9})$ ]] || return 1
  [[ ${#value} -lt 10 ]] || (( 10#$value <= 4294967295 ))
}

cb_config_valid_unix_mode() {
  [[ $1 =~ ^(0|[1-7][0-7]{0,3})$ ]]
}

cb_config_validate_tx() {
  local tx=$1 expected_state=${2:-} dir entry name state operation version parent cursor parent_dir
  local target stage old existed value key_dir id actual_fields expected_fields prefix uid gid mode acl_state xattr_state physical
  cb_require_tx_id "$tx"
  dir=$(cb_config_tx_dir "$tx")
  [[ $(dirname -- "$dir") == "$CB_CONFIG_TX_ROOT" && -d $dir && ! -L $dir ]] || cb_die "unsafe or missing config transaction directory: $dir"
  expected_fields='contract,core_tx,desired_acl_state,desired_gid,desired_mode,desired_physical_hash,desired_projection_hash,desired_structure_hash,desired_uid,desired_xattr_state,old,operation,ownership,parent,previous_acl_state,previous_existed,previous_gid,previous_mode,previous_physical_hash,previous_projection_hash,previous_structure_hash,previous_uid,previous_xattr_state,schema,stage,stage_acl_state,stage_gid,stage_mode,stage_physical_hash,stage_uid,stage_xattr_state,state,target,version'
  actual_fields=''
  while IFS= read -r -d '' entry; do
    name=$(basename -- "$entry")
    [[ ! -L $entry ]] || cb_die "symbolic config transaction entry is not allowed: $entry"
    case $name in ownership) [[ -d $entry ]] || cb_die "config ownership entry is not a directory: $entry" ;; *) cb_require_scalar_file "$entry" "$tx/$name" ;; esac
    if [[ -n $actual_fields ]]; then actual_fields+=','; fi
    actual_fields+=$name
  done < <(find -P "$dir" -mindepth 1 -maxdepth 1 -print0 | LC_ALL=C sort -z)
  [[ $actual_fields == "$expected_fields" ]] || cb_die "config transaction has an invalid field inventory: $tx"
  [[ $(cb_read_field "$dir/schema") == 2 ]] || cb_die "unsupported config transaction schema: $tx"
  [[ $(cb_read_field "$dir/contract") == codex-baseline-config-transaction/v2 ]] || cb_die "config transaction contract mismatch: $tx"
  operation=$(cb_read_field "$dir/operation")
  case $operation in install-cap|optimize|restore|rollback|uninstall) ;; *) cb_die "invalid config transaction operation: $tx" ;; esac
  state=$(cb_read_field "$dir/state")
  case $state in planned|prepared|committing|committed|rolled-back) ;; *) cb_die "invalid config transaction state: $tx" ;; esac
  [[ -z $expected_state || $state == "$expected_state" ]] || cb_die "config transaction $tx is not $expected_state"
  version=$(cb_read_field "$dir/version")
  [[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || cb_die "invalid config transaction version: $tx"
  target=$(cb_read_field "$dir/target")
  stage=$(cb_read_field "$dir/stage")
  old=$(cb_read_field "$dir/old")
  [[ $target == "$CB_CONFIG_FILE" ]] || cb_die "config transaction target mismatch: $tx"
  [[ $stage == "$CB_CODEX_HOME/.codex-baseline-config-stage-$tx" ]] || cb_die "config transaction stage mismatch: $tx"
  [[ $old == "$CB_CODEX_HOME/.codex-baseline-config-old-$tx" ]] || cb_die "config transaction old-path mismatch: $tx"
  cb_assert_target_under "$target" "$CB_CODEX_HOME"
  cb_assert_target_under "$stage" "$CB_CODEX_HOME"
  cb_assert_target_under "$old" "$CB_CODEX_HOME"
  [[ ! -e $stage && ! -L $stage ]] || cb_config_validate_artifact "$stage" stage
  [[ ! -e $old && ! -L $old ]] || cb_config_validate_artifact "$old" old
  existed=$(cb_read_field "$dir/previous_existed")
  [[ $existed == 0 || $existed == 1 ]] || cb_die "invalid config previous-existed flag: $tx"
  for name in previous_physical_hash desired_physical_hash; do
    value=$(cb_read_field "$dir/$name")
    [[ $value == absent || $value =~ ^[0-9a-f]{64}$ ]] || cb_die "invalid config transaction hash $name: $tx"
  done
  [[ $existed == 1 || $(cb_read_field "$dir/previous_physical_hash") == absent ]] || cb_die "config previous hash/existence mismatch: $tx"
  for prefix in previous desired stage; do
    uid=$(cb_read_field "$dir/${prefix}_uid")
    gid=$(cb_read_field "$dir/${prefix}_gid")
    mode=$(cb_read_field "$dir/${prefix}_mode")
    acl_state=$(cb_read_field "$dir/${prefix}_acl_state")
    xattr_state=$(cb_read_field "$dir/${prefix}_xattr_state")
    if [[ $uid == absent || $gid == absent || $mode == absent || $acl_state == absent || $xattr_state == absent ]]; then
      [[ $uid == absent && $gid == absent && $mode == absent && $acl_state == absent && $xattr_state == absent ]] || \
        cb_die "partial absent config metadata in $prefix journal: $tx"
    else
      if [[ $acl_state != base-only || $xattr_state != none ]] || \
         ! cb_config_valid_unix_id "$uid" || ! cb_config_valid_unix_id "$gid" || ! cb_config_valid_unix_mode "$mode"; then
        cb_die "invalid config metadata in $prefix journal: $tx"
      fi
    fi
  done
  if [[ $existed == 1 ]]; then
    [[ $(cb_read_field "$dir/previous_uid") != absent ]] || cb_die "existing config lacks previous metadata: $tx"
    [[ $(cb_read_field "$dir/previous_uid") == "$EUID" ]] || cb_die "existing config journal owner mismatch: $tx"
  else
    [[ $(cb_read_field "$dir/previous_uid") == absent ]] || cb_die "absent config contains previous metadata: $tx"
  fi
  if [[ $(cb_read_field "$dir/desired_physical_hash") == absent ]]; then
    [[ $(cb_read_field "$dir/desired_uid") == absent ]] || cb_die "absent desired config contains metadata: $tx"
  else
    [[ $(cb_read_field "$dir/desired_uid") != absent ]] || cb_die "present desired config lacks metadata: $tx"
    [[ $(cb_read_field "$dir/desired_uid") == "$EUID" ]] || cb_die "desired config journal owner mismatch: $tx"
  fi
  physical=$(cb_read_field "$dir/stage_physical_hash")
  [[ $physical =~ ^[0-9a-f]{64}$ && $(cb_read_field "$dir/stage_uid") != absent ]] || cb_die "invalid config stage metadata: $tx"
  [[ $(cb_read_field "$dir/stage_uid") == "$EUID" ]] || cb_die "config stage journal owner mismatch: $tx"
  for name in previous_projection_hash desired_projection_hash previous_structure_hash desired_structure_hash; do
    [[ $(cb_read_field "$dir/$name") =~ ^[0-9a-f]{64}$ ]] || cb_die "invalid config transaction hash $name: $tx"
  done
  parent=$(cb_read_field "$dir/parent")
  cursor=$parent
  declare -A seen=(["$tx"]=1)
  while [[ -n $cursor ]]; do
    cb_require_tx_id "$cursor"
    [[ -z ${seen[$cursor]+x} ]] || cb_die "config transaction parent cycle: $tx"
    seen[$cursor]=1
    parent_dir=$(cb_config_tx_dir "$cursor")
    [[ -d $parent_dir && ! -L $parent_dir ]] || cb_die "config transaction parent is missing: $cursor"
    cb_require_scalar_file "$parent_dir/state" "$cursor/state"
    [[ $(cb_read_field "$parent_dir/state") == committed ]] || cb_die "config transaction parent is not committed: $cursor"
    cb_require_scalar_file "$parent_dir/parent" "$cursor/parent"
    cursor=$(cb_read_field "$parent_dir/parent")
  done
  value=$(cb_read_field "$dir/core_tx")
  if [[ -n $value ]]; then
    cb_require_tx_id "$value"
    [[ -d $CB_STATE_ROOT/transactions/$value && ! -L $CB_STATE_ROOT/transactions/$value ]] || cb_die "config transaction core reference is missing: $value"
  fi
  [[ -d $dir/ownership/keys && ! -L $dir/ownership/keys ]] || cb_die "config ownership inventory is missing: $tx"
  for key_dir in "$dir"/ownership/keys/*; do
    [[ -e $key_dir || -L $key_dir ]] || continue
    [[ -d $key_dir && ! -L $key_dir ]] || cb_die "invalid config ownership entry: $key_dir"
    id=$(basename -- "$key_dir")
    case $id in agents_enabled|agents_max|service_tier|features_fast_mode) ;; *) cb_die "unknown config ownership key: $id" ;; esac
    actual_fields=''
    while IFS= read -r -d '' entry; do
      [[ -f $entry && ! -L $entry ]] || cb_die "invalid config ownership field: $entry"
      cb_require_scalar_file "$entry" "$tx/$id/$(basename -- "$entry")"
      if [[ -n $actual_fields ]]; then actual_fields+=','; fi
      actual_fields+=$(basename -- "$entry")
    done < <(find -P "$key_dir" -mindepth 1 -maxdepth 1 -print0 | LC_ALL=C sort -z)
    expected_fields='core_tx,created_table,installed_token,path,prior_file_existed,prior_state,prior_token,separator_added,type'
    [[ $actual_fields == "$expected_fields" ]] || cb_die "config ownership field inventory mismatch: $id"
    [[ $(cb_read_field "$key_dir/path") == "$(cb_config_key_path "$id")" ]] || cb_die "config ownership path mismatch: $id"
    [[ $(cb_read_field "$key_dir/type") == "$(cb_config_key_type "$id")" ]] || cb_die "config ownership type mismatch: $id"
    for name in prior_file_existed created_table separator_added; do
      value=$(cb_read_field "$key_dir/$name"); [[ $value == 0 || $value == 1 ]] || cb_die "invalid config ownership flag $name: $id"
    done
    value=$(cb_read_field "$key_dir/prior_state")
    case $value in
      present) cb_config_validate_token "$id" "$(cb_read_field "$key_dir/prior_token")" "$id/prior_token" ;;
      absent) [[ -z $(cb_read_field "$key_dir/prior_token") ]] || cb_die "absent config ownership has a prior token: $id" ;;
      *) cb_die "invalid config ownership prior state: $id" ;;
    esac
    cb_config_validate_token "$id" "$(cb_read_field "$key_dir/installed_token")" "$id/installed_token"
    value=$(cb_read_field "$key_dir/core_tx")
    if [[ -n $value ]]; then cb_require_tx_id "$value"; [[ -d $CB_STATE_ROOT/transactions/$value && ! -L $CB_STATE_ROOT/transactions/$value ]] || cb_die "config ownership core reference is missing: $id"; fi
  done
}

cb_config_live_token() {
  local id=$1
  if [[ -n ${CB_CFG_INDEX[$id]-} ]]; then printf '%s' "${CB_CFG_TOKEN[$id]}"; else printf '__ABSENT__'; fi
}

cb_config_projection_hash() {
  local input=$1 id
  cb_config_scan "$input"
  {
    for id in agents_enabled agents_max service_tier features_fast_mode; do
      printf '%s\t%s\n' "$(cb_config_key_path "$id")" "$(cb_config_live_token "$id")"
    done
  } | cb_sha256_text
}

cb_config_structure_hash() {
  local input=$1 id
  cb_config_scan "$input"
  {
    printf 'bom=%s\nfinal-newline=%s\n' "$([[ ${CB_CFG_LINES[0]-} == $'\xEF\xBB\xBF'* ]] && printf 1 || printf 0)" "$CB_CFG_FINAL_NEWLINE"
    for id in agents_enabled agents_max service_tier features_fast_mode; do
      printf '%s\t%s\n' "$(cb_config_key_path "$id")" "${CB_CFG_INDEX[$id]-absent}"
    done
    printf 'table-agents=%s\ntable-features=%s\n' "${CB_CFG_TABLE_HEADER[agents]-absent}" "${CB_CFG_TABLE_HEADER[features]-absent}"
  } | cb_sha256_text
}

cb_config_assert_owned_clean() {
  local current_dir key_dir id installed live
  current_dir=$(cb_config_current_dir_or_empty)
  [[ -n $current_dir ]] || return 0
  [[ -d $current_dir && ! -L $current_dir && $(cb_read_field "$current_dir/state") == committed ]] || cb_die 'config ownership state is incomplete'
  cb_config_scan "${CB_CONFIG_FILE:-/dev/null}"
  for key_dir in "$current_dir"/ownership/keys/*; do
    [[ -d $key_dir && ! -L $key_dir ]] || continue
    id=$(basename -- "$key_dir")
    installed=$(cb_read_field "$key_dir/installed_token")
    live=$(cb_config_live_token "$id")
    [[ $live == "$installed" ]] || cb_die "managed config key drifted: $(cb_config_key_path "$id")"
  done
}

cb_config_assert_journal_metadata() {
  local dir=$1 prefix=$2 path=$3 label=$4
  cb_config_assert_metadata_matches "$path" \
    "$(cb_read_field "$dir/${prefix}_uid")" \
    "$(cb_read_field "$dir/${prefix}_gid")" \
    "$(cb_read_field "$dir/${prefix}_mode")" \
    "$(cb_read_field "$dir/${prefix}_acl_state")" \
    "$(cb_read_field "$dir/${prefix}_xattr_state")" "$label"
}

cb_config_recover_pending() {
  local tx dir target stage old existed before_hash desired_hash live_hash
  tx=$(cb_read_tx_pointer "$CB_CONFIG_PENDING")
  [[ -n $tx ]] || return 0
  dir=$(cb_config_tx_dir "$tx")
  [[ -d $dir && ! -L $dir ]] || cb_die "config transaction is missing: $tx"
  cb_config_validate_tx "$tx"
  cb_config_assert_path
  cb_config_assert_mutation_metadata
  target=$(cb_read_field "$dir/target"); stage=$(cb_read_field "$dir/stage"); old=$(cb_read_field "$dir/old")
  existed=$(cb_read_field "$dir/previous_existed"); before_hash=$(cb_read_field "$dir/previous_physical_hash"); desired_hash=$(cb_read_field "$dir/desired_physical_hash")
  if [[ -e $stage || -L $stage ]]; then
    [[ $(cb_sha256_file "$stage") == "$(cb_read_field "$dir/stage_physical_hash")" ]] || cb_die 'config recovery stage content is unverifiable'
    cb_config_assert_journal_metadata "$dir" stage "$stage" 'config recovery stage'
  fi
  if [[ -e $old || -L $old ]]; then
    [[ $existed == 1 && $(cb_sha256_file "$old") == "$before_hash" ]] || cb_die 'config recovery preimage content is unverifiable'
    cb_config_assert_journal_metadata "$dir" previous "$old" 'config recovery preimage'
  fi
  live_hash=absent; [[ ! -e $target ]] || live_hash=$(cb_sha256_file "$target")
  if [[ $live_hash == "$desired_hash" ]]; then
    if [[ $desired_hash != absent ]]; then cb_config_assert_journal_metadata "$dir" desired "$target" 'desired config recovery target'; fi
    if [[ $existed == 1 ]]; then [[ -f $old && ! -L $old ]] || cb_die 'config recovery preimage is missing'; else [[ ! -e $old && ! -L $old ]] || cb_die 'unexpected config recovery preimage'; fi
    cb_write_field "$CB_CONFIG_CURRENT" "$tx"
    cb_write_field "$dir/state" committed
    [[ ! -e $old ]] || rm -f -- "$old"
    [[ ! -e $stage ]] || rm -f -- "$stage"
  elif [[ $live_hash == "$before_hash" || ( $existed == 0 && $live_hash == absent ) ]]; then
    if [[ $existed == 1 ]]; then cb_config_assert_journal_metadata "$dir" previous "$target" 'previous config recovery target'; fi
    [[ ! -e $stage ]] || rm -f -- "$stage"
    [[ ! -e $old ]] || rm -f -- "$old"
    cb_write_field "$dir/state" rolled-back
  elif [[ $live_hash == absent && -f $old && $(cb_sha256_file "$old") == "$before_hash" ]]; then
    cb_config_assert_journal_metadata "$dir" previous "$old" 'config recovery preimage before restore'
    [[ $(cb_sha256_file "$old") == "$before_hash" ]] || cb_die 'config recovery preimage changed before restore'
    mv -T -- "$old" "$target"
    [[ $(cb_sha256_file "$target") == "$before_hash" ]] || cb_die 'restored config recovery content mismatch'
    cb_config_assert_journal_metadata "$dir" previous "$target" 'restored config recovery target'
    cb_write_field "$dir/state" rolled-back
  else
    cb_die 'config transaction recovery found an unverifiable target state'
  fi
  rm -f -- "$CB_CONFIG_PENDING"
  cb_sync_parent "$CB_CONFIG_PENDING"
}

cb_config_prepare_next_ownership() {
  local tx_dir=$1 current_dir=$2 core_tx=${3:-} id key_dir prior_state prior_token scope created_table=0 separator_added=0 original_count
  cb_safe_mkdir_path "$tx_dir/ownership/keys"
  if [[ -n $current_dir ]]; then
    for key_dir in "$current_dir"/ownership/keys/*; do
      [[ -d $key_dir && ! -L $key_dir ]] || continue
      cp -a -- "$key_dir" "$tx_dir/ownership/keys/"
    done
  fi
  for id in agents_enabled agents_max service_tier features_fast_mode; do
    [[ -n ${CB_CFG_ACTION[$id]+x} ]] || continue
    key_dir="$tx_dir/ownership/keys/$id"
    if [[ ${CB_CFG_NEXT_OWN[$id]} == 0 ]]; then
      [[ ! -e $key_dir ]] || rm -rf -- "$key_dir"
      continue
    fi
    if [[ ! -d $key_dir ]]; then
      created_table=0
      separator_added=0
      cb_safe_mkdir_path "$key_dir"
      if [[ ${CB_CFG_ORIGINAL_PRESENT[$id]-0} == 1 ]]; then prior_state=present; prior_token=${CB_CFG_ORIGINAL_TOKEN[$id]}; else prior_state=absent; prior_token=''; fi
      cb_write_field "$key_dir/path" "$(cb_config_key_path "$id")"
      cb_write_field "$key_dir/type" "$(cb_config_key_type "$id")"
      cb_write_field "$key_dir/prior_state" "$prior_state"
      cb_write_field "$key_dir/prior_token" "$prior_token"
      cb_write_field "$key_dir/prior_file_existed" "${CB_CFG_ORIGINAL_FILE_EXISTED:-1}"
      cb_write_field "$key_dir/core_tx" "$core_tx"
      case $id in agents_enabled|agents_max) scope=agents ;; features_fast_mode) scope=features ;; *) scope='' ;; esac
      if [[ -n $scope && ${CB_CFG_ORIGINAL_TABLE[$scope]-0} == 0 ]]; then
        created_table=1
        original_count=${CB_CFG_ORIGINAL_LINE_COUNT:-0}
        if [[ $original_count -gt 0 && -n ${CB_CFG_ORIGINAL_LAST_LINE:-} ]]; then separator_added=1; fi
      fi
      cb_write_field "$key_dir/created_table" "$created_table"
      cb_write_field "$key_dir/separator_added" "$separator_added"
    fi
    cb_write_field "$key_dir/installed_token" "${CB_CFG_ACTION[$id]}"
  done
}

cb_config_apply_actions() {
  local operation=$1 core_tx=${2:-} plan_mode=${3:-apply} input candidate next id before_hash desired_hash stage_hash previous_projection desired_projection previous_structure desired_structure tx tx_dir current_dir='' stage old existed=0 desired_present=1 remove_origin=0 all_released=1 key_dir
  local before_mode=absent before_owner=absent before_group=absent before_acl_state=absent before_xattr_state=absent
  local desired_mode=absent desired_owner=absent desired_group=absent desired_acl_state=absent desired_xattr_state=absent
  local stage_mode=600 stage_owner=$EUID stage_group='' stage_acl_state=base-only stage_xattr_state=none parent_mode
  local before_acl='' before_xattrs='' stage_acl='' stage_xattrs='' final_acl='' final_xattrs=''
  CB_CONFIG_PLAN_CHANGE=0
  cb_config_assert_path
  if [[ $plan_mode == preflight ]]; then
    [[ ! -e $CB_CONFIG_PENDING && ! -L $CB_CONFIG_PENDING ]] || cb_die 'an incomplete config transaction requires recovery before auto-cap preflight'
  else
    cb_config_recover_pending
  fi
  cb_config_assert_owned_clean
  input=$(mktemp "${TMPDIR:-/tmp}/codex-baseline-config-input.XXXXXX")
  candidate=$(mktemp "${TMPDIR:-/tmp}/codex-baseline-config-candidate.XXXXXX")
  cb_register_temp "$input"; cb_register_temp "$candidate"
  if [[ -e $CB_CONFIG_FILE ]]; then cp -- "$CB_CONFIG_FILE" "$input"; existed=1; else : >"$input"; fi
  CB_CFG_ORIGINAL_FILE_EXISTED=$existed
  cb_config_scan "$input"
  declare -gA CB_CFG_ORIGINAL_PRESENT=() CB_CFG_ORIGINAL_TOKEN=()
  declare -gA CB_CFG_ORIGINAL_TABLE=([agents]=0 [features]=0)
  [[ -z ${CB_CFG_TABLE_HEADER[agents]+x} ]] || CB_CFG_ORIGINAL_TABLE[agents]=1
  [[ -z ${CB_CFG_TABLE_HEADER[features]+x} ]] || CB_CFG_ORIGINAL_TABLE[features]=1
  CB_CFG_ORIGINAL_LINE_COUNT=${#CB_CFG_LINES[@]}
  CB_CFG_ORIGINAL_LAST_LINE=''
  [[ $CB_CFG_ORIGINAL_LINE_COUNT -eq 0 ]] || CB_CFG_ORIGINAL_LAST_LINE=${CB_CFG_LINES[$((CB_CFG_ORIGINAL_LINE_COUNT - 1))]%$'\r'}
  for id in agents_enabled agents_max service_tier features_fast_mode; do
    if [[ -n ${CB_CFG_INDEX[$id]-} ]]; then CB_CFG_ORIGINAL_PRESENT[$id]=1; CB_CFG_ORIGINAL_TOKEN[$id]=${CB_CFG_TOKEN[$id]}; else CB_CFG_ORIGINAL_PRESENT[$id]=0; CB_CFG_ORIGINAL_TOKEN[$id]=''; fi
  done
  current_dir=$(cb_config_current_dir_or_empty)
  if [[ -z $core_tx && -n $current_dir ]]; then core_tx=$(cb_read_field "$current_dir/core_tx"); fi
  cp -- "$input" "$candidate"
  for id in agents_enabled agents_max service_tier features_fast_mode; do
    [[ -n ${CB_CFG_ACTION[$id]+x} ]] || continue
    next="$candidate.next"
    cb_config_patch_one "$candidate" "$next" "$id" "${CB_CFG_ACTION[$id]}"
    mv -- "$next" "$candidate"
  done
  if [[ -n $current_dir ]]; then
    local scope key_dir created separator cleanup
    for scope in agents features; do
      created=0; separator=0
      for id in $([[ $scope == agents ]] && printf '%s\n' agents_enabled agents_max || printf '%s\n' features_fast_mode); do
        key_dir="$current_dir/ownership/keys/$id"
        [[ -d $key_dir ]] || continue
        [[ $(cb_read_field "$key_dir/created_table") == 1 ]] && created=1
        [[ $(cb_read_field "$key_dir/separator_added") == 1 ]] && separator=1
      done
      if [[ $created == 1 ]]; then
        cleanup="$candidate.cleanup"
        cb_config_remove_empty_created_table "$candidate" "$cleanup" "$scope" "$separator"
        mv -- "$cleanup" "$candidate"
      fi
    done
  fi
  if [[ $operation == restore || $operation == rollback || $operation == uninstall ]] && [[ ! -s $candidate && -n $current_dir ]]; then
    for key_dir in "$current_dir"/ownership/keys/*; do
      [[ -d $key_dir && ! -L $key_dir ]] || continue
      id=$(basename -- "$key_dir")
      [[ ${CB_CFG_NEXT_OWN[$id]-1} == 0 ]] || all_released=0
      if [[ -f $key_dir/prior_file_existed && $(cb_read_field "$key_dir/prior_file_existed") == 0 ]]; then remove_origin=1; fi
    done
    if [[ $all_released == 1 && $remove_origin == 1 ]]; then desired_present=0; fi
  fi
  before_hash=absent; [[ $existed == 0 ]] || before_hash=$(cb_sha256_file "$input")
  stage_hash=$(cb_sha256_file "$candidate")
  if [[ $desired_present == 1 ]]; then desired_hash=$(cb_sha256_file "$candidate"); else desired_hash=absent; fi
  previous_projection=$(cb_config_projection_hash "$input")
  desired_projection=$(cb_config_projection_hash "$candidate")
  previous_structure=$(cb_config_structure_hash "$input")
  desired_structure=$(cb_config_structure_hash "$candidate")
  if [[ $before_hash == "$desired_hash" ]]; then
    return 0
  fi
  CB_CONFIG_PLAN_CHANGE=1
  if [[ $plan_mode == preflight || ( $CB_DRY_RUN -eq 0 && ( $CB_OPTIMIZE_APPLY -ne 0 || $operation != optimize ) ) ]]; then
    cb_config_assert_mutation_metadata
    if [[ $existed == 1 ]]; then
      before_owner=$CB_CONFIG_META_UID; before_group=$CB_CONFIG_META_GID; before_mode=$CB_CONFIG_META_MODE
      before_acl_state=$CB_CONFIG_META_ACL_STATE; before_xattr_state=$CB_CONFIG_META_XATTR_STATE
    fi
  fi
  cb_config_validate_candidate "$candidate"
  if [[ $plan_mode == preflight || $CB_DRY_RUN -eq 1 || $CB_OPTIMIZE_APPLY -eq 0 && $operation == optimize ]]; then
    return 0
  fi
  cb_require_command id
  stage_group=$(id -g)
  parent_mode=$(stat -Lc '%a' -- "$CB_CODEX_HOME")
  if (( (8#$parent_mode & 02000) != 0 )); then stage_group=$(stat -Lc '%g' -- "$CB_CODEX_HOME"); fi
  if [[ $desired_present == 1 ]]; then
    if [[ $existed == 1 ]]; then
      desired_owner=$before_owner; desired_group=$before_group; desired_mode=$before_mode
      desired_acl_state=$before_acl_state; desired_xattr_state=$before_xattr_state
      stage_owner=$desired_owner; stage_group=$desired_group; stage_mode=$desired_mode
      stage_acl_state=$desired_acl_state; stage_xattr_state=$desired_xattr_state
    else
      desired_owner=$stage_owner; desired_group=$stage_group; desired_mode=$stage_mode
      desired_acl_state=$stage_acl_state; desired_xattr_state=$stage_xattr_state
    fi
  fi
  cb_safe_mkdir_path "$CB_CONFIG_TX_ROOT"
  tx=$(date -u '+%Y%m%dT%H%M%SZ')-$$-$RANDOM
  tx_dir=$(cb_config_tx_dir "$tx")
  cb_safe_mkdir_path "$tx_dir"
  stage="$CB_CODEX_HOME/.codex-baseline-config-stage-$tx"
  old="$CB_CODEX_HOME/.codex-baseline-config-old-$tx"
  [[ ! -e $stage && ! -L $stage && ! -e $old && ! -L $old ]] || cb_die 'config staging collision'
  cb_write_field "$tx_dir/schema" 2
  cb_write_field "$tx_dir/contract" codex-baseline-config-transaction/v2
  cb_write_field "$tx_dir/operation" "$operation"
  cb_write_field "$tx_dir/version" "$CB_VERSION"
  cb_write_field "$tx_dir/parent" "$(cb_config_current_tx)"
  cb_write_field "$tx_dir/core_tx" "$core_tx"
  cb_write_field "$tx_dir/target" "$CB_CONFIG_FILE"
  cb_write_field "$tx_dir/stage" "$stage"
  cb_write_field "$tx_dir/old" "$old"
  cb_write_field "$tx_dir/previous_existed" "$existed"
  cb_write_field "$tx_dir/previous_physical_hash" "$before_hash"
  cb_write_field "$tx_dir/previous_uid" "$before_owner"
  cb_write_field "$tx_dir/previous_gid" "$before_group"
  cb_write_field "$tx_dir/previous_mode" "$before_mode"
  cb_write_field "$tx_dir/previous_acl_state" "$before_acl_state"
  cb_write_field "$tx_dir/previous_xattr_state" "$before_xattr_state"
  cb_write_field "$tx_dir/desired_physical_hash" "$desired_hash"
  cb_write_field "$tx_dir/desired_uid" "$desired_owner"
  cb_write_field "$tx_dir/desired_gid" "$desired_group"
  cb_write_field "$tx_dir/desired_mode" "$desired_mode"
  cb_write_field "$tx_dir/desired_acl_state" "$desired_acl_state"
  cb_write_field "$tx_dir/desired_xattr_state" "$desired_xattr_state"
  cb_write_field "$tx_dir/stage_physical_hash" "$stage_hash"
  cb_write_field "$tx_dir/stage_uid" "$stage_owner"
  cb_write_field "$tx_dir/stage_gid" "$stage_group"
  cb_write_field "$tx_dir/stage_mode" "$stage_mode"
  cb_write_field "$tx_dir/stage_acl_state" "$stage_acl_state"
  cb_write_field "$tx_dir/stage_xattr_state" "$stage_xattr_state"
  cb_write_field "$tx_dir/previous_projection_hash" "$previous_projection"
  cb_write_field "$tx_dir/desired_projection_hash" "$desired_projection"
  cb_write_field "$tx_dir/previous_structure_hash" "$previous_structure"
  cb_write_field "$tx_dir/desired_structure_hash" "$desired_structure"
  cb_write_field "$tx_dir/state" planned
  cb_config_prepare_next_ownership "$tx_dir" "$current_dir" "$core_tx"
  cp -- "$candidate" "$stage"
  if [[ $desired_present == 1 ]]; then
    if [[ $existed == 1 ]]; then
      cp --attributes-only --preserve=all -- "$CB_CONFIG_FILE" "$stage" || cb_die 'cannot preserve config.toml metadata on the replacement stage'
      [[ $(stat -Lc '%a' -- "$stage") == "$before_mode" && $(stat -Lc '%u' -- "$stage") == "$before_owner" && $(stat -Lc '%g' -- "$stage") == "$before_group" ]] || cb_die 'config.toml mode/owner/group did not copy exactly to the replacement stage'
      before_acl=$(getfacl -cp -- "$CB_CONFIG_FILE") || cb_die 'cannot inspect config.toml ACL'
      stage_acl=$(getfacl -cp -- "$stage") || cb_die 'cannot inspect replacement-stage ACL'
      [[ $stage_acl == "$before_acl" ]] || cb_die 'config.toml ACL did not copy exactly to the replacement stage'
      before_xattrs=$(getfattr --absolute-names -m - -d --encoding=hex -- "$CB_CONFIG_FILE" 2>/dev/null | sed '/^# file:/d') || cb_die 'cannot inspect config.toml extended attributes'
      stage_xattrs=$(getfattr --absolute-names -m - -d --encoding=hex -- "$stage" 2>/dev/null | sed '/^# file:/d') || cb_die 'cannot inspect replacement-stage extended attributes'
      [[ $stage_xattrs == "$before_xattrs" ]] || cb_die 'config.toml extended attributes did not copy exactly to the replacement stage'
    else
      chmod 0600 "$stage"
    fi
    stage_acl=$(getfacl -cp -- "$stage" 2>/dev/null || cb_die 'cannot inspect replacement-stage ACL')
    if grep -Eq '^(default:|user:[^:]|group:[^:]|mask:)' <<<"$stage_acl"; then
      cb_die 'replacement stage has an extended ACL that cannot be preserved safely'
    fi
    stage_xattrs=$(getfattr --absolute-names -m - -d --encoding=hex -- "$stage" 2>/dev/null | sed '/^#/d;/^[[:space:]]*$/d') || cb_die 'cannot inspect replacement-stage extended attributes'
    [[ -z $stage_xattrs ]] || cb_die 'replacement stage has extended attributes that cannot be preserved safely'
  else
    chmod 0600 "$stage"
  fi
  [[ $(cb_sha256_file "$stage") == "$stage_hash" ]] || cb_die 'config.toml stage content changed during preparation'
  cb_config_assert_journal_metadata "$tx_dir" stage "$stage" 'config replacement stage'
  cb_sync_file "$stage"
  if [[ $existed == 1 && $desired_present == 1 ]]; then
    cp --preserve=all -- "$CB_CONFIG_FILE" "$old" || cb_die 'cannot create the config.toml recovery preimage'
    [[ $(cb_sha256_file "$old") == "$before_hash" ]] || cb_die 'config.toml recovery preimage hash mismatch'
    cb_config_assert_journal_metadata "$tx_dir" previous "$old" 'config.toml recovery preimage'
    cb_sync_file "$old"
  fi
  cb_write_field "$tx_dir/state" prepared
  if [[ ${CODEX_BASELINE_TESTING:-0} == 1 && ${CODEX_BASELINE_TEST_FAIL_AFTER_CONFIG_PREPARE_BEFORE_PENDING:-0} == 1 ]]; then
    cb_die 'test fault after config preparation and before recovery publication'
  fi
  cb_write_field "$CB_CONFIG_PENDING" "$tx"
  cb_sync_parent "$CB_CONFIG_PENDING"
  cb_write_field "$tx_dir/state" committing
  cb_config_assert_path
  if [[ $existed == 1 ]]; then
    [[ $(cb_sha256_file "$CB_CONFIG_FILE") == "$before_hash" ]] || cb_die 'config.toml changed before atomic replace'
    cb_config_assert_journal_metadata "$tx_dir" previous "$CB_CONFIG_FILE" 'config.toml before atomic replace'
    if [[ $desired_present != 1 ]]; then
      cb_config_test_edit_before_rename
      [[ $(cb_sha256_file "$CB_CONFIG_FILE") == "$before_hash" ]] || cb_die 'config.toml changed immediately before atomic remove'
      cb_config_assert_journal_metadata "$tx_dir" previous "$CB_CONFIG_FILE" 'config.toml immediately before atomic remove'
      mv -T -- "$CB_CONFIG_FILE" "$old"
      cb_sync_parent "$CB_CONFIG_FILE"
      cb_fault_after_mutation "config-moved-old:$CB_CONFIG_FILE"
    fi
  else
    [[ ! -e $CB_CONFIG_FILE && ! -L $CB_CONFIG_FILE ]] || cb_die 'config.toml appeared before atomic create'
  fi
  if [[ $desired_present == 1 ]]; then
    cb_config_test_edit_before_rename
    if [[ $existed == 1 ]]; then
      [[ $(cb_sha256_file "$CB_CONFIG_FILE") == "$before_hash" ]] || cb_die 'config.toml changed immediately before atomic replace'
      cb_config_assert_journal_metadata "$tx_dir" previous "$CB_CONFIG_FILE" 'config.toml immediately before atomic replace'
    else
      [[ ! -e $CB_CONFIG_FILE && ! -L $CB_CONFIG_FILE ]] || cb_die 'config.toml appeared immediately before atomic create'
    fi
    [[ $(cb_sha256_file "$stage") == "$stage_hash" ]] || cb_die 'config.toml stage changed immediately before atomic replace'
    cb_config_assert_journal_metadata "$tx_dir" stage "$stage" 'config stage immediately before atomic replace'
    mv -Tf -- "$stage" "$CB_CONFIG_FILE"
    cb_sync_file "$CB_CONFIG_FILE"
    cb_sync_parent "$CB_CONFIG_FILE"
  else
    rm -f -- "$stage"
  fi
  cb_fault_after_mutation "config-committed:$CB_CONFIG_FILE"
  if [[ $desired_present == 1 ]]; then
    [[ $(cb_sha256_file "$CB_CONFIG_FILE") == "$desired_hash" ]] || cb_die 'config.toml post-commit hash mismatch'
    cb_config_assert_journal_metadata "$tx_dir" desired "$CB_CONFIG_FILE" 'committed config.toml'
    if [[ $existed == 1 ]]; then
      [[ $(stat -Lc '%a' -- "$CB_CONFIG_FILE") == "$before_mode" && $(stat -Lc '%u' -- "$CB_CONFIG_FILE") == "$before_owner" && $(stat -Lc '%g' -- "$CB_CONFIG_FILE") == "$before_group" ]] || cb_die 'config.toml final mode/owner/group changed during replace'
      final_acl=$(getfacl -cp -- "$CB_CONFIG_FILE") || cb_die 'cannot inspect final config.toml ACL'; [[ $final_acl == "$before_acl" ]] || cb_die 'config.toml final ACL changed during replace'
      final_xattrs=$(getfattr --absolute-names -m - -d --encoding=hex -- "$CB_CONFIG_FILE" 2>/dev/null | sed '/^# file:/d') || cb_die 'cannot inspect final config.toml extended attributes'; [[ $final_xattrs == "$before_xattrs" ]] || cb_die 'config.toml final extended attributes changed during replace'
    fi
  else
    [[ ! -e $CB_CONFIG_FILE && ! -L $CB_CONFIG_FILE ]] || cb_die 'config.toml post-commit absence mismatch'
  fi
  cb_config_scan "$CB_CONFIG_FILE"
  for id in agents_enabled agents_max service_tier features_fast_mode; do
    [[ ${CB_CFG_NEXT_OWN[$id]-0} == 1 ]] || continue
    [[ $(cb_config_live_token "$id") == "${CB_CFG_ACTION[$id]-$(cb_read_field "$tx_dir/ownership/keys/$id/installed_token")}" ]] || cb_die "config key post-commit verification failed: $id"
  done
  cb_write_field "$CB_CONFIG_CURRENT" "$tx"
  cb_write_field "$tx_dir/state" committed
  rm -f -- "$CB_CONFIG_PENDING"
  cb_sync_parent "$CB_CONFIG_PENDING"
  [[ ! -e $old ]] || rm -f -- "$old"
  cb_sync_parent "$CB_CONFIG_FILE"
}

cb_config_plan_restore() {
  local current_dir key_dir id prior_state
  declare -gA CB_CFG_ACTION=() CB_CFG_NEXT_OWN=()
  current_dir=$(cb_config_current_dir_or_empty)
  [[ -n $current_dir ]] || return 1
  cb_config_scan "$CB_CONFIG_FILE"
  for key_dir in "$current_dir"/ownership/keys/*; do
    [[ -d $key_dir && ! -L $key_dir ]] || continue
    id=$(basename -- "$key_dir")
    prior_state=$(cb_read_field "$key_dir/prior_state")
    if [[ $prior_state == present ]]; then CB_CFG_ACTION[$id]=$(cb_read_field "$key_dir/prior_token"); else CB_CFG_ACTION[$id]=__ABSENT__; fi
    CB_CFG_NEXT_OWN[$id]=0
  done
  return 0
}

cb_config_restore() {
  local operation=${1:-restore} core_tx=${2:-}
  if ! cb_config_plan_restore; then return 1; fi
  cb_config_apply_actions "$operation" "$core_tx"
}

cb_config_auto_install_cap() {
  local core_tx=$1 plan_mode=${2:-apply}
  CB_CONFIG_PLAN_CHANGE=0
  cb_config_assert_path
  cb_config_scan "$CB_CONFIG_FILE"
  [[ -z ${CB_CFG_INDEX[agents_enabled]-} || ${CB_CFG_TOKEN[agents_enabled]} != false ]] || return 0
  [[ -z ${CB_CFG_INDEX[features_multi_agent]-} || ${CB_CFG_TOKEN[features_multi_agent]} != false ]] || return 0
  [[ -z ${CB_CFG_INDEX[agents_max]-} && -z ${CB_CFG_INDEX[agents_legacy_max]-} ]] || return 0
  declare -gA CB_CFG_ACTION=([agents_max]=6) CB_CFG_NEXT_OWN=([agents_max]=1)
  cb_config_apply_actions install-cap "$core_tx" "$plan_mode"
}

cb_core_chain_contains() {
  local expected=$1 current=$2 dir
  while [[ -n $current ]]; do
    cb_require_tx_id "$current"
    dir="$CB_STATE_ROOT/transactions/$current"
    [[ -d $dir && ! -L $dir ]] || cb_die "core transaction chain is incomplete: $current"
    [[ $(cb_read_field "$dir/state") == committed ]] || cb_die "core transaction chain contains an uncommitted entry: $current"
    [[ $current != "$expected" ]] || return 0
    current=$(cb_read_field "$dir/parent")
  done
  [[ -z $expected ]]
}

cb_composite_tx_dir() {
  cb_require_tx_id "$1"
  printf '%s/%s' "$CB_COMPOSITE_ROOT" "$1"
}

cb_composite_validate() {
  local id=$1 dir entry name fields='' expected='contract,desired_core,operation,schema,source_core,state' operation state source desired value
  cb_require_tx_id "$id"
  dir=$(cb_composite_tx_dir "$id")
  [[ $(dirname -- "$dir") == "$CB_COMPOSITE_ROOT" && -d $dir && ! -L $dir ]] || cb_die "unsafe or missing composite transaction directory: $dir"
  while IFS= read -r -d '' entry; do
    [[ -f $entry && ! -L $entry ]] || cb_die "invalid composite transaction field: $entry"
    cb_require_scalar_file "$entry" "$id/$(basename -- "$entry")"
    name=$(basename -- "$entry"); if [[ -n $fields ]]; then fields+=','; fi; fields+=$name
  done < <(find -P "$dir" -mindepth 1 -maxdepth 1 -print0 | LC_ALL=C sort -z)
  [[ $fields == "$expected" ]] || cb_die "composite transaction has an invalid field inventory: $id"
  [[ $(cb_read_field "$dir/schema") == 2 && $(cb_read_field "$dir/contract") == codex-baseline-composite-transaction/v2 ]] || cb_die "composite transaction identity mismatch: $id"
  operation=$(cb_read_field "$dir/operation"); case $operation in install|rollback|uninstall) ;; *) cb_die "invalid composite operation: $id" ;; esac
  state=$(cb_read_field "$dir/state"); case $state in planned|committed|rolled-back) ;; *) cb_die "invalid composite state: $id" ;; esac
  source=$(cb_read_field "$dir/source_core"); desired=$(cb_read_field "$dir/desired_core")
  for value in "$source" "$desired"; do
    [[ -z $value ]] || { cb_require_tx_id "$value"; [[ -d $CB_STATE_ROOT/transactions/$value && ! -L $CB_STATE_ROOT/transactions/$value ]] || cb_die "composite core reference is missing: $value"; }
  done
  case $operation in
    install) [[ -z $source && -n $desired ]] || cb_die "invalid install composite endpoints: $id" ;;
    rollback) [[ -n $source && $source != "$desired" ]] || cb_die "invalid rollback composite endpoints: $id" ;;
    uninstall) [[ -n $source && -z $desired ]] || cb_die "invalid uninstall composite endpoints: $id" ;;
  esac
}

cb_composite_begin() {
  local operation=$1 source=$2 desired=$3 id dir
  [[ ! -f $CB_COMPOSITE_PENDING ]] || cb_die 'another composite transaction is pending'
  cb_safe_mkdir_path "$CB_COMPOSITE_ROOT"
  id=$(date -u '+%Y%m%dT%H%M%SZ')-$$-$RANDOM
  dir=$(cb_composite_tx_dir "$id")
  cb_safe_mkdir_path "$dir"
  cb_write_field "$dir/schema" 2
  cb_write_field "$dir/contract" codex-baseline-composite-transaction/v2
  cb_write_field "$dir/operation" "$operation"
  cb_write_field "$dir/source_core" "$source"
  cb_write_field "$dir/desired_core" "$desired"
  cb_write_field "$dir/state" planned
  cb_composite_validate "$id"
  cb_write_field "$CB_COMPOSITE_PENDING" "$id"
  cb_sync_parent "$CB_COMPOSITE_PENDING"
}

cb_composite_apply_config() {
  local operation=$1 source=$2 desired=$3 current_dir='' config_core=''
  case $operation in
    install)
      cb_config_auto_install_cap "$desired"
      ;;
    rollback)
      current_dir=$(cb_config_current_dir_or_empty)
      if [[ -n $current_dir ]]; then
        config_core=$(cb_read_field "$current_dir/core_tx")
        if [[ $config_core == "$source" ]]; then cb_config_restore rollback "$source" || true; fi
      fi
      ;;
    uninstall)
      if cb_config_current_dir >/dev/null; then cb_config_restore uninstall "$source" || true; fi
      ;;
  esac
}

cb_composite_finalize() {
  local id=$1 terminal=$2 dir
  cb_composite_validate "$id"
  dir=$(cb_composite_tx_dir "$id")
  cb_write_field "$dir/state" "$terminal"
  rm -f -- "$CB_COMPOSITE_PENDING"
  cb_sync_parent "$CB_COMPOSITE_PENDING"
}

cb_composite_recover_pending() {
  local id dir operation source desired current
  id=$(cb_read_tx_pointer "$CB_COMPOSITE_PENDING")
  [[ -n $id ]] || return 0
  cb_composite_validate "$id"
  dir=$(cb_composite_tx_dir "$id")
  [[ $(cb_read_field "$dir/state") == planned ]] || cb_die "pending composite transaction is not planned: $id"
  operation=$(cb_read_field "$dir/operation")
  source=$(cb_read_field "$dir/source_core")
  desired=$(cb_read_field "$dir/desired_core")
  current=$(cb_current_tx)
  if [[ $operation == uninstall && -n $current && $current != "$desired" ]]; then
    cb_core_chain_contains "$current" "$source" || cb_die 'uninstall composite found an unrelated core state'
    while [[ -n $(cb_current_tx) ]]; do cb_rollback_once uninstall; done
    current=$(cb_current_tx)
  fi
  if [[ $current == "$desired" ]]; then
    if [[ -n $desired ]]; then cb_validate_tx "$desired" committed "$CB_STATE_ROOT"; fi
    cb_composite_apply_config "$operation" "$source" "$desired"
    cb_composite_finalize "$id" committed
  elif [[ $current == "$source" ]]; then
    cb_composite_finalize "$id" rolled-back
  else
    cb_die 'composite recovery found an unverifiable core state'
  fi
}

cb_config_owned_keys_json() {
  local current_dir key_dir separator=''
  current_dir=$(cb_config_current_dir_or_empty)
  printf '['
  if [[ -n $current_dir ]]; then
    for key_dir in "$current_dir"/ownership/keys/*; do
      [[ -d $key_dir ]] || continue
      printf '%s"%s"' "$separator" "$(cb_json_escape "$(cb_read_field "$key_dir/path")")"
      separator=,
    done
  fi
  printf ']'
}

cb_optimize_report() {
  local mode=$1 status=$2 applied=$3 speed=$4 bytes=${5:-0} drift=${6:-false} enabled=null feature_enabled=null cap=null legacy=null override=false runtime_capability=unverified
  cb_config_scan "$CB_CONFIG_FILE"
  if [[ -n ${CB_CFG_TOKEN[agents_enabled]-} ]]; then enabled=${CB_CFG_TOKEN[agents_enabled]}; fi
  if [[ -n ${CB_CFG_TOKEN[features_multi_agent]-} ]]; then feature_enabled=${CB_CFG_TOKEN[features_multi_agent]}; fi
  if [[ -n ${CB_CFG_TOKEN[agents_max]-} ]]; then cap=${CB_CFG_TOKEN[agents_max]}; override=true; fi
  if [[ -n ${CB_CFG_TOKEN[agents_legacy_max]-} ]]; then legacy=${CB_CFG_TOKEN[agents_legacy_max]}; override=true; fi
  [[ $enabled != false ]] || override=true
  [[ $feature_enabled != false ]] || override=true
  if command -v codex >/dev/null 2>&1 && codex --strict-config --version >/dev/null 2>&1; then runtime_capability=available; fi
  if [[ $CB_JSON -eq 1 ]]; then
    printf '{"schema":1,"contract":"codex-baseline-optimize/v1","mode":"%s","status":"%s","apply":%s,"config":"%s","agents":{"enabled":%s,"cap":%s,"legacy_cap":%s,"effective_override":%s},"speed":"%s","managed_keys":' \
      "$mode" "$status" "$applied" "$(cb_json_escape "$CB_CONFIG_FILE")" "$enabled" "$cap" "$legacy" "$override" "$speed"
    cb_config_owned_keys_json
    printf ',"drift":%s,"bytes_changed":%d,"capabilities":{"agents":"%s","fast":"%s","ultrafast":"unavailable"},"limitations":["runtime depth/model/concurrency telemetry may remain unverified","cooperative CAS is not a hostile-writer or power-loss guarantee"]}\n' "$drift" "$bytes" "$runtime_capability" "$runtime_capability"
  else
    printf 'Optimizer: %s (%s)\nConfig: %s\nAgents: enabled=%s cap=%s legacy-cap=%s\nSpeed: %s\nManaged keys: ' "$status" "$mode" "$CB_CONFIG_FILE" "$enabled" "$cap" "$legacy" "$speed"
    cb_config_owned_keys_json
    printf '\nUltrafast: unavailable; bytes changed: %d; drift: %s\n' "$bytes" "$drift"
  fi
}

cb_optimize_prepare_plan() {
  local current_dir='' key_dir='' id prior_state
  if [[ $CB_OPTIMIZE_MODE == restore ]]; then
    CB_OPTIMIZE_PLAN_MODE=restore
    cb_config_plan_restore
    return
  fi
  CB_OPTIMIZE_PLAN_MODE=optimize
  cb_config_scan "$CB_CONFIG_FILE"
  declare -gA CB_CFG_ACTION=([agents_enabled]=true [agents_max]=6) CB_CFG_NEXT_OWN=([agents_enabled]=1 [agents_max]=1)
  if [[ $CB_OPTIMIZE_SPEED == fast ]]; then
    current_dir=$(cb_config_current_dir_or_empty)
    [[ -z $current_dir ]] || key_dir="$current_dir/ownership/keys/service_tier"
    if [[ -n ${CB_CFG_INDEX[service_tier]-} && ! -d $key_dir && ${CB_CFG_TOKEN[service_tier]} != '"fast"' ]]; then
      cb_die 'speed=fast refuses an unowned conflicting key: service_tier'
    fi
    CB_CFG_ACTION[service_tier]='"fast"'; CB_CFG_ACTION[features_fast_mode]=true
    CB_CFG_NEXT_OWN[service_tier]=1; CB_CFG_NEXT_OWN[features_fast_mode]=1
  elif [[ $CB_OPTIMIZE_SPEED == standard ]]; then
    current_dir=$(cb_config_current_dir_or_empty)
    for id in service_tier features_fast_mode; do
      key_dir=''
      [[ -z $current_dir ]] || key_dir="$current_dir/ownership/keys/$id"
      if [[ -n $key_dir && -d $key_dir ]]; then
        prior_state=$(cb_read_field "$key_dir/prior_state")
        if [[ $prior_state == present ]]; then CB_CFG_ACTION[$id]=$(cb_read_field "$key_dir/prior_token"); else CB_CFG_ACTION[$id]=__ABSENT__; fi
        CB_CFG_NEXT_OWN[$id]=0
      elif [[ -n ${CB_CFG_INDEX[$id]-} ]]; then
        if [[ $id == service_tier && ${CB_CFG_TOKEN[$id]} == '"fast"' ]] || \
           [[ $id == features_fast_mode && ${CB_CFG_TOKEN[$id]} == true ]]; then
          cb_die "speed=standard refuses an unowned conflicting key: $(cb_config_key_path "$id")"
        fi
      fi
    done
  fi
}

cb_optimize() {
  local before=absent after=absent status=available mode=check current_dir='' key_dir id installed live drift=false applied=false bytes_changed=0
  CB_OPTIMIZE_MODE=check; CB_OPTIMIZE_CHECK_SET=0; CB_OPTIMIZE_APPLY=0; CB_OPTIMIZE_SPEED=keep; CB_DRY_RUN=0; CB_JSON=0
  while [[ $# -gt 0 ]]; do
    case $1 in
      --check) CB_OPTIMIZE_MODE=check; CB_OPTIMIZE_CHECK_SET=1 ;;
      --restore) CB_OPTIMIZE_MODE=restore ;;
      --speed) shift; [[ $# -gt 0 ]] || cb_die '--speed requires keep, standard, fast, or ultrafast'; CB_OPTIMIZE_SPEED=$1 ;;
      --speed=*) CB_OPTIMIZE_SPEED=${1#*=} ;;
      --dry-run) CB_DRY_RUN=1 ;;
      --apply) CB_OPTIMIZE_APPLY=1 ;;
      --json) CB_JSON=1 ;;
      *) cb_die "unknown optimize option: $1" ;;
    esac
    shift
  done
  case $CB_OPTIMIZE_SPEED in keep|standard|fast|ultrafast) ;; *) cb_die 'invalid --speed value' ;; esac
  [[ $CB_DRY_RUN -eq 0 || $CB_OPTIMIZE_APPLY -eq 0 ]] || cb_die '--dry-run and --apply are mutually exclusive'
  if [[ $CB_OPTIMIZE_CHECK_SET -eq 1 && ( $CB_OPTIMIZE_MODE != check || $CB_OPTIMIZE_SPEED != keep || $CB_DRY_RUN -eq 1 || $CB_OPTIMIZE_APPLY -eq 1 ) ]]; then
    cb_die '--check cannot be combined with restore, speed, dry-run, or apply'
  fi
  if [[ $CB_OPTIMIZE_MODE == restore && $CB_OPTIMIZE_SPEED != keep ]]; then cb_die '--restore cannot be combined with --speed'; fi
  if [[ $CB_OPTIMIZE_SPEED == ultrafast ]]; then
    cb_init_paths; cb_optimize_report optimize unavailable false ultrafast 0 false
    return 3
  fi
  cb_init_paths
  cb_config_assert_path
  if [[ $CB_OPTIMIZE_MODE == check && $CB_OPTIMIZE_SPEED == keep && $CB_OPTIMIZE_APPLY -eq 0 && $CB_DRY_RUN -eq 0 ]]; then
    cb_config_scan "$CB_CONFIG_FILE"
    current_dir=$(cb_config_current_dir_or_empty)
    if [[ -n $current_dir ]]; then
      for key_dir in "$current_dir"/ownership/keys/*; do
        [[ -d $key_dir && ! -L $key_dir ]] || continue
        id=$(basename -- "$key_dir")
        installed=$(cb_read_field "$key_dir/installed_token")
        live=$(cb_config_live_token "$id")
        if [[ $live != "$installed" ]]; then drift=true; fi
      done
    fi
    [[ $drift == false ]] || status=conflict
    cb_optimize_report check "$status" false unmanaged 0 "$drift"
    [[ $drift == false ]] || return 4
    return 0
  fi
  if [[ $CB_OPTIMIZE_APPLY -eq 0 ]]; then CB_DRY_RUN=1; fi
  CB_VERSION=$(<"$CB_SOURCE_ROOT/VERSION")
  if [[ $CB_OPTIMIZE_APPLY -eq 1 && ! -e $CB_PENDING && ! -L $CB_PENDING && \
        ! -e $CB_CONFIG_PENDING && ! -L $CB_CONFIG_PENDING && ! -e $CB_COMPOSITE_PENDING && ! -L $CB_COMPOSITE_PENDING ]]; then
    if ! cb_optimize_prepare_plan; then cb_optimize_report restore not-managed false keep 0 false; return 0; fi
    cb_config_apply_actions "$CB_OPTIMIZE_PLAN_MODE" '' preflight
  fi
  if [[ $CB_OPTIMIZE_APPLY -eq 1 ]]; then
    cb_init_mutation_roots
    cb_acquire_lock
    cb_recover_pending
    cb_config_recover_pending
    cb_composite_recover_pending
  fi
  [[ ! -e $CB_CONFIG_FILE ]] || before=$(cb_sha256_file "$CB_CONFIG_FILE")
  if ! cb_optimize_prepare_plan; then cb_optimize_report restore not-managed false keep 0 false; return 0; fi
  mode=$CB_OPTIMIZE_PLAN_MODE
  cb_config_apply_actions "$mode" ''
  [[ ! -e $CB_CONFIG_FILE ]] || after=$(cb_sha256_file "$CB_CONFIG_FILE")
  if [[ $CB_OPTIMIZE_APPLY -eq 1 ]]; then
    applied=true
    if [[ $mode == restore ]]; then status=restored; else status=applied; fi
  else
    status=planned
  fi
  if [[ $before != "$after" && $after != absent ]]; then bytes_changed=$(stat -c '%s' -- "$CB_CONFIG_FILE"); fi
  cb_optimize_report "$mode" "$status" "$applied" "$CB_OPTIMIZE_SPEED" "$bytes_changed" false
}

cb_uninstall() {
  local current source current_dir obj
  CB_VERSION=$(<"$CB_SOURCE_ROOT/VERSION")
  cb_init_paths
  cb_begin_operation
  source=$(cb_current_tx)
  if [[ $CB_DRY_RUN -eq 1 ]]; then
    if cb_config_current_dir >/dev/null; then cb_config_restore uninstall "$source" || true; fi
    current=$source
    if [[ -z $current ]]; then
      printf 'codex-baseline is not installed; no changes\n'
      return 0
    fi
    while [[ -n $current ]]; do
      current_dir=$(cb_live_tx_dir "$current")
      [[ -d $current_dir ]] || cb_die "transaction chain is incomplete: $current"
      printf 'uninstall: would unwind transaction %s\n' "$current"
      for obj in "$current_dir"/objects/*; do
        [[ -d $obj && $(cb_read_field "$obj/status") == committed ]] || continue
        printf 'uninstall: %s\n' "$(cb_read_field "$obj/target")"
      done
      current=$(cb_read_field "$current_dir/parent")
    done
    printf 'dry-run: no files changed\n'
    return 0
  fi
  if [[ -z $source ]]; then
    if cb_config_current_dir >/dev/null; then cb_config_restore uninstall '' || true; fi
    printf 'codex-baseline is not installed; baseline-owned config state was restored where present\n'
    return 0
  fi
  cb_composite_begin uninstall "$source" ''
  while [[ -n $(cb_current_tx) ]]; do
    cb_rollback_once uninstall
  done
  cb_composite_recover_pending
  printf 'codex-baseline is uninstalled; transaction history retained in %s\n' "$CB_STATE_ROOT"
}

cb_doctor() {
  local current state failures=0 warnings=0 codex_version='not-found' codex_number='' agents_file markers
  local current_dir obj kind target installed live managed_total=0 managed_ok=0 skill_count=0
  local manifest manifest_root manifest_error_file manifest_error='' minimum_codex='' tested_codex='' research_checked='' research_review_by='' research_state=unknown platform=linux capabilities=unknown
  local baseline_version='' provenance_scope='local-source' provenance_version='' provenance_trust='' provenance_hash=''
  local codex_verification=not-found marker_begin marker_end transaction_json baseline_version_json provenance_version_json provenance_trust_json provenance_hash_json research_checked_json research_review_json
  local dependency dependency_state=verified config_state=unverified-codex-not-found deprecated_state=unverified-codex-not-found optimizer_capability=unverified
  local config_owned=0 config_drift=false config_dir='' key_dir
  local -a warning_messages=() failure_messages=() required_dependencies=(
    awk bash basename chmod cp cut date dirname find getfacl getfattr grep head iconv ln mkdir mktemp mv
    od realpath sed sort stat tail tr wc
  ) missing_dependencies=()
  cb_init_paths
  for dependency in "${required_dependencies[@]}"; do
    if ! command -v "$dependency" >/dev/null 2>&1; then missing_dependencies+=("$dependency"); fi
  done
  if ! command -v sha256sum >/dev/null 2>&1 && ! command -v shasum >/dev/null 2>&1; then
    missing_dependencies+=('sha256sum-or-shasum')
  fi
  if [[ ${#missing_dependencies[@]} -gt 0 ]]; then
    dependency_state=missing
    failures=$((failures + 1))
    failure_messages+=("Required runtime commands are missing: ${missing_dependencies[*]}")
  fi
  manifest_root=$CB_SOURCE_ROOT
  if [[ -f $CB_RUNTIME/baseline/manifest.json ]]; then
    manifest_root=$CB_RUNTIME
    provenance_scope='installed-runtime'
  fi
  manifest="$manifest_root/baseline/manifest.json"
  if [[ $dependency_state == verified ]]; then
    manifest_error_file=$(mktemp "${TMPDIR:-/tmp}/codex-baseline-doctor-manifest.XXXXXX")
    if provenance_version=$(cb_verify_source_manifest "$manifest_root" 2>"$manifest_error_file"); then
      provenance_trust=$(sed -n 's/^  "source_trust": "\([A-Za-z0-9._-]*\)",$/\1/p' "$manifest")
      provenance_hash=$(sed -n 's/^  "payload_hash": "\([0-9a-f]*\)",$/\1/p' "$manifest")
      minimum_codex=$(sed -n 's/^  "minimum_codex": "\([0-9.]*\)",$/\1/p' "$manifest")
      tested_codex=$(sed -n 's/^  "tested_codex": "\([0-9.]*\)",$/\1/p' "$manifest")
      if [[ ! $minimum_codex =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        failures=$((failures + 1))
        failure_messages+=('Source manifest minimum_codex is malformed.')
        minimum_codex=''
      fi
      if [[ ! $tested_codex =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        failures=$((failures + 1))
        failure_messages+=('Source manifest tested_codex is malformed.')
        tested_codex=''
      fi
    else
      IFS= read -r manifest_error <"$manifest_error_file" || true
      manifest_error=${manifest_error#codex-baseline: }
      failures=$((failures + 1))
      failure_messages+=("Source/research manifest check failed: ${manifest_error:-unknown manifest verification error}")
    fi
    rm -f -- "$manifest_error_file"
  fi
  if command -v codex >/dev/null 2>&1; then
    codex_verification=executed
    if codex_version=$(codex --version 2>/dev/null); then
      if [[ $codex_version =~ ([0-9]+\.[0-9]+\.[0-9]+) ]]; then
        codex_number=${BASH_REMATCH[1]}
      else
        failures=$((failures + 1))
        failure_messages+=('Codex version output does not contain a semantic version.')
      fi
    else
      codex_version=error
      failures=$((failures + 1))
      failure_messages+=('Codex version probe failed.')
    fi
    if codex --strict-config --version >/dev/null 2>&1; then
      config_state=accepted-by-strict-config
      deprecated_state=none-reported-by-strict-config
    else
      config_state=rejected-by-strict-config
      deprecated_state=unverified-config-rejected
      failures=$((failures + 1))
      failure_messages+=('Codex strict-config version probe failed.')
    fi
    if codex features list 2>/dev/null | awk '$1 == "goals" || $1 == "multi_agent" || $1 == "skill_search" { if ($2 == "stable" && $3 == "true") seen[$1] = 1 } END { exit seen["goals"] && seen["multi_agent"] && seen["skill_search"] ? 0 : 1 }'; then
      capabilities=verified
      [[ $config_state == accepted-by-strict-config ]] && optimizer_capability=available
    else
      warnings=$((warnings + 1))
      warning_messages+=('Native Codex capability probe is degraded.')
      capabilities=degraded
    fi
    if [[ -n $minimum_codex && -n $codex_number ]] && [[ $(printf '%s\n%s\n' "$minimum_codex" "$codex_number" | sort -V | head -n 1) != "$minimum_codex" ]]; then
      failures=$((failures + 1))
      failure_messages+=("Codex is older than the supported minimum version $minimum_codex.")
    fi
    if [[ -n $tested_codex && -n $codex_number && $codex_number != "$tested_codex" ]] &&
      [[ $(printf '%s\n%s\n' "$tested_codex" "$codex_number" | sort -V | head -n 1) == "$tested_codex" ]]; then
      capabilities=unverified-future-version
      warnings=$((warnings + 1))
      warning_messages+=("Codex $codex_number is newer than the tested version $tested_codex; volatile capabilities remain unverified.")
    fi
  else
    failures=$((failures + 1))
    failure_messages+=('Codex executable was not found.')
  fi
  if grep -qi microsoft /proc/sys/kernel/osrelease 2>/dev/null; then platform=wsl2; fi
  current=$(cb_current_tx)
  state=not-installed
  if [[ -n $current && -d $(cb_live_tx_dir "$current") ]]; then
    current_dir=$(cb_live_tx_dir "$current")
    state=$(cb_read_field "$current_dir/state")
    baseline_version=$(cb_read_field "$current_dir/version")
    [[ $state == committed ]] || { failures=$((failures + 1)); failure_messages+=('Current transaction is not committed.'); }
    for obj in "$current_dir"/objects/*; do
      [[ -d $obj ]] || continue
      case $(cb_read_field "$obj/status") in committed|unchanged) ;; *) continue ;; esac
      managed_total=$((managed_total + 1))
      kind=$(cb_read_field "$obj/kind")
      target=$(cb_read_field "$obj/target")
      installed=$(cb_read_field "$obj/installed_hash")
      if live=$(cb_live_hash "$kind" "$target" 2>/dev/null); then
        if [[ $live == "$installed" ]]; then managed_ok=$((managed_ok + 1)); else failures=$((failures + 1)); failure_messages+=("Managed content drifted: $target"); fi
      else
        failures=$((failures + 1))
        failure_messages+=("Managed object could not be inspected: $target")
      fi
    done
  fi
  if [[ -f $CB_PENDING ]]; then
    failures=$((failures + 1))
    failure_messages+=('An incomplete transaction is pending recovery.')
  fi
  if [[ -f $CB_CONFIG_PENDING ]]; then
    failures=$((failures + 1))
    failure_messages+=('An incomplete config transaction is pending recovery.')
  fi
  if [[ -f $CB_COMPOSITE_PENDING ]]; then
    failures=$((failures + 1))
    failure_messages+=('An incomplete composite transaction is pending recovery.')
  fi
  config_dir=''
  if [[ -e $CB_CONFIG_CURRENT || -L $CB_CONFIG_CURRENT ]]; then
    if ! config_dir=$(cb_config_current_dir 2>/dev/null); then
      failures=$((failures + 1))
      failure_messages+=('Managed config transaction state is invalid.')
      config_dir=''
    fi
  fi
  if [[ -n $config_dir ]]; then
    for key_dir in "$config_dir"/ownership/keys/*; do [[ ! -d $key_dir ]] || config_owned=$((config_owned + 1)); done
    if ! (cb_config_assert_path; cb_config_assert_owned_clean) 2>/dev/null; then
      config_drift=true
      failures=$((failures + 1))
      failure_messages+=('Managed config projection drifted or became unsafe.')
    fi
  fi
  if [[ -d $CB_LOCK ]]; then
    warnings=$((warnings + 1))
    warning_messages+=('An operation lock exists.')
  fi
  agents_file="$CB_CODEX_HOME/AGENTS.md"
  if [[ -s $CB_CODEX_HOME/AGENTS.override.md ]]; then
    agents_file="$CB_CODEX_HOME/AGENTS.override.md"
  fi
  markers=$(cb_marker_counts "$agents_file")
  [[ $markers == '1 1' || $state == not-installed ]] || { failures=$((failures + 1)); failure_messages+=('Global guidance marker counts are invalid.'); }
  for target in \
    "$CB_AGENTS_HOME/skills/codex-baseline-repo-onboarding/SKILL.md" \
    "$CB_AGENTS_HOME/skills/codex-baseline-deep-work/SKILL.md" \
    "$CB_AGENTS_HOME/skills/codex-baseline-conformance-review/SKILL.md" \
    "$CB_AGENTS_HOME/skills/codex-baseline-retrospective/SKILL.md"; do
    [[ -f $target && ! -L $target ]] && skill_count=$((skill_count + 1))
  done
  [[ $state == not-installed || $skill_count -eq 4 ]] || { failures=$((failures + 1)); failure_messages+=('One or more baseline skills are missing.'); }
  if [[ -f $manifest ]]; then
    research_checked=$(sed -n 's/^  "research_checked": "\([0-9-]*\)",$/\1/p' "$manifest")
    research_review_by=$(sed -n 's/^  "research_review_by": "\([0-9-]*\)",$/\1/p' "$manifest")
    if [[ -n $research_review_by ]] && date -d "$research_review_by" >/dev/null 2>&1; then
      if [[ $(date -u +%s) -le $(date -u -d "$research_review_by 23:59:59" +%s) ]]; then
        research_state=current
      else
        research_state=stale
        warnings=$((warnings + 1))
        warning_messages+=('Research evidence is past its review-by date.')
      fi
    else
      research_state=invalid
      warnings=$((warnings + 1))
      warning_messages+=('Research freshness metadata is invalid.')
    fi
  fi
  if [[ $CB_JSON -eq 1 ]]; then
    marker_begin=${markers%% *}; marker_end=${markers##* }
    transaction_json=null; [[ -z $current ]] || transaction_json="\"$(cb_json_escape "$current")\""
    baseline_version_json=null; [[ -z $baseline_version ]] || baseline_version_json="\"$(cb_json_escape "$baseline_version")\""
    provenance_version_json=null; [[ -z $provenance_version ]] || provenance_version_json="\"$(cb_json_escape "$provenance_version")\""
    provenance_trust_json=null; [[ -z $provenance_trust ]] || provenance_trust_json="\"$(cb_json_escape "$provenance_trust")\""
    provenance_hash_json=null; [[ -z $provenance_hash ]] || provenance_hash_json="\"$(cb_json_escape "$provenance_hash")\""
    research_checked_json=null; [[ -z $research_checked ]] || research_checked_json="\"$(cb_json_escape "$research_checked")\""
    research_review_json=null; [[ -z $research_review_by ]] || research_review_json="\"$(cb_json_escape "$research_review_by")\""
    printf '{"schema":2,"contract":"codex-baseline-doctor/v2","platform":"%s","powershell":null,"codex":"%s","codex_verification":"%s","state":"%s","transaction":%s,"baseline_version":%s,"source_provenance":{"scope":"%s","version":%s,"trust":%s,"payload_sha256":%s},"global_guidance":"%s","marker_counts":{"begin":%d,"end":%d},"managed_objects":{"ok":%d,"total":%d},"skills":{"ok":%d,"total":4},"native_capabilities":"%s","runtime_dependencies":{"status":"%s","required":' \
      "$platform" "$(cb_json_escape "$codex_version")" "$codex_verification" "$(cb_json_escape "$state")" "$transaction_json" "$baseline_version_json" "$(cb_json_escape "$provenance_scope")" "$provenance_version_json" "$provenance_trust_json" "$provenance_hash_json" \
      "$(cb_json_escape "$agents_file")" "$marker_begin" "$marker_end" "$managed_ok" "$managed_total" "$skill_count" "$capabilities" "$dependency_state"
    cb_json_string_array "${required_dependencies[@]}"
    printf ',"missing":'
    cb_json_string_array "${missing_dependencies[@]}"
    printf '},"active_config":{"status":"%s","verification":"codex --strict-config --version"},"hook_state":{"baseline_owned":0,"user_owned":"preserved-not-enumerated"},"deprecated_settings":{"status":"%s"},"paths":{"home":"%s","codex_home":"%s","agents_home":"%s","state_root":"%s"},"owned_config_keys":%d,"owned_hooks":0,"optimizer":{"contract":"codex-baseline-config-operations/v2","managed_keys":' \
      "$config_state" "$deprecated_state" "$(cb_json_escape "$CB_HOME")" "$(cb_json_escape "$CB_CODEX_HOME")" "$(cb_json_escape "$CB_AGENTS_HOME")" "$(cb_json_escape "$CB_STATE_ROOT")" \
      "$config_owned"
    cb_config_owned_keys_json
    printf ',"drift":%s,"agents":"%s","fast":"%s","ultrafast":"unavailable"},"research":{"checked":%s,"review_by":%s,"state":"%s"},"warnings":' \
      "$config_drift" "$optimizer_capability" "$optimizer_capability" "$research_checked_json" "$research_review_json" "$research_state"
    cb_json_string_array "${warning_messages[@]}"
    printf ',"failures":'
    cb_json_string_array "${failure_messages[@]}"
    printf ',"warning_count":%d,"failure_count":%d}\n' "$warnings" "$failures"
  else
    printf 'Codex: %s\nPlatform: %s\nInstallation: %s\nTransaction: %s\nBaseline version: %s\nSource provenance: %s version=%s trust=%s payload=%s\nGlobal guidance: %s (markers %s)\nManaged objects: %d/%d\nSkills: %d/4\nNative capabilities: %s\nRuntime dependencies: %s (%d required, %d missing)\nActive config: %s; deprecated settings: %s\nPaths: HOME=%s CODEX_HOME=%s AGENTS_HOME=%s state=%s\nOwned config keys/hooks: %d/0 (drift=%s; agents=%s; fast=%s; ultrafast=unavailable)\nResearch: %s (checked %s, review by %s)\nWarnings: %d\nFailures: %d\n' \
      "$codex_version" "$platform" "$state" "${current:-none}" "${baseline_version:-none}" "$provenance_scope" "${provenance_version:-unknown}" "${provenance_trust:-unknown}" "${provenance_hash:-unknown}" "$agents_file" "$markers" "$managed_ok" "$managed_total" "$skill_count" "$capabilities" \
      "$dependency_state" "${#required_dependencies[@]}" "${#missing_dependencies[@]}" "$config_state" "$deprecated_state" "$CB_HOME" "$CB_CODEX_HOME" "$CB_AGENTS_HOME" "$CB_STATE_ROOT" \
      "$config_owned" "$config_drift" "$optimizer_capability" "$optimizer_capability" "$research_state" "${research_checked:-unknown}" "${research_review_by:-unknown}" "$warnings" "$failures"
  fi
  [[ $failures -eq 0 ]]
}

cb_prepare_update_archive() {
  local archive_input=$1 expected_version=${2:-} acquisition=$3 archive extract_root archive_size version update_temp
  cb_update_temp_root
  update_temp=$CB_UPDATE_TEMP_ROOT
  archive="$update_temp/archive.tar.gz"
  extract_root="$update_temp/extract"
  mkdir -- "$extract_root"
  if [[ $acquisition == unsigned-github-release ]]; then
    cb_fetch_update_url "$archive_input" "$archive" "$CB_UPDATE_MAX_ARCHIVE_BYTES"
  else
    cb_copy_update_input "$archive_input" "$archive" "$CB_UPDATE_MAX_ARCHIVE_BYTES"
  fi
  archive_size=$(stat -c '%s' -- "$archive")
  if [[ $acquisition == unsigned-github-release || $acquisition == test-remote-copy ]]; then
    [[ $archive_size == "$CB_UPDATE_TAR_BYTES" ]] || cb_die 'update archive byte length mismatch'
    [[ $(cb_sha256_file "$archive") == "$CB_UPDATE_TAR_SHA256" ]] || cb_die 'update archive SHA-256 mismatch'
  fi
  cb_validate_and_extract_tar "$archive" "$expected_version" "$extract_root"
  version=$(cb_verify_update_source_inventory "$CB_UPDATE_SOURCE_ROOT")
  [[ -z $expected_version || $version == "$expected_version" ]] || cb_die 'update descriptor and source manifest version disagree'
  CB_UPDATE_ARCHIVE_VERSION=$version
}

cb_update_remote_flow() {
  local current_version current_release_status descriptor archive_url comparison update_temp
  cb_init_paths
  current_version=$(<"$CB_SOURCE_ROOT/VERSION")
  cb_semver_valid "$current_version" || cb_die 'installed updater version is not stable MAJOR.MINOR.PATCH'
  current_release_status=$(sed -n 's/^  "status": "\([A-Za-z0-9.]*\)"$/\1/p' "$CB_SOURCE_ROOT/baseline/release-status.json")
  [[ $current_release_status == stable || $current_release_status =~ ^rc\.[1-9][0-9]*$ ]] || cb_die 'installed release status is missing or unsupported'
  cb_update_temp_root
  update_temp=$CB_UPDATE_TEMP_ROOT
  descriptor="$update_temp/descriptor"
  if [[ ${CODEX_BASELINE_TESTING:-0} == 1 && -n ${CODEX_BASELINE_TEST_UPDATE_METADATA_PATH:-} ]]; then
    cb_copy_update_input "$CODEX_BASELINE_TEST_UPDATE_METADATA_PATH" "$descriptor" 16384
  else
    cb_fetch_update_url "$CB_UPDATE_METADATA_URL" "$descriptor" 16384
  fi
  cb_read_update_descriptor "$descriptor"
  comparison=$(cb_semver_compare "$CB_UPDATE_VERSION" "$current_version")
  if [[ $comparison -lt 0 ]]; then cb_die "latest release $CB_UPDATE_VERSION is older than installed $current_version"; fi
  if [[ $CB_UPDATE_CHECK -eq 1 ]]; then
    if [[ $comparison -eq 0 && $current_release_status == stable ]]; then
      printf 'codex-baseline %s is already current (latest stable %s)\n' "$current_version" "$CB_UPDATE_VERSION"
    else
      if [[ $comparison -eq 0 ]]; then
        printf 'codex-baseline stable promotion available: %s-%s -> %s\n' "$current_version" "$current_release_status" "$CB_UPDATE_VERSION"
      else
        printf 'codex-baseline update available: %s -> %s\n' "$current_version" "$CB_UPDATE_VERSION"
      fi
    fi
    printf 'source-acquisition: unsigned-github-release\nsource-authentication: not-publisher-authenticated\n'
    return 0
  fi
  archive_url="https://github.com/ShigeoAMV/codex-baseline/releases/download/$CB_UPDATE_TAG/$CB_UPDATE_TAR_NAME"
  if [[ ${CODEX_BASELINE_TESTING:-0} == 1 && -n ${CODEX_BASELINE_TEST_UPDATE_ARCHIVE_PATH:-} ]]; then
    cb_prepare_update_archive "$CODEX_BASELINE_TEST_UPDATE_ARCHIVE_PATH" "$CB_UPDATE_VERSION" test-remote-copy
  else
    cb_prepare_update_archive "$archive_url" "$CB_UPDATE_VERSION" unsigned-github-release
  fi
  cb_install_like update "$CB_UPDATE_SOURCE_ROOT" unsigned-github-release
}

cb_update_offline_flow() {
  local archive_path=$1
  cb_prepare_update_archive "$archive_path" '' offline-archive
  cb_install_like update "$CB_UPDATE_SOURCE_ROOT" offline-archive
}

cb_parse_update_flags() {
  local modes
  while [[ $# -gt 0 ]]; do
    case $1 in
      --check) CB_UPDATE_CHECK=1 ;;
      --remote) CB_UPDATE_REMOTE=1 ;;
      --local) CB_UPDATE_LOCAL=1 ;;
      --offline)
        shift
        [[ $# -gt 0 && -n $1 ]] || cb_die '--offline requires a tar.gz archive path'
        CB_UPDATE_OFFLINE=$1
        ;;
      --dry-run) CB_DRY_RUN=1 ;;
      --acknowledge-unverified-source) CB_ACKNOWLEDGE_UNVERIFIED_SOURCE=1 ;;
      *) cb_die "unknown option: $1" ;;
    esac
    shift
  done
  modes=$((CB_UPDATE_CHECK + CB_UPDATE_REMOTE + CB_UPDATE_LOCAL))
  [[ -z $CB_UPDATE_OFFLINE ]] || modes=$((modes + 1))
  (( modes <= 1 )) || cb_die 'choose only one of --check, --remote, --local, or --offline'
  [[ $CB_UPDATE_CHECK -eq 0 || $CB_DRY_RUN -eq 0 ]] || cb_die '--check and --dry-run are separate preview modes'
}

cb_update() {
  cb_parse_update_flags "$@"
  cb_init_paths
  if [[ -n $CB_UPDATE_OFFLINE ]]; then
    cb_update_offline_flow "$CB_UPDATE_OFFLINE"
  elif [[ $CB_UPDATE_LOCAL -eq 1 ]]; then
    cb_install_like update "$CB_SOURCE_ROOT" local-checkout
  elif [[ $CB_UPDATE_CHECK -eq 1 || $CB_UPDATE_REMOTE -eq 1 || $CB_SOURCE_ROOT == "$CB_RUNTIME" ]]; then
    cb_update_remote_flow
  else
    cb_install_like update "$CB_SOURCE_ROOT" local-checkout
  fi
}

cb_parse_common_flags() {
  while [[ $# -gt 0 ]]; do
    case $1 in
      --dry-run) CB_DRY_RUN=1 ;;
      --json) CB_JSON=1 ;;
      --acknowledge-unverified-source) CB_ACKNOWLEDGE_UNVERIFIED_SOURCE=1 ;;
      *) cb_die "unknown option: $1" ;;
    esac
    shift
  done
}

main() {
  local command=${1:-help}
  [[ $# -eq 0 ]] || shift
  trap cb_on_exit EXIT
  case $command in
    install)
      cb_parse_common_flags "$@"
      cb_install_like "$command"
      ;;
    update)
      cb_update "$@"
      ;;
    doctor)
      cb_parse_common_flags "$@"
      cb_doctor
      ;;
    optimize)
      cb_optimize "$@"
      ;;
    rollback)
      cb_parse_common_flags "$@"
      cb_rollback
      ;;
    uninstall)
      cb_parse_common_flags "$@"
      cb_uninstall
      ;;
    onboard)
      exec "$CB_SCRIPT_DIR/onboard.sh" "$@"
      ;;
    benchmark)
      CODEX_BASELINE_BENCHMARK_API_KEY=$CB_DISPATCH_BENCHMARK_KEY
      export CODEX_BASELINE_BENCHMARK_API_KEY
      exec "$CB_SCRIPT_DIR/benchmark.sh" "$@"
      ;;
    help|-h|--help) cb_usage ;;
    *) cb_usage >&2; cb_die "unknown command: $command" ;;
  esac
}

main "$@"
