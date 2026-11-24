# Solution — Question 1: Streaming sidecar for a file-based logger

## 1. Understanding the problem

### How `kubectl logs` actually works

`kubectl logs` shows only what a container writes to **stdout/stderr**. The
container runtime captures those two streams and stores them on the node, under
`/var/log/pods/<ns>_<pod>_<uid>/<container>/`. The kubelet serves that file to the
API server when you run `kubectl logs`.

```
 app container                      node
 ┌──────────────┐  stdout/stderr   ┌───────────────────────────┐
 │  echo ...    │ ───────────────► │ /var/log/pods/.../app/0.log│ ◄── kubectl logs
 └──────────────┘                  └───────────────────────────┘
```

### What the legacy app does instead

```sh
echo "... processed order $i" >> /var/log/legacy-app.log
```

The `>>` redirect sends every line to a **file inside the container's own
filesystem** (its writable overlay layer). So:

- stdout stays empty, and `kubectl logs ... -c app` prints nothing.
- No other container can see the file. Each container has its own private
  root filesystem.
- The file is lost whenever the container restarts.

### The constraint that shapes the answer

> *Do not modify the specification of the existing container other than adding
> the required volume mount.*

You can't fix the app itself (for example, by making it log to stdout). You
have to work *around* it. That's the textbook case for the **streaming sidecar
pattern** from the Kubernetes logging docs.

---

## 2. The solution

### Idea

```
 Pod legacy-app
 ┌───────────────────────────────────────────────────────────┐
 │  app container                 sidecar container          │
 │  writes ──► /var/log/legacy-app.log ──► tail -f ──► stdout ──► kubectl logs -c sidecar
 │                  │                          │             │
 │                  └──── emptyDir "logs" ─────┘             │
 │                    (same directory in both)               │
 └───────────────────────────────────────────────────────────┘
```

1. Add a **volume** (`emptyDir`) to the Pod.
2. Mount it at `/var/log` in **both** containers. They now see the same directory.
3. Add a **sidecar** container that `tail`s the file to **its own stdout**.
   That stdout is captured like any other container's, so
   `kubectl logs -c sidecar` works.

### The three additions, and where each one goes

| Addition | YAML path | Indented under |
|---|---|---|
| `volumeMounts` for app | `spec.template.spec.containers[app].volumeMounts` | the `app` container, same column as `image:` |
| `sidecar` container | `spec.template.spec.containers[]` | the `containers:` list, as a new `- name:` item |
| `volumes` | `spec.template.spec.volumes` | Pod `spec:`, same column as `containers:` |

Check any path with `kubectl explain`, for example:
`kubectl explain deploy.spec.template.spec.volumes.emptyDir`

### Final Deployment (complete, valid YAML)

```yaml
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
    spec:                              # Pod spec: same column as metadata:
      containers:
      - name: app                      # existing container: only volumeMounts added
        image: busybox:stable
        command:
        - /bin/sh
        - -c
        - 'i=0; while true; do echo "$(date) INFO legacy-app processed order $i" >> /var/log/legacy-app.log; i=$((i+1)); sleep 5; done'
        resources:
          requests:
            cpu: 10m
            memory: 16Mi
        volumeMounts:                  # NEW
        - name: logs
          mountPath: /var/log
      - name: sidecar                  # NEW container
        image: busybox:stable
        command:
        - /bin/sh
        - -c
        - tail -n+1 -f /var/log/legacy-app.log
        volumeMounts:
        - name: logs
          mountPath: /var/log
      volumes:                         # NEW: same column as containers:
      - name: logs
        emptyDir: {}
```

When you edit the live object, it also contains server-added fields
(`terminationMessagePath`, `dnsPolicy`, `status:` …). Leave them where they are.
**Only insert** the three blocks. Don't paste a whole spec over them.

### Doing it on the exam

**Option A: edit a file (recommended, because it keeps a backup)**

```bash
kubectl -n mercury get deploy legacy-app -o yaml > q1.yaml
vim q1.yaml                     # insert the 3 blocks
kubectl apply -f q1.yaml        # must say "configured"
```

**Option B: edit the live object**

```bash
kubectl -n mercury edit deploy legacy-app
```

