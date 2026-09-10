---
date: 2026-09-10
description: The capstone episode — deploy a real app end-to-end on your homelab, from namespace to TLS-terminated ingress, using every component you've built so far.
categories:
  - Homelab
  - Kubernetes
  - Hands-On Tutorial
tags:
  - homelab
  - kubernetes
  - deployment
  - ingress
  - longhorn
  - secrets
  - capstone
comments: true
series: Homelab From Scratch (Hands-On Build)
---

# Deploy a real app end-to-end (capstone)

You've built the stack. Now let's use it.

This is the capstone episode of the **Homelab From Scratch (Hands-On Build)** series. Every previous episode taught you one piece; here you'll thread them all together. We'll deploy a small real application — a personal dashboard that reads some config, stores a bit of state on persistent storage, and is reachable over HTTPS from anywhere on your tailnet — and walk through every Kubernetes object it needs, in the order Flux would apply them.

If you've been following along, you can paste these snippets directly. If you haven't, this episode is still a useful standalone reference for "what does a complete app look like in Kubernetes, anyway?"

<!-- more -->

## What we're building

We'll deploy a tiny personal app called **hello-app** — a single-container web service that:

- Serves a small HTML page on port 8080
- Reads a `GREETING` setting from a ConfigMap
- Stores a page-view counter in a file on a Longhorn persistent volume
- Is reachable at `hello-app.example.com` over HTTPS (TLS from Let's Encrypt, terminated at Traefik)
- Has its secrets (a basic-auth password for the dashboard) stored encrypted via SOPS + age

Nothing fancy — that's the point. The value is in seeing the _shape_ of a real deployment, not the complexity of the app itself. You can swap in anything with a Docker image later.

## Prerequisites

You should have completed (at least) episodes 1–10 of this series:

- **Ep1** — your nodes are running Debian with static IPs and SSH
- **Ep2** — k3s is installed across your nodes
- **Ep3** — Cilium is your CNI, with a load-balancer VIP on the LAN
- **Ep4** — Flux is reconciling your cluster from git
- **Ep5** — Traefik is your ingress, cert-manager has a working Let's Encrypt issuer
- **Ep6** — Longhorn is providing replicated storage
- **Ep7** — SOPS + age is encrypting your secrets
- **Ep8** — Headscale gives you tailnet access from anywhere
- **Ep9** — Prometheus + Grafana + ntfy is monitoring the cluster
- **Ep10** — Renovate, Reloader, and CrowdSec are keeping things patched and safe

If any of those are missing, the snippets below won't fully work — but reading them will still show you how the pieces fit.

## The shape of a Kubernetes app

Every app in your cluster — no matter how large — is just a handful of Kubernetes objects working together. For a typical web service you need:

1. A **Namespace** — a home for the app's objects
2. A **ConfigMap** (optional) — non-secret configuration
3. A **Secret** (optional) — secret configuration, encrypted with SOPS
4. One or more **PersistentVolumeClaims** (optional) — durable storage via Longhorn
5. A **Deployment** — the actual running containers
6. A **Service** — a stable network endpoint for the pods
7. An **Ingress** — external HTTP routing + TLS, via Traefik + cert-manager

That's it. The rest is detail. Let's build them one at a time.

## Step 1: the namespace

Start with a home. Create a file called `namespace.yaml`:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: hello-app
```

That's the whole file. Kubernetes namespaces are just named containers for other objects — no spec, no magic. Apply it once and everything else below goes inside it.

```bash
kubectl apply -f namespace.yaml
```

You should see `namespace/hello-app created`. If you've already bootstrapped Flux (episode 4), you'd commit this to your GitOps repo instead and let Flux apply it — but for this walkthrough we'll apply directly so you can see each piece land. In a real GitOps flow every file below lives in `apps/base/hello-app/` and gets reconciled by Flux.

## Step 2: configuration via ConfigMap

Apps need settings. Non-secret ones live in a ConfigMap — a plain dictionary Kubernetes injects into pods as environment variables or files.

For hello-app we want a configurable greeting message. Create `configmap.yaml`:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: hello-app-config
  namespace: hello-app
data:
  GREETING: "Hello from your homelab!"
```

Two things to notice:

- The `namespace` field is explicit here. You can also omit it and `kubectl apply -n hello-app -f ...` instead — both work, but being explicit in the file is friendlier to GitOps (no implicit context).
- The value is a plain string. If you later want to change it, edit the file, apply again, and — if you've set up Reloader (episode 10) — your pods will restart automatically to pick up the new value.

Create it:

```bash
kubectl apply -f configmap.yaml
```

## Step 3: secrets via SOPS + age

Secret configuration — passwords, API keys, tokens — should never be committed as plaintext. In this series you set up SOPS + age in episode 7, which means you can write a `secret.sops.yaml` file that looks normal but is encrypted on disk.

For hello-app we want a basic-auth password for the dashboard. Create `secret.sops.yaml`:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: hello-app-secret
  namespace: hello-app
type: Opaque
stringData:
  DASHBOARD_PASSWORD: "pick-a-good-password-here"
```

Two important notes:

- **`stringData`, not `data`.** `stringData` lets you write plaintext and Kubernetes base64-encodes it for you at apply time. `data` expects already-base64-encoded values. Use `stringData` — it's easier to read and less error-prone.
- **This file is encrypted with SOPS before you commit it.** The snippet above shows what the _decrypted_ content looks like. In your real repo you'd run `sops -e secret.sops.yaml > secret.sops.yaml` (or your editor's SOPS integration) so the committed file contains `ENC[...]` ciphertext and the age recipient header. Flux decrypts it at deploy time using the `sops-age` Secret you created in episode 7.

The `DASHBOARD_PASSWORD` value above is a placeholder. Pick your own. And never commit the plaintext version to git — only the SOPS-encrypted file.

```bash
kubectl apply -f secret.sops.yaml
```

This works because you applied it directly (decrypted in memory). In the GitOps path, Flux does the decrypt for you.

## Step 4: persistent storage via Longhorn

If your app needs to keep data across restarts — a database file, uploaded content, a counter — you need a PersistentVolumeClaim (PVC). Longhorn (episode 6) provisions replicated storage backed by your nodes' disks.

For hello-app we want a small volume to store a page-view counter file. Create `pvc.yaml`:

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: hello-app-data
  namespace: hello-app
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: longhorn
  resources:
    requests:
      storage: 1Gi
```

Key fields:

- **`accessModes: [ReadWriteOnce]`** — the volume can be mounted read-write by a single node at a time. That's what most single-replica apps want. (Longhorn also supports `ReadWriteMany` for multi-node shared access, but that's slower and rarely needed for a single pod.)
- **`storageClassName: longhorn`** — tells Kubernetes to ask Longhorn for the volume, not the default local-path provisioner. If you haven't installed Longhorn, this PVC will stay pending forever — make sure episode 6 is done first.
- **`storage: 1Gi`** — start small. You can expand it later (Longhorn supports online expansion).

