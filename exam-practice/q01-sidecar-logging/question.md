# Question 1 — Weight: 4%

> **Context**
> You must connect to the correct host. Failure to do so may result in a zero score.
> `[candidate@base] $ ssh cka-node01`
> *(Practice note: just use your local cluster — run `./setup.sh` first.)*

---

**Task**

An existing legacy application runs as the Deployment `legacy-app` in the
namespace `mercury`. The application writes its log output to the file
`/var/log/legacy-app.log` and does **not** write anything to stdout, so its
logs cannot be read with `kubectl logs`.

Update the existing Deployment `legacy-app`, adding a co-located container
to the Pod with the following specification:

- Name: `sidecar`
- Image: `busybox:stable`
- The container must run the command:

  ```
  /bin/sh -c "tail -n+1 -f /var/log/legacy-app.log"
  ```

Use a Volume named `logs`, mounted at `/var/log`, to make the log file
`legacy-app.log` available to the co-located container.

> **Note**
> Do not modify the specification of the existing container other than adding
> the required volume mount.

After your changes, the following command must stream the application's log
lines:

```
kubectl -n mercury logs deploy/legacy-app -c sidecar
```