If saving fails, kubectl keeps your edit in `/tmp/kubectl-edit-*.yaml`. Fix that
file and run `kubectl replace -f <file>`.

vim helpers: `/terminationMessagePolicy` jumps to the end of the `app` container.
Then press `o` to open a new line at the same indentation. Use `:set paste`
before pasting.

### Verifying (don't trust `rollout status` alone)

```bash
kubectl -n mercury get deploy legacy-app -o jsonpath='{.metadata.generation}{"\n"}'  # must be >1
kubectl -n mercury get pod -l app=legacy-app        # NEW pod name, small AGE, READY 2/2
kubectl -n mercury logs deploy/legacy-app -c sidecar
./verify.sh
```

`rollout status` reports "successfully rolled out" even when **nothing was
changed**, because the original rollout is still the latest one. A Pod that is
old and `1/1` means your edit never landed.

---

## 3. Why a sidecar?

A sidecar is an extra container in the **same Pod** as the main application.
Containers in one Pod:

- are always **scheduled together** on the same node,
- **share volumes** (so they can share files),
- share the network namespace (`localhost`),
- have the same lifecycle (created and deleted together).

That's exactly what you need here: a helper that can read the app's files
without touching the app. Benefits:

- **No change to the app.** The legacy binary and its image stay as they are.
- **Separation of concerns.** Log handling lives in its own container. You can
  update or remove it on its own.
- **Standard tooling works again.** `kubectl logs`, and any node-level log
  collector (Fluent Bit, Promtail…) that reads `/var/log/pods`, now pick up
  these logs.

Costs: an extra container per Pod (a little CPU and memory). The log data is
also written twice, once to the emptyDir and once to the container log on the
node.

---

## 4. Why `emptyDir`?

`emptyDir` is a directory that is created empty when the Pod starts on a node,
shared by **all containers in that Pod**, and deleted when the Pod is removed.
It survives container restarts, but not Pod deletion.

That's exactly the scope of the problem: two containers in one Pod need to
share a scratch directory, and nobody needs the files after the Pod is gone.

| Volume type | Would it work? | Why it's not the best choice here |
|---|---|---|
| **emptyDir** | ✅ | Pod-scoped and shared, no setup, no node coupling. **Best fit.** |
| `emptyDir: {medium: Memory}` | ✅ | tmpfs (RAM): fast, but every byte counts against the Pod's memory limit. Risky for a growing log file. |
| `hostPath` (e.g. `/var/log/legacy`) | ⚠️ works | Ties the Pod to a node directory. Replicas on the same node write to the same file. A security risk (often blocked by Pod Security "restricted"). Files are left behind on the node. |
| `persistentVolumeClaim` | ⚠️ works | Needs a StorageClass or PV. Overkill for temporary logs. With `ReadWriteOnce` and several replicas on different nodes, it fails. |
| `configMap` / `secret` | ❌ | Mounted **read-only**, so the app can't write. |

Tip: add `sizeLimit` so a runaway log can't fill the node's disk:

```yaml
volumes:
- name: logs
  emptyDir:
    sizeLimit: 100Mi     # Pod is evicted if exceeded
```

Gotcha: mounting a volume at `/var/log` **hides** whatever the image had in
`/var/log`. For busybox that directory is empty, so it doesn't matter. For other
images, mount just a subdirectory (e.g. `/var/log/app`), or use `subPath`.

---

## 5. Other ways to solve it

### 5a. Native sidecar container (Kubernetes ≥ 1.29, GA in 1.33)

A container in `initContainers` with `restartPolicy: Always`:

```yaml
      initContainers:
      - name: sidecar
        image: busybox:stable
        restartPolicy: Always          # this is what makes it a native sidecar
        command: ["/bin/sh", "-c", "tail -n+1 -F /var/log/legacy-app.log"]   # -F, not -f
        volumeMounts:
        - name: logs
          mountPath: /var/log
```

Advantages over a plain second container:

- It **starts before** the main containers and **stops after** them, so it
  doesn't miss the first or last log lines.
- In **Jobs**, a regular sidecar that never exits keeps the Job from
  completing. A native sidecar doesn't block completion.

