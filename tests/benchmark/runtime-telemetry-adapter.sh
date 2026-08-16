#!/bin/bash
set -Eeuo pipefail
IFS=$'\n\t'

input=${1:?input descriptor required}
descriptor_hash=$(sha256sum -- "$input")
descriptor_hash=${descriptor_hash%% *}
event=$(jq -cs '[.[] | select(.type == "runtime.telemetry")][0]' /events.jsonl)
test_case=$(jq -r '.test_case // "valid"' <<<"$event")
usage=$(jq -cs '
  [.[] | select(.type == "turn.completed") | .usage] as $usage |
  if ($usage | length) == 1 and (($usage[0].usage_scope // $usage[0].scope // null) == "aggregate") and
     ($usage[0].cost_usd | type == "number")
  then ($usage[0] | {input_tokens,cached_input_tokens,output_tokens,reasoning_tokens,usage_scope:"aggregate",cost_usd,retry_count:0,review_findings:0})
  else {input_tokens:null,cached_input_tokens:null,output_tokens:null,reasoning_tokens:null,usage_scope:"unverified",cost_usd:null,retry_count:0,review_findings:0}
  end
' /events.jsonl)
orchestration=$(jq -c '.orchestration' <<<"$event")
input_hashes=$(jq -c --arg descriptor "$descriptor_hash" '
  {arm_config_sha256:.arm_config_sha256,descriptor_sha256:$descriptor,
   evaluation_profile_sha256:.evaluation_profile_sha256,events_sha256:.artifacts.events.sha256,
   last_message_sha256:.artifacts.last_message.sha256,profile_receipt_sha256:.artifacts.profile_receipt.sha256,
   run_receipt_sha256:.run_receipt_sha256,source_sha256:.source_hash}
' "$input")

case $test_case in
  valid) ;;
  inflated) usage=$(jq '.input_tokens += 1' <<<"$usage") ;;
  replay) input_hashes=$(jq '.events_sha256 = ("0" * 64)' <<<"$input_hashes") ;;
  contradictory) orchestration=$(jq '.planned_fanout = 7' <<<"$orchestration") ;;
  extra)
    jq -nc --argjson hashes "$input_hashes" --argjson usage "$usage" --argjson orchestration "$orchestration" \
      '{schema:1,contract:"codex-runtime-telemetry/v1",input_hashes:$hashes,usage:$usage,orchestration:$orchestration,extra:true}'
    exit 0
    ;;
  *) exit 2 ;;
esac

jq -nc --argjson hashes "$input_hashes" --argjson usage "$usage" --argjson orchestration "$orchestration" \
  '{schema:1,contract:"codex-runtime-telemetry/v1",input_hashes:$hashes,usage:$usage,orchestration:$orchestration}'
