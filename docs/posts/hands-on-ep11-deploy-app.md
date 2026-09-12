---
date: 2026-09-12
description: "The capstone episode — deploy a real app end-to-end on your homelab: namespace, Deployment, Service, Ingress+TLS, persistent storage, a Secret, and a live metric. Everything from episodes 1–10 in one walkthrough."
categories: [Homelab, Kubernetes, Hands-On Tutorial]
tags: [k3s, kubernetes, flux, gitops, helm, deployments, ingress, longhorn, sops, monitoring, homelab]
comments: true
series: Homelab From Scratch (Hands-On Build)
---

# Deploy a real app end-to-end (capstone)

<!-- more -->

You've installed k3s, stood up Cilium, bootstrapped Flux, wired Traefik and Let's Encrypt, deployed Longhorn, encrypted secrets with SOPS + age, installed Headscale for remote access, added Prometheus + Grafana + ntfy alerting, and set up Renovate, Reloader, and CrowdSec. That's a lot of infrastructure — and until now, none of the episodes has asked you to put a **real application** on top of it.

This episode fixes that. We'll deploy a small but realistic service from scratch and walk through every layer you've built so far: a namespace, a ServiceAccount, a Deployment, a Service, an Ingress with TLS, a PersistentVolumeClaim on Longhorn, a SOPS-encrypted Secret, and a custom metric we can alert on.

This is the capstone for the **Homelab From Scratch (Hands-On Build)** series — the point where all the pieces click together.

## What we're deploying

We'll build a tiny "hello" service that:

- Serves a JSON greeting on `/` and a `/metrics` endpoint (so Prometheus can scrape it).
- Stores a counter in a file on a Longhorn volume, so restarts survive.
- Reads a configurable greeting prefix from a Secret (the SOPS-encrypted kind you learned in [episode 7: secrets without plaintext](/secrets-without-plaintext-sops--age/)).
- Is reachable at a `*.example.com` hostname with a real Let's Encrypt certificate (from [episode 5: ingress + free TLS](/ingress--free-tls-traefik--cert-manager/)).
- Sends a custom Prometheus metric that we can hook into the ntfy alerting you set up in [episode 9: monitoring that pages you](/monitoring-that-pages-you-prometheus--grafana--ntfy/).

By the end, you'll have a template you can adapt for any real app you want to self-host.

!!! tip "You already have all the pieces"
    This episode doesn't install anything new. It reuses every platform component from earlier episodes — the only difference is that you're wiring them together for a new app instead of following a platform install recipe.

## The plan (and why each step exists)

Before we write any YAML, here's the order and the reason:

1. **Namespace + ServiceAccount** — every app gets its own namespace and a dedicated ServiceAccount. This is the same pattern HomeOps uses for all its apps: isolates resources, makes RBAC and `kubectl` cleanup obvious, and gives you a natural place for per-app Secrets and ConfigMaps.

2. **PersistentVolumeClaim (Longhorn)** — if your app keeps any state (a counter file, a SQLite database, uploads, config that must survive a restart), it needs a volume. Longhorn gives you a replicated block device; your PVC just asks for storage and Longhorn makes it real across the nodes you set up in [episode 6: distributed storage](/distributed-storage-with-longhorn/).

3. **Deployment** — the actual workload. We'll keep it small: one replica, a volume mount for the counter file, an env var injected from a Secret, and the image pull policy you'd actually use.

4. **Service** — a stable ClusterIP so the Deployment, other pods in the cluster, and the Ingress can all reach the app by name.

5. **Ingress + TLS** — the external-facing piece. Traefik routes `hello.example.com` to your Service, and cert-manager provisions a real Let's Encrypt certificate. This is the same pattern as every other app in the series.

6. **Secret (SOPS + age)** — a greeting prefix the app reads at startup. Encrypted in git, decrypted by Flux at apply time. No plaintext secrets anywhere.

7. **A custom metric + a first alert** — the app exposes a `/metrics` page; we add one Prometheus recording/alert rule so the whole "expose a metric → alertmanager → ntfy" chain from episode 9 has something to fire on.

## Step 1 — the namespace and ServiceAccount

Create a directory for the app — call it `hello/` (or anything you like; the name is just the directory and the Kubernetes names inside).

```yaml
# hello/namespace.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: hello
```

```yaml
# hello/serviceaccount.yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: hello
  namespace: hello
```

