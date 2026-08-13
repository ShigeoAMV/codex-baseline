#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

result=${1:?result JSON required}
jq -e '
  .case_id == "ambiguity-research" and .workflow == "DEEP" and .high_risk == false and
  (.selected_skills | index("codex-baseline-deep-work") != null) and
  (.evidence_files | any(endswith("request.md"))) and
  (.evidence_files | any(endswith("README.md"))) and
  (.evidence_files | any(endswith("docs/current-contract.md"))) and
  .material_question.needed == true and
  (.material_question.topic | test("compatib|deprecat|legacy"; "i")) and
  (.material_question.question | test("legacy_name"; "i")) and
  (.material_question.question | test("immediate|window|day|deprecat"; "i")) and
  .plan == null and .risk_controls == null and .onboarding == null and .conformance == null
' "$result" >/dev/null
