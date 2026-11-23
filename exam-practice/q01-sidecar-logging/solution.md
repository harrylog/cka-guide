# Solution — Question 1

## Steps

```bash
kubectl -n mercury get deploy legacy-app -o yaml > q1.yaml   # backup first
kubectl -n mercury edit deploy legacy-app                    # or edit q1.yaml + kubectl apply -f
```

Edit `spec.template.spec` so it looks like this (additions marked `# +`):

```yaml
    spec:
      containers:
      - name: app
        image: busybox:stable
        command: [...unchanged...]
        resources: {...unchanged...}
        volumeMounts:                                   # +
        - name: logs                                    # +
          mountPath: /var/log                           # +
      - name: sidecar                                   # +
        image: busybox:stable                           # +
        command: ["/bin/sh", "-c", "tail -n+1 -f /var/log/legacy-app.log"]  # +
        volumeMounts:                                   # +
        - name: logs                                    # +
          mountPath: /var/log                           # +
      volumes:                                          # +
      - name: logs                                      # +
        emptyDir: {}                                    # +
```

Check it:

```bash
kubectl -n mercury rollout status deploy/legacy-app
kubectl -n mercury get pod -l app=legacy-app        # READY 2/2
kubectl -n mercury logs deploy/legacy-app -c sidecar
```

## Why

- **emptyDir** is the right volume type. Every container in the Pod shares it,
  and it lasts as long as the Pod does.
- Before the change, the log file lived in the `app` container's own writable
  layer, so no other container could see it.
- `tail -n+1 -f` prints the file from line 1 and keeps following it, so the
  sidecar's stdout (and so `kubectl logs`) mirrors the log file.
- You may see the sidecar restart once if it starts before `app` has created the
  file. That's harmless: it recovers as soon as the file exists.

## Gotcha: native sidecar (`initContainers` + `restartPolicy: Always`)

A native sidecar **starts before** the main containers, and the kubelet waits for
it to be running before it starts `app`. Here, `tail -f` exits straight away
because `/var/log/legacy-app.log` doesn't exist yet. So `app` never starts and
the Pod loops in `Init:Error`, which means the native form fails with this exact
command. To use a native sidecar for log shipping, use `tail -F` (it retries
until the file appears) or `touch` the file first. On the exam, use the command
exactly as given.

## Docs to bookmark

- Sidecar containers: https://kubernetes.io/docs/concepts/workloads/pods/sidecar-containers/
- Logging architecture (streaming sidecar): https://kubernetes.io/docs/concepts/cluster-administration/logging/