That's it for the account — we aren't giving this app any special Kubernetes permissions (it doesn't need to list pods or read secrets), so the default ServiceAccount behavior is fine once we name it explicitly. Naming it explicitly is still good practice: it means the pod's `serviceAccountName` is obvious in the Deployment, and it's the first step toward giving the app a scoped identity later if you ever need one (the broker + ServiceAccount pattern from [episode 10: keeping it patched & safe: Renovate, Reloader, CrowdSec](/keeping-it-patched--safe-renovate-reloader-crowdsec/)).

!!! info "Going further — RBAC for apps that need Kubernetes API access"
    If your app ever needs to talk to the Kubernetes API (listing pods, reading config, etc.), create a `ClusterRole` + `ClusterRoleBinding` (or a namespaced `Role` + `RoleBinding`) scoped to exactly what it needs, and bind it to this ServiceAccount. The HomeOps repo does this for apps like homepage that render a cluster overview. For our hello service, no API access is needed, so we stop at the ServiceAccount.

## Step 2 — the PersistentVolumeClaim

Our counter file lives on disk. Create a PVC that asks Longhorn for 1 GiB:

```yaml
# hello/pvc.yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: hello-data
  namespace: hello
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: longhorn
  resources:
    requests:
      storage: 1Gi
```

A few things worth noticing:

- `storageClassName: longhorn` — this is the StorageClass you installed in [episode 6](/distributed-storage-with-longhorn/). Without it, the PVC would sit in `Pending` forever.
- `ReadWriteOnce` — the volume can be mounted by one node at a time. That's fine for a single-replica app. If you ever run a multi-replica stateful workload, you'd need `ReadWriteMany` (and a storage backend that supports it — Longhorn supports RWO natively; RWX needs the NFS/other backing path).
- `1Gi` — over-provisioning storage "just in case" is a real habit; resist it. Start small. Longhorn volumes are cheap to grow later if the app actually needs it, and a 1 GiB volume for a counter file is plenty.

!!! warning "PVCs persist after you delete the Deployment"
    If you delete the hello Deployment, the PVC and its data stay — PVCs are independent objects and aren't garbage-collected when their workload disappears. The `reclaimPolicy` controls what happens to the underlying PersistentVolume when you *do* delete the PVC explicitly. The upstream Longhorn chart defaults this to `Delete` (deleting the PVC tears down the volume), but episode 6 set yours to `Retain` — so on your cluster, deleting the PVC leaves the PV intact.

## Step 3 — the Secret (SOPS-encrypted)

The app reads a greeting prefix from an environment variable. We'll store that prefix in a Secret, and encrypt that Secret with SOPS + age so it's safe in git.

First, the **plaintext source** you'd create on your own machine (this is the file you'd encrypt — never commit this plaintext):

```yaml
# hello-secret.yaml  (plaintext — do NOT commit this)
apiVersion: v1
kind: Secret
metadata:
  name: hello-config
  namespace: hello
type: Opaque
stringData:
  GREETING_PREFIX: "Hello from my homelab"
```

Then encrypt it:

```bash
sops --encrypt --age age1examplepublickey... --in-place hello-secret.yaml
```

After encryption, the file becomes `hello-secret.sops.yaml` — the `sops:` metadata block at the bottom is what tells Flux how to decrypt it at apply time, using the `sops-age` Secret you set up in episode 7.

The encrypted file looks roughly like this (only the first line shown; the real file is longer):

```yaml
# hello-secret.sops.yaml  (commit this)
apiVersion: ENC[AES256_GCM,data:...,iv:...,tag:...,type:str]
kind: ENC[AES256_GCM,data:...,iv:...,tag:...,type:str]
metadata:
  name: hello-config
  namespace: hello
stringData:
  GREETING_PREFIX: ENC[AES256_GCM,data:...,iv:...,tag:...,type:str]
sops:
  age:
    - recipient: age1examplepublickey...
      enc: |
        -----BEGIN AGE ENCRYPTED FILE-----
        ...
        -----END AGE ENCRYPTED FILE-----
```

