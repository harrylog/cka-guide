# Solution — Question 2: NetworkPolicy with per-port, per-source rules

## 1. Understanding the problem

### Starting state

```
                         Service api (venus)
                       ┌─────────────────────┐
 venus/frontend  ─────►│ 8080 http           │──► api Pods (app=api, tier=backend)
 venus/batch     ─────►│ 9090 metrics        │
 mars/frontend   ─────►│                     │
 monitoring/prometheus►└─────────────────────┘
        every arrow currently works for both ports
```

With **no NetworkPolicy selecting a Pod, all traffic to it is allowed.** That's
the Kubernetes default.

### Target state

| Source | :8080 | :9090 |
|---|---|---|
| `venus` Pod with `app=frontend` | ✅ | ❌ |
| `venus` Pod with any other label (`batch`) | ❌ | ❌ |
| `mars` Pod with `app=frontend` (decoy) | ❌ | ❌ |
| any Pod in `monitoring` | ❌ | ✅ |

### How NetworkPolicy decides

1. A policy **selects** Pods with `spec.podSelector`. Once at least one policy
   selects a Pod for `Ingress`, that Pod becomes **default-deny for ingress**.
2. Each item in `spec.ingress[]` is an **allow** rule. A connection is allowed
   if **any** rule matches, so rules are ORed.
3. Inside one rule, the connection must match **`from`** and **`ports`**
   together (AND). That's how you get "this source, only that port".
4. Policies only add allows. There are no "deny" rules.

So you need **one policy** with **two ingress rules**, each pairing a source
with a port.

---

## 2. The solution

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: api-allow
  namespace: venus
spec:
  podSelector:                 # which Pods this policy protects
    matchLabels:
      app: api
  policyTypes:
  - Ingress                    # only ingress, so egress stays unrestricted
  ingress:
  # Rule 1: frontend Pods in THIS namespace -> 8080
  - from:
    - podSelector:             # podSelector alone = same namespace as the policy
        matchLabels:
          app: frontend
    ports:
    - protocol: TCP
      port: 8080
  # Rule 2: any Pod in namespace monitoring -> 9090
  - from:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: monitoring
    ports:
    - protocol: TCP
      port: 9090
```

Write it, then apply it:

```bash
vim q2.yaml
kubectl apply -f q2.yaml
kubectl -n venus describe networkpolicy api-allow   # read it back in plain English
```

Test it. Use the exact commands; `-T 2` stops a blocked request from hanging.

```bash
kubectl -n venus      exec frontend   -- wget -qO- -T 2 http://api.venus:8080   # works
kubectl -n venus      exec frontend   -- wget -qO- -T 2 http://api.venus:9090   # times out
kubectl -n venus      exec batch      -- wget -qO- -T 2 http://api.venus:8080   # times out
kubectl -n mars       exec frontend   -- wget -qO- -T 2 http://api.venus:8080   # times out
kubectl -n monitoring exec prometheus -- wget -qO- -T 2 http://api.venus:9090   # works
./verify.sh
```

A blocked connection **times out** (`wget: download timed out`). It isn't
"refused", because the packets are silently dropped.

---

## 3. Why each piece looks the way it does

### `podSelector: {matchLabels: {app: api}}`

You need to select the Pods "of the Deployment `api`". Find their labels:

```bash
kubectl -n venus get deploy api -o jsonpath='{.spec.template.metadata.labels}'
# {"app":"api","tier":"backend"}
```

`app: api`, `tier: backend`, or both would all select the right Pods. **Don't**
use `podSelector: {}`. That selects *every* Pod in `venus`, including
`frontend` and `batch`, and changes their traffic too.

### `policyTypes: [Ingress]`

If you leave out `policyTypes`, Kubernetes sets it from what you wrote: `Ingress`
always, plus `Egress` only if there's an `egress:` section. Writing it
explicitly is clearer. Adding `Egress` with no egress rules would **block all
outgoing traffic**, including DNS, which breaks the "do not restrict egress"
note.

### Rule 1: `podSelector` alone means *this* namespace

Inside `from`, a `podSelector` **without** a `namespaceSelector` matches Pods in
the **policy's own namespace** only (`venus`). That's exactly what keeps the
decoy `mars/frontend` out.

### Rule 2: `kubernetes.io/metadata.name`

The `monitoring` namespace has no custom labels, and you're not allowed to add
any. But since v1.22 every namespace automatically gets an unchangeable label
with its own name:

```bash
kubectl get ns monitoring --show-labels
# monitoring   Active   ...   kubernetes.io/metadata.name=monitoring
```

That label is the standard way to select a namespace by name.

### Two separate rules instead of one

If you put both sources and both ports into one rule:

```yaml
  - from:
    - podSelector: {matchLabels: {app: frontend}}
    - namespaceSelector: {matchLabels: {kubernetes.io/metadata.name: monitoring}}
    ports:
    - port: 8080
    - port: 9090