Create it:

```bash
kubectl apply -f pvc.yaml
```

Watch it bind:

```bash
kubectl get pvc -n hello-app
```

You should see `hello-app-data` in `Bound` state within a few seconds. If it says `Pending`, something's wrong — usually Longhorn isn't installed or there's no storage available on the nodes.

## Step 5: the Deployment

Now the actual workhorse — the Deployment. This is the object that describes your running application: which image, how many copies, what configuration to inject, what storage to mount.

Create `deployment.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: hello-app
  namespace: hello-app
  annotations:
    reloader.stakater.com/auto: "true"
spec:
  replicas: 1
  selector:
    matchLabels:
      app: hello-app
  template:
    metadata:
      labels:
        app: hello-app
    spec:
      containers:
        - name: hello-app
          image: ghcr.io/yourname/hello-app:latest
          ports:
            - containerPort: 8080
          envFrom:
            - configMapRef:
                name: hello-app-config
            - secretRef:
                name: hello-app-secret
          volumeMounts:
            - name: data
              mountPath: /data
          resources:
            requests:
              cpu: 50m
              memory: 64Mi
            limits:
              cpu: 500m
              memory: 256Mi
      volumes:
        - name: data
          persistentVolumeClaim:
            claimName: hello-app-data
```

Let's walk through the interesting parts:

