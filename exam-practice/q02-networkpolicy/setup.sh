#!/usr/bin/env bash
# Builds the starting state for Question 2. Safe to re-run (resets the task).
set -euo pipefail

kubectl delete namespace venus mars monitoring --ignore-not-found --wait=true >/dev/null

kubectl apply -f - <<'EOF'
apiVersion: v1
kind: Namespace
metadata:
  name: venus
---
apiVersion: v1
kind: Namespace
metadata:
  name: mars
---
apiVersion: v1
kind: Namespace
metadata:
  name: monitoring
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: api
  namespace: venus
  labels:
    app: api
spec:
  replicas: 2
  selector:
    matchLabels:
      app: api
      tier: backend
  template:
    metadata:
      labels:
        app: api
        tier: backend
    spec:
      containers:
      - name: api
        image: busybox:stable
        command:
        - /bin/sh
        - -c
        - |
          mkdir -p /www/app /www/metrics
          echo "api: hello from $(hostname)" > /www/app/index.html
          echo "api_requests_total 42"      > /www/metrics/index.html
          httpd -p 9090 -h /www/metrics
          exec httpd -f -p 8080 -h /www/app
        ports:
        - name: http
          containerPort: 8080
        - name: metrics
          containerPort: 9090
---
apiVersion: v1
kind: Service
metadata:
  name: api
  namespace: venus
spec:
  selector:
    app: api
  ports:
  - name: http
    port: 8080
    targetPort: 8080
  - name: metrics
    port: 9090
    targetPort: 9090
---
apiVersion: v1
kind: Pod
metadata:
  name: frontend
  namespace: venus
  labels:
    app: frontend
spec:
  containers:
  - name: frontend
    image: busybox:stable
    command: ["sleep", "infinity"]
---
apiVersion: v1
kind: Pod
metadata:
  name: batch
  namespace: venus
  labels:
    app: batch
spec:
  containers:
  - name: batch
    image: busybox:stable
    command: ["sleep", "infinity"]
---
apiVersion: v1
kind: Pod
metadata:
  name: frontend
  namespace: mars
  labels:
    app: frontend
spec:
  containers:
  - name: frontend
    image: busybox:stable
    command: ["sleep", "infinity"]
---
apiVersion: v1
kind: Pod
metadata:
  name: prometheus
  namespace: monitoring
  labels:
    app: prometheus
spec:
  containers:
  - name: prometheus
    image: busybox:stable
    command: ["sleep", "infinity"]
EOF

kubectl -n venus rollout status deploy/api --timeout=120s
kubectl wait --for=condition=Ready pod/frontend pod/batch -n venus --timeout=120s >/dev/null
kubectl wait --for=condition=Ready pod/frontend -n mars --timeout=120s >/dev/null
kubectl wait --for=condition=Ready pod/prometheus -n monitoring --timeout=120s >/dev/null

echo
echo "Setup complete. Read question.md and start your timer."