```

then *every listed source* may reach *every listed port*. Frontend could read
metrics and Prometheus could call the API. That's wrong. Each "source → port"
pairing needs its own rule.

---

## 4. The #1 trap: AND vs OR in `from`

These two snippets differ by a **single dash** and mean completely different
things:

```yaml
# (A) ONE peer with both selectors = AND
#     "Pods labelled app=frontend THAT ARE IN namespace monitoring"
- from:
  - namespaceSelector:
      matchLabels: {kubernetes.io/metadata.name: monitoring}
    podSelector:
      matchLabels: {app: frontend}

# (B) TWO peers = OR
#     "ANY Pod in namespace monitoring, OR app=frontend Pods in venus"
- from:
  - namespaceSelector:
      matchLabels: {kubernetes.io/metadata.name: monitoring}
  - podSelector:
      matchLabels: {app: frontend}
```

Also watch out for this one:

```yaml
- from:
  - namespaceSelector: {}          # ALL namespaces
    podSelector:
      matchLabels: {app: frontend}  # AND app=frontend
```

It means "`app=frontend` Pods in **any** namespace", so `mars/frontend` gets in.
`verify.sh` checks for exactly this mistake.

---

## 5. Other ways to solve it

### 5a. Default-deny plus a separate allow policy

A common production pattern is a blanket deny, plus small allow policies:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-ingress
  namespace: venus
spec:
  podSelector: {}          # every Pod in venus
  policyTypes: [Ingress]
```

Allows from all policies that select a Pod are combined (unioned), so
`api-allow` would still let the right traffic in. **On this exam task, don't do
it.** It would also cut off ingress to `frontend` and `batch`, which the task
didn't ask for. In real life it's a great baseline.

### 5b. Named ports instead of numbers

The api container names its ports (`http`, `metrics`), so this also works:

```yaml
    ports:
    - protocol: TCP
      port: http       # resolved per Pod from containerPort names
```

This is handy when different Pods use different port numbers for the same
role. Numbers are simpler and harder to get wrong under time pressure.

### 5c. Generate a skeleton, then edit it

`kubectl create` has no `networkpolicy` subcommand, so you can't run
`kubectl create networkpolicy`. Copy the example from the docs page instead
(link below), and delete what you don't need. It's faster than typing it from
memory.

### 5d. Selecting by namespace *and* Pod

If the task had said "only Pods labelled `app=prometheus` in `monitoring`", use
form **(A)** from section 4: one peer with both `namespaceSelector` and
`podSelector`.

---

## 6. Common mistakes

1. **`namespaceSelector: {}` with `podSelector`.** This allows the label from
   *every* namespace (lets `mars/frontend` in).
2. **One combined rule.** Sources and ports become all-to-all (see section 3).
3. **`podSelector: {}` as the policy target.** This also isolates `frontend`
   and `batch`.
4. **Adding `Egress` to `policyTypes`.** This blocks DNS and all outgoing
   traffic of the api Pods.
5. **Labelling the `monitoring` namespace.** It works, but the task forbids it.
   Use `kubernetes.io/metadata.name`.
6. **Using the Service port when it differs from the Pod port.** NetworkPolicy
   ports are the **Pod (target) ports**, not the Service ports. They're the same
   here (8080/9090), but they won't always be.
7. **Testing without a timeout.** `wget` with no `-T` hangs for a long time on a
   blocked port and wastes exam time.

## Docs to bookmark (allowed in the exam)

- Network Policies (has the full example to copy):
  https://kubernetes.io/docs/concepts/services-networking/network-policies/
- Behaviour of `to` and `from` selectors (the AND/OR rule):
  https://kubernetes.io/docs/concepts/services-networking/network-policies/#behavior-of-to-and-from-selectors
- Declare a Network Policy (walkthrough):
  https://kubernetes.io/docs/tasks/administer-cluster/declare-network-policy/
