# Question 2 — Weight: 7%

> **Context**
> You must connect to the correct host. Failure to do so may result in a zero score.
> `[candidate@base] $ ssh cka-node02`
> *(Practice note: just use your local cluster — run `./setup.sh` first.)*

---

**Task**

The Deployment `api` in the namespace `venus` exposes two ports through the
Service `api`:

- `8080/TCP`: the application API
- `9090/TCP`: the metrics endpoint

Currently, any Pod in the cluster can reach both ports.

Create a new NetworkPolicy named `api-allow` in the namespace `venus` that
applies to the Pods of the Deployment `api` and:

- allows connections to port `8080` **only** from Pods with the label
  `app=frontend` that run in the namespace `venus`
- allows connections to port `9090` **only** from Pods running in the
  namespace `monitoring`
- denies all other incoming connections to the `api` Pods

> **Note**
> - Do not restrict outgoing (egress) traffic of the `api` Pods.
> - Do not modify or relabel any existing Pods, Deployments, Services or
>   Namespaces.
> - Other Pods with the label `app=frontend` exist in other namespaces. They
>   must **not** be able to reach port `8080`.

You can test connectivity with, for example:

```
kubectl -n venus exec frontend -- wget -qO- -T 2 http://api.venus:8080
```