!!! warning "Never commit the plaintext version"
    The whole point of SOPS is that the plaintext `hello-secret.yaml` never enters git. Only `hello-secret.sops.yaml` does. If you accidentally `git add` the plaintext file, `git rm --cached` it and re-add the `.sops.yaml` version before pushing. (A real CI check — like the one in the HomeOps repo's `ci.yml` — would catch an unencrypted secret and fail the build.)

## Step 4 — the ConfigMap (non-secret config)

Not everything belongs in a Secret. The app also needs a non-sensitive config value: which port to listen on, or how often to flush the counter to disk. Put that in a ConfigMap:

```yaml
# hello/configmap.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: hello-config
  namespace: hello
data:
  LOG_LEVEL: "info"
  COUNTER_FLUSH_INTERVAL_SECONDS: "60"
```

Plain ConfigMaps are fine for non-secret values. The distinction matters: ConfigMaps are not encrypted in etcd by default, so they're for configuration that's OK to be readable cluster-wide. Secrets (the SOPS-encrypted ones) are for anything you wouldn't want in plain etcd.

## Step 5 — the Deployment

Now the actual workload:

```yaml
# hello/deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: hello
  namespace: hello
spec:
  replicas: 1
  selector:
    matchLabels:
      app: hello
  template:
    metadata:
      labels:
        app: hello
    spec:
      serviceAccountName: hello
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
        fsGroup: 1000
      containers:
        - name: hello
          image: ghcr.io/your-username/hello-homelab:0.1.0
          ports:
            - name: http
              containerPort: 8080
          env:
            - name: GREETING_PREFIX
              valueFrom:
                secretKeyRef:
                  name: hello-config
                  key: GREETING_PREFIX
            - name: LOG_LEVEL
              valueFrom:
                configMapKeyRef:
                  name: hello-config
                  key: LOG_LEVEL
          volumeMounts:
            - name: data
              mountPath: /data
          resources:
            requests:
              cpu: 50m
              memory: 64Mi
            limits:
              cpu: 200m
              memory: 128Mi
          livenessProbe:
            httpGet:
              path: /healthz
              port: http
            initialDelaySeconds: 5
            periodSeconds: 10
          readinessProbe:
            httpGet:
              path: /healthz
              port: http
            initialDelaySeconds: 3
            periodSeconds: 5
      volumes:
        - name: data
          persistentVolumeClaim:
            claimName: hello-data
```

A few notes on what's here and why:

- `replicas: 1` — a single replica is the right starting point for a homelab app. The counter file is on a RWO volume, which can only be mounted by one node at a time, so more replicas wouldn't help anyway (they'd each need their own PVC, or a shared-storage backend).
- `serviceAccountName: hello` — ties the pod to the ServiceAccount from step 1. Even though we aren't using it for API access yet, naming it makes the identity explicit and future-proof.
- `securityContext: runAsNonRoot` — the pod runs as UID 1000, not root. This is the same baseline hardening you saw in the Hermes deployment. Not every app image supports non-root at first (some expect to write to root-owned paths), but when it does work, it's a meaningful reduction in blast radius.
- `env` from a `secretKeyRef` — the app gets `GREETING_PREFIX` from the SOPS-encrypted Secret. This is the pattern episode 7 introduced; the Secret is decrypted by Flux at apply time, and the value pops into the pod as a normal environment variable. The app never sees SOPS — it just reads `GREETING_PREFIX`.
- `volumeMounts: /data` — the Longhorn PVC from step 2, mounted at `/data`. The counter file goes here.
- `resources` — small requests and limits. Homelab apps rarely need much; setting limits prevents a runaway process from starving a node. Start conservative and adjust based on what `kubectl top pods` tells you after the app has been running for a day.
- `livenessProbe` + `readinessProbe` — both hit `/healthz`. Liveness tells Kubernetes to restart the pod if the app becomes unresponsive; readiness tells the Service to stop sending traffic until the app is ready. For a simple app, a single `/healthz` endpoint is enough to start.

!!! info "Going further — initContainers and config seeding"
    Real apps often need a one-time setup step before the main container starts: seed a config file if it doesn't exist, run a database migration, or wait for a dependency. That's what an `initContainer` is for. The HomeOps repo's `better-booking-bot` uses a busybox initContainer to seed a config file on its PVC exactly this way. For our hello service, we don't need one — the app can create its counter file on first run — but this is the pattern to reach for when you do.

## Step 6 — the Service

Every app that's reachable needs a Service. This one is a plain ClusterIP:

```yaml
# hello/service.yaml
apiVersion: v1
kind: Service
metadata:
  name: hello
  namespace: hello
spec:
  selector:
    app: hello
  ports:
    - name: http
      port: 80
      targetPort: http
```

- `port: 80` — the Service's port, what other pods and the Ingress talk to.
- `targetPort: http` — the named port from the Deployment's container (`containerPort: 8080`, named `http`). Using a named target port is more robust than a bare number: if you change the container port later, the Service still works as long as the name stays the same.
- No `type: LoadBalancer` or `nodePort` — Traefik will route to this Service through the Ingress. The LAN-only pattern from episode 3 means most of your apps are reached via the Cilium VIP (`192.168.1.0/24` in your setup) through Traefik, not directly via a LoadBalancer IP.

## Step 7 — the Ingress + TLS

This is where the app becomes reachable from outside the cluster. The Ingress tells Traefik: "routes for `hello.example.com` go to the hello Service, and get a TLS certificate from Let's Encrypt."