**`reloader.stakater.com/auto: "true"`** — if you installed Reloader (episode 10), this annotation tells it to restart your pods whenever the referenced ConfigMap or Secret changes. Without it, pods keep the old values until you manually restart them. If you haven't installed Reloader yet, the pods still work — they just won't auto-restart on config changes.

**`envFrom` with `configMapRef` and `secretRef`** — this injects every key from the ConfigMap and Secret as environment variables into the container. So `$GREETING` will be `"Hello from your homelab!"` and `$DASHBOARD_PASSWORD` will be your password. The app code reads them at startup.

**`volumeMounts` + `volumes`** — this mounts the PVC at `/data` inside the container. The app can read and write files there, and they survive pod restarts because Longhorn keeps the data on disk.

**`resources`** — always set requests and limits. Requests tell the scheduler how much to reserve (a pod won't be placed on a node without enough uncommitted capacity); limits cap what the container can use (exceeding them triggers throttling or OOM-killing). For a tiny app like this, 50m/64Mi requests and 500m/256Mi limits are reasonable. Adjust for your actual app's needs — undershooting causes random restarts, overshooting wastes capacity across your whole cluster.

**`replicas: 1`** — one copy. For a personal app that's fine. If you wanted high availability you'd run more and use a `ReadWriteMany` PVC (or a database that handles replication itself). That's a later-level decision.

Applied:

```bash
kubectl apply -f deployment.yaml
```

Watch it start:

```bash
kubectl get pods -n hello-app -w
```

You should see `hello-app-xxxxx` move from `ContainerCreating` to `Running`. If it stays `ContainerCreating` or goes `CrashLoopBackOff`, something's wrong with the image name, the PVC binding, or the app itself. `kubectl logs -n hello-app deploy/hello-app` will usually tell you why.

## Step 6: the Service

Pods get ephemeral IPs that change every restart. A Service gives your app a stable network name inside the cluster that survives pod churn.

Create `service.yaml`:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: hello-app
  namespace: hello-app
spec:
  selector:
    app: hello-app
  ports:
    - port: 80
      targetPort: 8080
```

Two fields matter:

- **`selector: app: hello-app`** — matches the pods from your Deployment (they have `app: hello-app` labels). The Service forwards traffic to whichever pods match.
- **`port: 80` → `targetPort: 8080`** — external callers hit port 80 on the Service; Kubernetes forwards to port 8080 on the pod (where your container is listening). You can pick any port numbers here — `port` is the Service's port, `targetPort` is the container's port. They don't have to match.

Create it:

```bash
kubectl apply -f service.yaml
```

Inside the cluster, other pods can now reach your app at `hello-app.hello-app.svc.cluster.local:80`. You don't need this for the Ingress (which can target the Deployment directly via the pod IP), but it's the standard pattern — Ingresses point at Services, not pods, because Services are stable.

## Step 7: the Ingress — external access + TLS

Now the part that makes your app reachable from outside the cluster over HTTPS. The Ingress tells Traefik (episode 5) to route traffic for a specific hostname to your Service, and asks cert-manager to get a TLS certificate from Let's Encrypt.

Create `ingress.yaml`:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: hello-app
  namespace: hello-app
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
    traefik.ingress.kubernetes.io/router.middlewares: traefik-security-headers@kubernetescrd
spec:
  ingressClassName: traefik
  tls:
    - hosts:
        - hello-app.example.com
      secretName: hello-app-tls
  rules:
    - host: hello-app.example.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: hello-app
                port:
                  number: 80
```

Let's unpack this:

**`cert-manager.io/cluster-issuer: letsencrypt-prod`** — tells cert-manager to acquire a certificate for this host from the `letsencrypt-prod` ClusterIssuer you set up in episode 5. cert-manager watches Ingress objects, sees this annotation, and creates a Certificate + Order + Challenge flow automatically. Within a few minutes you'll have a real Let's Encrypt certificate.

**`traefik.ingress.kubernetes.io/router.middlewares: traefik-security-headers@kubernetescrd`** — attaches Traefik's security-headers middleware (the same one every other app in your cluster uses). This sets headers like `X-Frame-Options`, `X-Content-Type-Options`, and `Content-Security-Policy`. You set this up in episode 5; if you skipped it, remove this annotation and your app still works, just without the extra headers.

**`ingressClassName: traefik`** — tells Kubernetes which Ingress controller should handle this. With Cilium (episode 3) you might have multiple, so being explicit matters.

**`tls.hosts` + `tls.secretName`** — the hostnames to secure and the name of the Secret cert-manager will populate with the certificate. cert-manager creates this Secret for you — you don't create it yourself.

**`rules.host` + `backend`** — the routing rule: any HTTP request with `Host: hello-app.example.com` gets forwarded to the `hello-app` Service on port 80.

Create it:

```bash
kubectl apply -f ingress.yaml
```

Now wait for the certificate. Watch it:

```bash
kubectl get certificate -n hello-app
kubectl get challenge -n hello-app
```

`kubectl get certificate` should show `hello-app-tls` in `Ready` state within a few minutes (Let's Encrypt needs to verify you control the domain, which means DNS for `hello-app.example.com` must point to your Traefik load-balancer IP — see the "Before you try this yourself" notes below). `kubectl get challenge` shows the DNS-01 or HTTP-01 challenge in progress; when it disappears and the Certificate is `Ready`, you have TLS.

Test it:

```bash
curl -sk https://hello-app.example.com/
```

You should get your app's response over HTTPS. The `-k` skips certificate verification while you're testing — once cert-manager has issued the cert, you can drop it.

## Step 8: what the whole thing looks like together

Here's the complete file list for hello-app, in the order you'd apply them (or the order Flux would reconcile them, if you put them under `apps/base/hello-app/`):

```
hello-app/
├── namespace.yaml
├── configmap.yaml
├── secret.sops.yaml        (encrypted with SOPS)
├── pvc.yaml
├── deployment.yaml
├── service.yaml
└── ingress.yaml
```

And here's how they connect:

```mermaid
flowchart LR
    subgraph "hello-app namespace"
        Ingress[Ingress<br/>hello-app.example.com<br/>TLS + security headers]
        Service[Service<br/>port 80 → 8080]
        Deployment[Deployment<br/>hello-app pod]
        ConfigMap[ConfigMap<br/>GREETING]
        Secret[Secret<br/>DASHBOARD_PASSWORD<br/>(SOPS-encrypted)]
        PVC[PVC<br/>hello-app-data<br/>Longhorn 1Gi]
    end

    Ingress -->|routes to| Service
    Service -->|selects| Deployment
    Deployment -->|reads env| ConfigMap
    Deployment -->|reads env| Secret
    Deployment -->|mounts /data| PVC

    CertManager[cert-manager] -.->|issues cert for| Ingress
    Traefik[Traefik] -->|terminates TLS| Ingress
    Longhorn[Longhorn] -.->|provisions volume| PVC

    subgraph "outside the cluster"
        User((you)) -->|https://hello-app.example.com| Traefik
    end

    style Ingress fill:#f9f,stroke:#333
    style Deployment fill:#bbf,stroke:#333
    style PVC fill:#bfb,stroke:#333
    style Secret fill:#fbb,stroke:#333
```

Every arrow is a real Kubernetes relationship: label selectors, volume mounts, environment references, or TLS annotations. Nothing here is magic — it's all explicit connections you wrote in the YAML.

## Before you try this yourself

A few things you need in place before this will actually work end-to-end:

- **DNS for your domain.** `hello-app.example.com` must resolve to your Traefik load-balancer IP (the Cilium L2 VIP from episode 3, e.g. `192.168.1.2`). If you're using the LAN-only pattern (episode 5), that IP is only reachable from your LAN or tailnet, and Let's Encrypt's HTTP-01 challenge won't work from the public internet. For a publicly-reachable app you'd use DNS-01 (Cloudflare, as episode 5 set up) or run the challenge from inside your network. For a tailnet-only app, you don't need public TLS at all — you can use Traefik's self-signed cert or skip TLS behind Headscale.

- **A container image.** The snippet uses `ghcr.io/yourname/hello-app:latest` as a placeholder. Replace it with a real image you've built and pushed — or use a public one for testing. If the image doesn't exist, the pod will stay `ImagePullBackOff` forever.

- **Longhorn installed.** The PVC won't bind without it. Check with `kubectl get storageclass longhorn` — if it's missing, finish episode 6 first.

- **cert-manager + a working ClusterIssuer.** If `letsencrypt-prod` doesn't exist, the Ingress annotation is ignored and no certificate is issued. Check with `kubectl get clusterissuer letsencrypt-prod`.

- **SOPS + age set up for Flux (if using GitOps).** If you're applying directly with `kubectl` (as this walkthrough shows), you apply the decrypted Secret. If you're committing to your Flux repo, the `secret.sops.yaml` must be encrypted and Flux must have the `sops-age` Secret (episode 7). Applying an encrypted file directly with `kubectl` won't work — `kubectl` doesn't know how to decrypt SOPS.

## What you just built

That's a complete, production-shaped application in Kubernetes. Not production-grade in the enterprise sense — no horizontal scaling, no database replication, no multi-region — but production-shaped in the homelab sense: a named namespace, explicit configuration, encrypted secrets, durable storage, resource limits, TLS-terminated external access, and monitoring (the next time something goes wrong, your Prometheus alert from episode 9 will fire).

The same pattern — Namespace → ConfigMap → Secret → PVC → Deployment → Service → Ingress — repeats for every app in your cluster. The homepage dashboard (episode 0's screenshot), TREK, Mailpit, Umami, Hermes Agent, all of them are instances of this exact shape, just with more or fewer pieces. Once you've built one, you've built them all.

## Where to go from here

You now have a working homelab that does real things. A few natural next steps, in roughly this order:

- **Add more apps** using the pattern above. The Hello-app skeleton is a template — copy it, change the names, swap the image.
- **Add monitoring for your app.** Episode 9 set up cluster-level monitoring, but your app can expose Prometheus metrics too. Add a `/metrics` endpoint, create a ServiceMonitor, and watch your app's requests in Grafana.
- **Back up your Longhorn volumes.** Longhorn has built-in backup to an S3-compatible bucket. Set it up before you rely on any app's data — not after.
- **Run a restore drill.** Backups you haven't tested restoring are hopes, not plans. Pick a PVC, delete it, restore from backup, and verify the app still works. That's the only way to know your backups are real.
- **Harden what you have.** The next and final episode of this series walks through a hardening checklist — read-only root filesystems, dropped capabilities, network policies, pod security standards — and what "production" actually means for a homelab.

## Series navigation

- **Previous:** [episode 10: Keeping it patched & safe: Renovate, Reloader, CrowdSec](/keeping-it-patched--safe-renovate-reloader-crowdsec/)
- **Next:** [episode 12: Is this "production"? Hardening checklist + what HomeOps adds next]

This is episode 11 of the **Homelab From Scratch (Hands-On Build)** series — the capstone. The final episode wraps up with a hardening checklist and an honest look at what "production" means for a homelab.
