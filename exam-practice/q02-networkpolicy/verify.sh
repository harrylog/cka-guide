#!/usr/bin/env bash
# Grades Question 2.
set -uo pipefail

pass=0; fail=0
check() { # check "<description>" <exit-code>
  if [ "$2" -eq 0 ]; then echo "  [PASS] $1"; pass=$((pass+1)); else echo "  [FAIL] $1"; fail=$((fail+1)); fi
}

# reach <ns> <pod> <port>  -> exit 0 if the connection succeeds
reach() {
  kubectl -n "$1" exec "$2" -- wget -qO- -T 2 "http://api.venus.svc.cluster.local:$3" >/dev/null 2>&1
}
expect_allow() { reach "$1" "$2" "$3"; check "$1/$2 -> api:$3 is ALLOWED" $?; }
expect_deny()  { ! reach "$1" "$2" "$3"; check "$1/$2 -> api:$3 is DENIED" $?; }

echo "Question 2 — grading"

if ! np=$(kubectl -n venus get networkpolicy api-allow -o json 2>/dev/null); then
  echo "  [FAIL] NetworkPolicy venus/api-allow not found"; exit 1
fi
check "NetworkPolicy venus/api-allow exists" 0

# Policy must select exactly the api Pods
api_pods=$(kubectl -n venus get pods -l app=api -o name | sort)
sel=$(jq -r '.spec.podSelector.matchLabels // {} | to_entries | map("\(.key)=\(.value)") | join(",")' <<<"$np")
selected=$( [ -n "$sel" ] && kubectl -n venus get pods -l "$sel" -o name | sort )
expr_count=$(jq '.spec.podSelector.matchExpressions // [] | length' <<<"$np")
[ -n "$sel" ] && [ "$expr_count" -eq 0 ] && [ "$selected" = "$api_pods" ]
check "podSelector selects exactly the api Pods" $?

! jq -e '.spec.policyTypes // [] | index("Egress")' <<<"$np" >/dev/null
check "egress is not restricted" $?

# Existing objects untouched
[ "$(kubectl -n venus get pod frontend -o jsonpath='{.metadata.labels.app}')" = "frontend" ] \
  && [ "$(kubectl -n mars get pod frontend -o jsonpath='{.metadata.labels.app}')" = "frontend" ] \
  && [ "$(kubectl get ns monitoring -o json | jq '.metadata.labels | del(."kubernetes.io/metadata.name") | length')" -eq 0 ]
check "existing Pods/Namespaces were not relabelled" $?

# Give the policy controller a moment to program the rules
sleep 3

echo "  -- connectivity --"
expect_allow venus      frontend   8080
expect_deny  venus      frontend   9090
expect_deny  venus      batch      8080
expect_deny  venus      batch      9090
expect_deny  mars       frontend   8080
expect_deny  mars       frontend   9090
expect_allow monitoring prometheus 9090
expect_deny  monitoring prometheus 8080

echo
echo "Score: $pass/$((pass+fail))"
[ "$fail" -eq 0 ] && echo "RESULT: PASS" || echo "RESULT: FAIL"
