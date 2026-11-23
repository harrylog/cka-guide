#!/usr/bin/env bash
# Grades Question 1.
set -uo pipefail

NS=mercury
DEPLOY=legacy-app
EXPECTED_APP_CMD='i=0; while true; do echo "$(date) INFO legacy-app processed order $i" >> /var/log/legacy-app.log; i=$((i+1)); sleep 5; done'

pass=0; fail=0
check() { # check "<description>" <exit-code>
  if [ "$2" -eq 0 ]; then echo "  [PASS] $1"; pass=$((pass+1)); else echo "  [FAIL] $1"; fail=$((fail+1)); fi
}

echo "Question 1 — grading"

if ! spec=$(kubectl -n "$NS" get deploy "$DEPLOY" -o json 2>/dev/null); then
  echo "  [FAIL] Deployment $NS/$DEPLOY not found"; exit 1
fi
pod=$(jq '.spec.template.spec' <<<"$spec")

# Accept the sidecar under containers or as a native sidecar under initContainers
sidecar=$(jq '[(.initContainers // [])[], (.containers // [])[]] | map(select(.name=="sidecar")) | first // empty' <<<"$pod")
sidecar=${sidecar:-'{}'}
app=$(jq '.containers[] | select(.name=="app")' <<<"$pod")

[ "$sidecar" != "{}" ]; check "container 'sidecar' exists" $?
[ "$(jq -r '.image // ""' <<<"$sidecar")" = "busybox:stable" ]; check "sidecar image is busybox:stable" $?

sc_cmd=$(jq -r '((.command // []) + (.args // [])) | join(" ")' <<<"$sidecar")
grep -qE 'tail -n ?\+1 -f /var/log/legacy-app.log' <<<"$sc_cmd"; check "sidecar runs 'tail -n+1 -f /var/log/legacy-app.log'" $?

jq -e '.volumes // [] | map(select(.name=="logs")) | length==1' <<<"$pod" >/dev/null; check "pod has a volume named 'logs'" $?
jq -e '.volumeMounts // [] | map(select(.name=="logs" and .mountPath=="/var/log")) | length==1' <<<"$sidecar" >/dev/null
check "sidecar mounts 'logs' at /var/log" $?
jq -e '.volumeMounts // [] | map(select(.name=="logs" and .mountPath=="/var/log")) | length==1' <<<"$app" >/dev/null
check "app mounts 'logs' at /var/log" $?

# Existing container untouched (apart from volumeMounts)
[ "$(jq -r '.image' <<<"$app")" = "busybox:stable" ] \
  && [ "$(jq -r '.command[2]' <<<"$app")" = "$EXPECTED_APP_CMD" ]
check "existing container 'app' image/command unchanged" $?

kubectl -n "$NS" rollout status deploy/"$DEPLOY" --timeout=90s >/dev/null 2>&1; check "deployment rolled out and ready" $?

# Read from a running pod that has the sidecar (old pods may still be terminating)
ok=1
for _ in $(seq 1 12); do
  for p in $(kubectl -n "$NS" get pods -l app=legacy-app --field-selector=status.phase=Running -o name 2>/dev/null); do
    if kubectl -n "$NS" logs "$p" -c sidecar --tail=3 2>/dev/null | grep -q "legacy-app processed order"; then ok=0; break 2; fi
  done
  sleep 5
done
check "'kubectl logs -c sidecar' shows application log lines" $ok

echo
echo "Score: $pass/$((pass+fail))"
[ "$fail" -eq 0 ] && echo "RESULT: PASS" || echo "RESULT: FAIL"
