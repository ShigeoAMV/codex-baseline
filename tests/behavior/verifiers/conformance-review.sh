#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

result=${1:?result JSON required}
jq -e '
  def criterion($id; $status): any(.conformance.criteria[]; .id == $id and .status == $status and (.evidence | length) > 0);
  .case_id == "conformance-review" and .workflow == "STRICT" and .high_risk == false and
  (.selected_skills | index("codex-baseline-conformance-review") != null) and
  (.evidence_files | any(endswith("original-request.md"))) and
  (.evidence_files | any(endswith("acceptance.md"))) and
  (.evidence_files | any(endswith("artifact.md"))) and
  (.evidence_files | any(endswith("verification.md"))) and
  .material_question == null and .plan == null and .risk_controls == null and .onboarding == null and
  .conformance.independent == true and criterion("C1"; "delivered") and criterion("C2"; "missing") and
  (.conformance.findings | any((.severity == "CRITICAL" or .severity == "HIGH" or .severity == "MEDIUM") and (.evidence | test("rollback|restore|hash"; "i")))) and
  .conformance.verdict == "reject"
' "$result" >/dev/null