```yaml
# hello/ingress.yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: hello
  namespace: hello
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
    traefik.ingress.kubernetes.io/router.middlewares: traefik-security-headers@kubernetescrd
spec:
  ingressClassName: traefik
  tls:
    - hosts:
        - hello.example.com
      secretName: hello-tls
  rules:
    - host: hello.example.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: hello
                port:
                  number: 80
```

Key points:

- `cert-manager.io/cluster-issuer: letsencrypt-prod` — the annotation that tells cert-manager to procure a certificate for `hello.example.com` using the production Let's Encrypt issuer you set up in episode 5. The first time this Ingress is applied, cert-manager creates a `Certificate` resource, solves the DNS-01 challenge via Cloudflare, and stores the resulting cert in the `hello-tls` Secret.
- `traefik-security-headers@kubernetescrd` — the Traefik middleware that adds security headers (HSTS, X-Frame-Options, etc.) to responses. This is the same middleware every other app in the series uses, defined once in your Traefik configuration and referenced by name here.
- `ingressClassName: traefik` — tells Kubernetes to hand this Ingress to Traefik's controller, not to any other ingress controller that might be in the cluster.
- `tls.secretName: hello-tls` — the Secret cert-manager creates/renews. You don't create this yourself; cert-manager owns it. If you need to inspect the cert, `kubectl get secret hello-tls -n hello -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -text -noout`.
- `backend.service.name: hello` + `port.number: 80` — matches the Service from step 6.

!!! warning "Wildcard vs per-host certificates"
    Episode 5 used a wildcard certificate for the whole cluster (in your setup, likely `*.yourdomain.com`). That works great when every hostname is under the same domain. If you ever host an app on a completely different domain (say `hello.otherdomain.org`), you'd need a separate `Certificate` + `ClusterIssuer` for that domain — cert-manager can't issue a wildcard for a domain it doesn't control via DNS-01. For this episode, `hello.example.com` falls under the existing wildcard, so the annotation on the Ingress is enough.

## Step 8 — wire it all together with Flux

Now you have the pieces: namespace, ServiceAccount, PVC, ConfigMap, Secret (SOPS-encrypted), Deployment, Service, Ingress. The HomeOps way to apply these is through Flux — put them in a Kustomization that points at your `hello/` directory, and Flux reconciles them.

Create a Kustomization that lists the resources in order:

```yaml
# hello/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - namespace.yaml
  - serviceaccount.yaml
  - configmap.yaml
  - pvc.yaml
  - deployment.yaml
  - service.yaml
  - ingress.yaml
  - secret.sops.yaml
```

Then add this directory to your own Flux Kustomization (or create a new one that depends on your infrastructure configuration, mirroring the layered structure from episode 4). The exact path depends on how you organized your Flux `clusters/` directory, but the pattern is the same: a `path:` that points at your app directory, a `dependsOn:` that ensures the platform is ready first.

Once Flux has reconciled, you can verify each piece:

```bash
kubectl get all -n hello
kubectl get ingress -n hello
kubectl get certificate -n hello
kubectl get pvc -n hello
```

You should see the Deployment with one ready pod, the Service with an endpoint, the Ingress with an address, the Certificate as `Ready=True`, and the PVC as `Bound`.

!!! tip "Watch the certificate provision"
    The first apply is the slowest part — cert-manager has to solve the DNS-01 challenge with Cloudflare, which can take a minute or two. `kubectl get certificate -n hello -w` shows the transition from `Pending` to `Ready=True`. If it stays `Pending` for more than a few minutes, check `kubectl describe certificate hello-tls -n hello` and `kubectl get events -n hello --sort-by='.lastTimestamp'` for the reason.

## Step 9 — a custom metric and the alert chain

The app exposes `/metrics` in Prometheus format. Let's say it exports a gauge `hello_counter_total` that increments each time the greeting is served. Now we can close the loop from episode 9: a real metric → an Alertmanager alert → an ntfy notification.

### The Prometheus-side piece

Add a `PrometheusRule` to your app's directory (or to the monitoring configuration, depending on how your cluster is set up):

```yaml
# hello/prometheusrule.yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: hello-alerts
  namespace: hello
spec:
  groups:
    - name: hello
      rules:
        - alert: HelloHighLatency
          expr: histogram_quantile(0.95, rate(hello_request_duration_seconds_bucket[5m])) > 1
          for: 5m
          labels:
            severity: warning
          annotations:
            summary: "Hello service latency is high"
            description: "95th percentile latency is above 1s for more than 5 minutes."
```