**Why it fails with the exact command from the task.** A native sidecar starts
first, *before* `app` has created the log file. busybox `tail -f` on a missing
file prints `can't open ... No such file or directory` and exits with code 1.
The sidecar keeps crashing, and the Pod stays in `Init:Error` / `0/2` (tested on
this cluster). `tail -F` (capital F) waits for the file to appear and then
follows it, which fixes the problem. The task gives you the `-f` command, so use
the regular-container form on the exam.

### 5b. Make the app log to stdout (best in real life, not allowed here)

The cleanest fix is for the app to write logs to stdout, the
[12-factor](https://12factor.net/logs) way. If you can't change the code, a
symlink does the same thing. This is how the official nginx image works:

```sh
ln -sf /dev/stdout /var/log/legacy-app.log
```

You'd need to change the `app` container's command or image. The task forbids
that, so it's not acceptable here. In production it's usually the best answer:
no extra container and no duplicated log data.

### 5c. Logging-agent sidecar (ship logs elsewhere)

Instead of `tail`, run a log shipper (Fluent Bit, Vector, Promtail) as the
sidecar. It reads the file from the shared emptyDir and sends it straight to
Elasticsearch, Loki and so on. It uses the same pattern (sidecar + emptyDir),
but it doesn't make `kubectl logs` work, so it doesn't meet this task's
requirement.

### 5d. Node-level logging agent (DaemonSet)

The usual cluster-wide approach is one Fluent Bit (or similar) DaemonSet per
node, reading `/var/log/pods/*`. It only sees **stdout/stderr**. A log file
inside a container is invisible to it, so you'd **still** need a streaming
sidecar (or 5b). The two approaches work together; one doesn't replace the
other.

### 5e. `kubectl exec` (not a solution)

```bash
kubectl -n mercury exec deploy/legacy-app -c app -- tail -f /var/log/legacy-app.log
```

Useful for a quick look while debugging. It changes nothing, so it doesn't
satisfy the task.

### Summary

| Approach | Meets this task? | Real-world use |
|---|---|---|
| Regular sidecar + emptyDir | ✅ **exam answer** | Legacy apps you can't change |
| Native sidecar + emptyDir | ⚠️ only with `tail -F` | Preferred on modern clusters, essential in Jobs |
| App logs to stdout / symlink | ❌ (changes app) | Best when you control the image |
| Log-shipper sidecar | ❌ (no `kubectl logs`) | Send file logs straight to a backend |
| Node DaemonSet agent | ❌ (can't see files) | Standard cluster logging, alongside the above |
| `kubectl exec tail` | ❌ | Ad-hoc debugging only |

---

## 6. Common mistakes (seen in practice)

1. **Pasting shorthand literally.** Writing `command: [...unchanged...]` in the
   real YAML. Keep the real fields and only *insert* new blocks.
2. **Wrong indentation of `spec:`.** If Pod `spec:` ends up under `labels:`,
   YAML treats it as a label. It must line up with `metadata:`.
3. **Fields pushed out of their container.** Inserting in the middle of the
   `app` container leaves `terminationMessagePath`/`Policy` under `volumes`.
   Insert *after* the container's last field.
4. **Trusting `rollout status`.** It says "successfully rolled out" for an
   unchanged Deployment. Check that the Pod is new and `2/2`.
5. **Mounting the volume in only one container.** Each container has to mount
   it.
6. **Volume name mismatch.** The `volumeMounts[].name` must equal
   `volumes[].name` (`logs`).
7. **Using `-c sidecar` on the old Pod.** If the old Pod is still terminating,
   `kubectl logs deploy/...` may pick it and report
   `container sidecar is not valid`.

## Docs to bookmark (allowed in the exam)

- Logging architecture, streaming sidecar:
  https://kubernetes.io/docs/concepts/cluster-administration/logging/#streaming-sidecar-container
- Sidecar containers (native):
  https://kubernetes.io/docs/concepts/workloads/pods/sidecar-containers/
- Volumes, emptyDir:
  https://kubernetes.io/docs/concepts/storage/volumes/#emptydir
- Communicate between containers in a Pod (shared volume example):
  https://kubernetes.io/docs/tasks/access-application-cluster/communicate-containers-same-pod-shared-volume/
