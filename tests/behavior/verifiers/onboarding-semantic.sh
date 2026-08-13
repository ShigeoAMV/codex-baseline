#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

result=${1:?result JSON required}
jq -e '
  def declared($kind; $command):
    any(.onboarding.declared_commands[];
      .kind == $kind and .command == $command and .status == "declared" and (.source | endswith("package.json")));
  .case_id == "onboarding-semantic" and .workflow == "DEEP" and .high_risk == false and
  (.selected_skills | index("codex-baseline-repo-onboarding") != null) and
  (.evidence_files | any(endswith("AGENTS.md"))) and
  (.evidence_files | any(endswith("package.json"))) and
  (.evidence_files | any(endswith("tsconfig.json"))) and
  (.evidence_files | any(endswith(".github/workflows/ci.yml"))) and
  .material_question == null and .plan == null and .risk_controls == null and .conformance == null and
  .onboarding.existing_guidance_preserved == true and
  .onboarding.repository_code_executed == false and
  .onboarding.would_overwrite == false and
  declared("build"; "npm run build") and
  declared("test"; "npm test") and
  declared("lint"; "npm run lint") and
  declared("type-check"; "npm run type-check") and
  declared("format"; "npm run format") and
  (.onboarding.important_boundaries | any(test("generated"; "i"))) and
  (.onboarding.important_boundaries | any(test("src/domain.*(must not|never).*src/http"; "i"))) and
  (.onboarding.definition_of_done | any(test("npm test"; "i"))) and
  (.onboarding.definition_of_done | any(test("npm run lint"; "i"))) and
  (.onboarding.definition_of_done | any(test("npm run type-check"; "i"))) and
  (.onboarding.proposed_validation | index("npm test") != null) and
  (.onboarding.proposed_validation | index("npm run lint") != null) and
  (.onboarding.proposed_validation | index("npm run type-check") != null)
' "$result" >/dev/null