This rule fires if the 95th percentile of the app's request latency exceeds 1 second for 5 minutes. The exact metric and threshold are made-up for the tutorial — replace them with whatever your real app exposes.

### Confirming the chain

To verify the whole alerting pipeline works end to end:

1. **Check the ServiceMonitor** — the kube-prometheus-stack's default ServiceMonitor (or a podMonitor you add) should be scraping the hello Service's `/metrics` port. Confirm with `kubectl get servicemonitor -n monitoring` and `kubectl get podmonitor -n hello` depending on which you use.
2. **Check Prometheus** — in Grafana's Prometheus explore view, run `hello_counter_total` and confirm the series exists and is incrementing.
3. **Fiddle with the threshold** — temporarily lower the alert threshold to something you can trigger (e.g. `> 0`), wait for the `for: 5m` window, and confirm you get an ntfy message. Then set it back to the real value.
4. **Check Alertmanager** — `kubectl logs -n monitoring statefulset/kube-prometheus-stack-alertmanager` (or the specific pod `kubectl logs -n monitoring kube-prometheus-stack-alertmanager-0`) shows the alert being routed to the ntfy receiver you configured in episode 9.

!!! warning "The Alertmanager pod is a StatefulSet, not a Deployment"
    In the kube-prometheus-stack chart, Alertmanager runs as a StatefulSet (`kube-prometheus-stack-alertmanager-0`). When you need to read its logs or exec into it, target the StatefulSet pod by name, not `deploy/...`. A `kubectl logs -n monitoring deploy/kube-prometheus-stack-alertmanager` will fail with "no matches for kind Deployment" — the correct target is `kubectl logs -n monitoring statefulset/kube-prometheus-stack-alertmanager` (or the specific pod `kubectl logs -n monitoring kube-prometheus-stack-alertmanager-0`). This is the same gotcha the monitoring episode reviewer caught: the chart's workload kind matters when you write `kubectl exec`/`logs`/`rollout` commands for a reader to paste.

## Step 10 — what this gives you

At this point you have:

- A real running service, reachable at `hello.example.com` with a valid Let's Encrypt certificate.
- Persistent state on Longhorn that survives pod restarts.
- A Secret (greeting prefix) encrypted in git with SOPS + age, decrypted by Flux at apply time.
- A custom Prometheus metric being scraped, with an Alertmanager rule that can page you via ntfy.
- A clean, reusable directory layout you can copy for the next app.

That's the whole platform in one app. Every layer from episodes 1–10 is now doing something visible.

## Where to go from here

The next episode — [episode 12: is this "production"? Hardening checklist + what HomeOps adds next] — takes a honest look at what you've built, what's still missing, and what "production-grade for a homelab" really means.

!!! info "Going further — the real HomeOps repo"
    The actual HomeOps repo organizes all of this behind a small set of conventions (a Kustomization per app, a `secret.sops.yaml` per app that needs one, a shared Traefik middleware reference, and a three-layer Flux layering). This episode showed the underlying resources directly so you can see what each one does — the repo's structure is just a consistent way to arrange them. You don't need the repo to follow any of these steps; every manifest here is self-contained.

## Recap of the series so far

| Episode | What you built |
|---------|----------------|
| 0 | What's coming: the roadmap and the 3-mini-PC hardware |
| 1 | Hardware + OS baseline: Debian, static IPs, SSH keys, hostnames, `ufw` |
| 2 | Install k3s across 3 nodes with `k3sup` |
| 3 | Cilium CNI + L2 load-balancer VIP |
| 4 | Flux GitOps: `flux bootstrap`, `clusters/` + 3 Kustomization layering |
| 5 | Traefik ingress + cert-manager Let's Encrypt (DNS-01 wildcard) + Reflector |
| 6 | Longhorn distributed storage (HelmRelease + replicated PVC walkthrough) |
| 7 | SOPS + age secrets (age keypair, `.sops.yaml`, `*.sops.yaml`, `sops-age` Secret) |
| 8 | Headscale remote access (self-hosted Tailscale control plane on a VPS + Headplane) |
| 9 | Monitoring: kube-prometheus-stack + one alert → ntfy |
| 10 | Renovate + Reloader + CrowdSec (patching, auto-reload, WAF) |
| 11 | **Deploy a real app end-to-end (capstone)** ← you are here |
| 12 | Is this "production"? Hardening checklist + what HomeOps adds next |

This is part of the Homelab From Scratch (Hands-On Build) series — the previous post was [Keeping it patched & safe: Renovate, Reloader, CrowdSec](/keeping-it-patched--safe-renovate-reloader-crowdsec/).
