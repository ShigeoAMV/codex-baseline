#!/usr/bin/env bash
set -Eeuo pipefail
root=${1:?workspace required}
doc="$root/ARCHITECTURE.md"
[[ -f $doc && ! -L $doc ]]
test "$(find "$root" -maxdepth 1 -type f -printf '%f\n' | LC_ALL=C sort | tr '\n' ' ')" = 'ARCHITECTURE.md requirements.md '
for concept in 'system context' 'boundar' 'data flow' 'security' 'recover' 'observ' 'deploy' 'alternative' 'non-goal' 'risk' 'rollout' 'acceptance'; do
  grep -Eiq "$concept" "$doc"
done
grep -Eiq 'tenant.*(quota|limit|fair|partition)' "$doc"
grep -Eiq '(at.least.once|duplicate|idempoten)' "$doc"
grep -Eiq '(30.minute|outage|backlog)' "$doc"
grep -Eiq '(rollback|revers)' "$doc"
grep -Eq '^```(bash|sh)[[:space:]]*$' "$doc"
grep -Eq '(^|[[:space:]])(make|curl|test|\./[^[:space:]]+)' "$doc"
[[ $(wc -w <"$doc") -ge 500 ]]
