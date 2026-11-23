#!/usr/bin/env bash
# Builds the starting state for Question 1. Safe to re-run (resets the task).
set -euo pipefail

NS=mercury

kubectl delete deployment legacy-app -n "$NS" --ignore-not-found --wait=true >/dev/null 2>&1 || true
kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

kubectl apply -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: legacy-app
  namespace: mercury
  labels:
    app: legacy-app
spec:
  replicas: 1
  selector:
    matchLabels:
      app: legacy-app
  template:
    metadata:
      labels:
        app: legacy-app
    spec:
      containers:
      - name: app
        image: busybox:stable
        command:
        - /bin/sh
        - -c
        - 'i=0; while true; do echo "$(date) INFO legacy-app processed order $i" >> /var/log/legacy-app.log; i=$((i+1)); sleep 5; done'
        resources:
          requests:
            cpu: 10m
            memory: 16Mi
EOF

kubectl -n "$NS" rollout status deploy/legacy-app --timeout=120s
echo
echo "Setup complete. Read question.md and start your timer."
