---
date: 2026-09-09
description: >
  Automated patching with Renovate, zero-downtime config reloads with Reloader,
  and a community-powered WAF with CrowdSec — the three controllers that keep a
  homelab safe and current without you babysitting it.
categories:
  - Homelab
  - Kubernetes
  - Hands-On Tutorial
tags:
  - renovate
  - reloader
  - crowdsec
  - security
  - gitops
  - homelab
comments: true
series: Homelab From Scratch (Hands-On Build)
---

# Keeping it patched & safe: Renovate, Reloader, CrowdSec

In the last episode we set up monitoring that actually pages you when something goes wrong.
But a cluster that's monitored but not patched is a monitored ticking time bomb — and a
cluster where every config change needs a manual pod restart is one you'll stop making small
improvements on. This episode adds the three controllers that close those gaps: **Renovate**
for automated dependency updates, **Reloader** for zero-downtime config reloads, and **CrowdSec**
as a community-powered WAF that protects your ingress.

This is episode 10 of the *Homelab From Scratch (Hands-On Build)* series. We've already got a
3-node k3s cluster ([episode 2](/install-k3s-across-3-nodes/)), Cilium networking with a LAN
VIP ([episode 3](/networking-with-cilium--a-load-balancer-vip/)), Flux GitOps ([episode 4](/gitops-with-flux-let-git-run-your-cluster/)),
Traefik ingress with free TLS ([episode 5](/ingress--free-tls-traefik--cert-manager/)), Longhorn
storage ([episode 6](/distributed-storage-with-longhorn/)), SOPS+age secrets ([episode 7](/secrets-without-plaintext-sops--age/)),
Headscale remote access ([episode 8](/remote-access-headscale-self-hosted-tailscale/)), and
monitoring that pages you ([episode 9](/monitoring-that-pages-you-prometheus--grafana--ntfy/)).
If you're following along in order, you're ready for this one.

<!-- more -->

## Why these three?

A homelab without automation drifts. Container images go stale, Helm chart versions fall behind,
and config changes that should be seamless require manual `kubectl rollout restart` commands you
forget to run. Meanwhile, anything exposed to the internet — even just your LAN VIP — gets probed
within minutes of going live.

These three controllers address three separate concerns:

1. **Renovate** — wakes up once a day, scans your Helm charts and container images for newer
   versions, and opens a PR per update. You review and merge on your own schedule.
2. **Reloader** — watches for changes to Secrets, ConfigMaps, and other resources, then
   automatically rolls the Deployments and StatefulSets that depend on them. No more manual
   restarts after a cert rotation or a config tweak.
3. **CrowdSec** — a lightweight, community-driven WAF that analyzes traffic patterns and blocks
   malicious IPs using shared threat intelligence. It sits in front of your ingress and quietly
   drops the noise.

## Renovate: automated dependency updates

Renovate is a dependency update bot. You give it a list of repositories and a schedule, and it
opens PRs when it finds newer versions of the things you depend on — container image tags, Helm
chart versions, GitHub Actions versions, even external Helm repositories.

### What we install

We create a dedicated namespace, a HelmRepository so Flux can find the chart, and a HelmRelease
that configures Renovate's behavior:

```yaml
# namespace.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: renovate
```

```yaml
# helmrepository.yaml
apiVersion: source.toolkit.fluxcd.io/v1
kind: HelmRepository
metadata:
  name: renovate
  namespace: renovate
spec:
  interval: 24h
  url: https://docs.renovatebot.com/helm-charts
```

```yaml
# helmrelease.yaml
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: renovate
  namespace: renovate
spec:
  interval: 30m
  chart:
    spec:
      chart: renovate
      version: "46.*"
      sourceRef:
        kind: HelmRepository
        name: renovate
        namespace: renovate
      interval: 24h
  install:
    remediation:
      retries: 3
  upgrade:
    remediation:
      retries: 3
  values:
    serviceAccount:
      create: true
      name: renovate-token-fetcher
    cronjob:
      schedule: "0 2 * * *"
      concurrencyPolicy: Forbid
      successfulJobsHistoryLimit: 3
      failedJobsHistoryLimit: 3
      initContainers:
        - name: fetch-homeops-token
          image: python:3.14-slim
          command: ["python3", "-c"]
          args:
            - |
              import json, os, urllib.request
              with open("/var/run/secrets/kubernetes.io/serviceaccount/token") as f:
                  sa_token = f.read().strip()
              req = urllib.request.Request(
                  "http://github-homeops-broker.github-homeops-broker.svc.cluster.local/v1/token",
                  method="POST",
                  headers={"Authorization": f"Bearer {sa_token}"},
              )
              with urllib.request.urlopen(req, timeout=15) as resp:
                  data = json.load(resp)
              with open("/shared/token", "w") as f:
                  f.write(data["token"])
              os.chmod("/shared/token", 0o644)
          securityContext:
            runAsNonRoot: true
            runAsUser: 10000
            allowPrivilegeEscalation: false
            capabilities:
              drop: ["ALL"]
          volumeMounts:
            - name: shared-token
              mountPath: /shared
      extraVolumes:
        - name: shared-token
          emptyDir: {}
      extraVolumeMounts:
        - name: shared-token
          mountPath: /shared
          readOnly: true
      preCommand: |
        export RENOVATE_TOKEN="$(cat /shared/token)"
    renovate:
      config: |
        {
          "platform": "github",
          "repositories": ["shubhamwagh/homeops"],
          "schedule": ["after 2am and before 4am"],
          "timezone": "Europe/London",
          "automerge": false,
          "dependencyDashboard": true,
          "requireConfig": "optional",
          "semanticCommits": "enabled",
          "separateMajorMinor": true,
          "separateMinorPatch": false,
          "labels": ["dependencies", "renovate"],
          "reviewers": ["shubhamwagh"],
          "flux": {
            "managerFilePatterns": [
              "/(^|/)clusters\\/staging\\/flux-system\\/gotk-components\\.ya?ml$/"
            ]
          },
          "kubernetes": {
            "managerFilePatterns": [
              "/(^|/)apps\\/base\\/.+\\/deployment\\.ya?ml$/",
              "/(^|/)infrastructure\\/base\\/.+\\/deployment\\.ya?ml$/"
            ]
          },
          "helm-values": {
            "managerFilePatterns": [
              "/(^|/)apps\\/base\\/.+\\/helmrelease.*\\.ya?ml$/",
              "/(^|/)infrastructure\\/base\\/.+\\/helmrelease.*\\.ya?ml$/"
            ]
          },
          "packageRules": [
            {
              "matchUpdateTypes": ["patch"],
              "matchCategories": ["infrastructure"],
              "groupName": "Infrastructure - Patch Updates",
              "automerge": false
            },
            {
              "matchUpdateTypes": ["minor"],
              "matchCategories": ["infrastructure"],
              "groupName": "Infrastructure - Minor Updates",
              "automerge": false
            },
            {
              "matchUpdateTypes": ["major"],
              "groupName": "{{depName}} - Major Update",
              "labels": ["major-update", "needs-review"],
              "automerge": false
            },
            {
              "matchPackagePatterns": ["flux", "cert-manager", "traefik", "longhorn"],
              "labels": ["critical-infrastructure"],
              "automerge": false
            },
            {
              "matchDatasources": ["docker"],
              "versioning": "docker"
            },
            {
              "matchDatasources": ["helm"],
              "versioning": "helm"
            }
          ]
        }
    resources:
      requests:
        cpu: 200m
        memory: 512Mi
      limits:
        cpu: 1000m
        memory: 1Gi
```

That's a lot of YAML — let's walk through what matters.

### The token problem (and how we solve it)

Renovate needs a GitHub token to open PRs. The naive approach is to paste a personal access
token into a Secret and wire it into the Deployment. That works — until you realize it also
means every Renovate PR is authored under your personal account. With branch protection enabled
(PR required, 1 approval required, build check required), a PR you author yourself can never be
approved, because GitHub blocks self-approval. Every Renovate PR would sit forever in the queue
waiting for a second human who doesn't exist.

The fix: a dedicated identity. Renovate runs under its own Kubernetes ServiceAccount
(`renovate-token-fetcher`), and that ServiceAccount talks to an internal token broker
(`github-homeops-broker`) that mints a fresh, short-lived GitHub App installation token per run.
The token is written to an `emptyDir` volume shared between the init container and the main
Renovate container, exported as `RENOVATE_TOKEN` before Renovate starts, and expires in about an
hour regardless. No static credential in a Secret, no PRs under a personal account.

This is the same pattern behind the [credential-protection approach from the SOPS + age episode](/secrets-without-plaintext-sops--age/) — a dedicated ServiceAccount identity checked by the broker's TokenReview allowlist, not a shared default SA.

### What Renovate actually scans

The `renovate.config` block tells Renovate where to look and what to do:

- **Repositories**: `["shubhamwagh/homeops"]` — one repo for now. Renovate scans every
  `deployment.yaml` for container image tags, every `helmrelease.yaml` for chart version ranges,
  and every Flux `gotk-components.yaml` for the Flux version.
- **Schedule**: `["after 2am and before 4am"]` in `Europe/London` — runs once per night, outside
  waking hours.
- **`automerge: false`** — Renovate never merges on its own. Every PR is yours to review.
- **`separateMajorMinor: true`** — minor and patch updates are grouped separately so a cluster of
  patch updates doesn't hide a minor bump in the noise.
- **`packageRules`** — this is where you encode your risk tolerance:

  - Infrastructure patch and minor updates get their own group names but still don't auto-merge —
    they're reviewed like everything else, just grouped for readability.
  - Major updates get a `major-update` + `needs-review` label so they're easy to spot in the PR
    list.
  - The packages `flux`, `cert-manager`, `traefik`, and `longhorn` get a `critical-infrastructure`
    label — these are the components that, if upgraded without care, can take down the whole cluster.
  - Docker images use Docker versioning, Helm charts use Helm versioning — Renovate knows how to
    compare semver for each.

### Applying it

Create these three YAML files in your own workspace — you don't need the HomeOps repo for this. Pick a directory, create each file, then apply them with `kubectl`:

```bash
# Apply the three YAML files (namespace + HelmRepository + HelmRelease)
kubectl apply -f namespace.yaml
kubectl apply -f helmrepository.yaml
kubectl apply -f helmrelease.yaml
```

Or, if you're using Flux to manage everything as we've been doing since [episode 4](/gitops-with-flux-let-git-run-your-cluster/):

```bash
flux reconcile kustomization infrastructure -n flux-system
```

### What you'll see

Within a day, Renovate will open a PR in `shubhamwagh/homeops` per update it finds. Each PR has a
description explaining what changed, the changelog link, and the release notes. You review,
comment, approve, and merge — on your schedule, with full context.

!!! tip "Reading a Renovate PR"
    Renovate PRs follow a consistent format: a title like `chore(deps): update
    ghcr.io/tale/headplane docker tag to v0.7.1`, a body with the change summary, a
    compatibility score, and links to the changelog. Read the body first — it tells you
    whether the update is a patch (almost always safe), a minor (usually safe, read the
    notes), or a major (read carefully, may need config changes).

## Reloader: zero-downtime config reloads

Every time you change a Secret or ConfigMap that a Deployment consumes, the pods need to restart to
pick up the new value. Without Reloader, that's a manual `kubectl rollout restart` — easy to forget,
especially for Secrets you rarely touch (like a rotated TLS cert or a freshly generated age key).

Reloader watches for changes to Secrets, ConfigMaps, and workload definitions, then automatically
triggers a rolling restart of the Deployments and StatefulSets that depend on them. It uses a
annotation-based model: you mark a workload with `reloader.stakater.com/auto: "true"` and Reloader
handles the rest.

### What we install

```yaml
# namespace.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: reloader
```

```yaml
# helmrepository.yaml
apiVersion: source.toolkit.fluxcd.io/v1
kind: HelmRepository
metadata:
  name: stakater
  namespace: reloader
spec:
  interval: 24h
  url: https://stakater.github.io/stakater-charts
```

```yaml
# helmrelease.yaml
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: reloader
  namespace: reloader
spec:
  interval: 30m
  chart:
    spec:
      chart: reloader
      version: "1.2.*"
      sourceRef:
        kind: HelmRepository
        name: stakater
        namespace: reloader
      interval: 24h
  install:
    remediation:
      retries: 3
  upgrade:
    remediation:
      retries: 3
  values:
    reloader:
      watchGlobally: true
```

`watchGlobally: true` tells Reloader to watch all namespaces, not just its own. That's what you
want in a small cluster — one Reloader instance watching everything, rather than per-namespace
instances. In a larger cluster you might restrict it, but for a homelab the simplicity wins.

### How it works in practice

Once Reloader is running, any Deployment annotated with:

```yaml
metadata:
  annotations:
    reloader.stakater.com/auto: "true"
```

will be automatically restarted when any Secret or ConfigMap it references changes. Reloader does a
rolling restart — it doesn't kill all pods at once. Your service stays available during the update.

!!! warning "Reloader restarts, it doesn't know your readiness probes"
    Reloader triggers a rolling restart, which respects your Deployment's `strategy` and
    `readinessProbe` settings — but it doesn't know whether your app handles a config change
    gracefully mid-request. If you have a workload that can't tolerate a restart at an arbitrary
    moment, don't annotate it. Restart it manually at a quiet time instead.

## CrowdSec: community-powered WAF

CrowdSec is an open-source, community-driven intrusion prevention system. It analyzes logs from your
services, detects malicious behavior patterns, and blocks offending IPs. The blocking decisions are
informed by the CrowdSec community blocklist — when one CrowdSec user detects an attack from an IP,
that IP gets added to the shared blocklist and every other CrowdSec user benefits.

For a homelab, CrowdSec sits in front of your Traefik ingress and quietly drops the noise: scanner
probes, known-bad IPs, and common attack patterns. It's not a replacement for good security hygiene
(least-privilege RBAC, no exposed admin interfaces, kept-up-to-date images) — it's a second layer
that absorbs the background radiation of the internet.

### Architecture

CrowdSec runs two components in the cluster:

- **LAPI (Local API)** — a Deployment that stores the decision database (what IPs are blocked, what
  scenarios have triggered) and exposes an API the agents query. We use SQLite for the database
  (backed by a PersistentVolume) since a homelab doesn't need the scalability of PostgreSQL.
- **Agent** — a DaemonSet that runs on every node, acquires logs from the services you configure
  (in our case, Traefik), and consults the LAPI to decide whether to block.

The agent acquires Traefik logs via the `acquisition` block — it watches the Traefik pod's log
output and applies the scenarios defined in the `COLLECTIONS` environment variable. The scenarios
we start with are:

- `crowdsecurity/traefik` — Traefik-specific patterns (bad user agents, unusual paths, rate-limit
  violations)
- `crowdsecurity/http-cve` — known HTTP-based CVEs and exploit patterns
- `crowdsecurity/base-http-scenarios` — base HTTP attack patterns (scanner detection, brute-force
  patterns)

### What we install

```yaml
# namespace.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: crowdsec
```

```yaml
# helmrepository.yaml
apiVersion: source.toolkit.fluxcd.io/v1
kind: HelmRepository
metadata:
  name: crowdsec
  namespace: crowdsec
spec:
  interval: 1h
  url: https://crowdsecurity.github.io/helm-charts
```

```yaml
# helmrelease.yaml
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: crowdsec
  namespace: crowdsec
spec:
  interval: 30m
  chart:
    spec:
      chart: crowdsec
      version: "0.12.x"
      sourceRef:
        kind: HelmRepository
        name: crowdsec
        namespace: crowdsec
  values:
    lapi:
      replicas: 1
      persistentVolume:
        enabled: true
      database:
        type: sqlite
      resources:
        requests:
          cpu: 500m
          memory: 512Mi
        limits:
          cpu: 1000m
          memory: 1Gi
      metrics:
        enabled: true
        serviceMonitor:
          enabled: true
          namespace: monitoring
          interval: 30s
      env:
        - name: TZ
          value: "UTC"
      strategy:
        type: Recreate
    agent:
      enabled: true
      kind: DaemonSet
      resources:
        requests:
          cpu: 100m
          memory: 200Mi
        limits:
          cpu: 200m
          memory: 400Mi
      acquisition:
        - namespace: traefik
          podName: "*"
          program: traefik
      env:
        - name: TZ
          value: "UTC"
        - name: COLLECTIONS
          value: "crowdsecurity/traefik crowdsecurity/http-cve crowdsecurity/base-http-scenarios"
      metrics:
        enabled: true
        serviceMonitor:
          enabled: true
          namespace: monitoring
          interval: 30s
    dashboard:
      enabled: false
    tls:
      enabled: false
```

A few notes on the configuration:

- **LAPI persistent volume**: the decision database (blocked IPs, scenario state) is persisted. If
  the LAPI pod restarts, it doesn't lose its blocklist. The `strategy: Recreate` is because the Helm
  chart uses a PVC that can't be shared across replicas — with `replicas: 1` and Recreate, a
  restart reattaches the same volume.
- **Agent as DaemonSet**: runs one agent per node. Each agent acquires logs from the Traefik pod in
  the `traefik` namespace. The `podName: "*"` matches any pod name in that namespace — useful if
  you rename or rescale Traefik later.
- **Dashboard disabled**: the CrowdSec dashboard is a separate web UI. For a homelab, the
  Grafana dashboards ([episode 9](/monitoring-that-pages-you-prometheus--grafana--ntfy/)) give you
  enough visibility into what CrowdSec is doing via the ServiceMonitor metrics.
- **TLS disabled**: the LAPI and agent communicate over the cluster's internal network. No need for
  mTLS inside the cluster — the network is already segmented by Cilium ([episode 3](/networking-with-cilium--a-load-balancer-vip/)).

### ServiceMonitor: seeing CrowdSec in Grafana

CrowdSec exposes Prometheus metrics from both the LAPI and the agent. We create two
ServiceMonitors so the Prometheus stack from [episode 9](/monitoring-that-pages-you-prometheus--grafana--ntfy/)
can scrape them:

```yaml
# servicemonitor.yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: crowdsec-lapi
  namespace: monitoring
  labels:
    app: crowdsec
    release: kube-prometheus-stack
spec:
  namespaceSelector:
    matchNames:
      - crowdsec
  selector:
    matchLabels:
      app: crowdsec-service
  endpoints:
    - port: metrics
      interval: 30s
      path: /metrics
---
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: crowdsec-agent
  namespace: monitoring
  labels:
    app: crowdsec
    release: kube-prometheus-stack
spec:
  namespaceSelector:
    matchNames:
      - crowdsec
  selector:
    matchLabels:
      app: crowdsec-agent-service
  endpoints:
    - port: metrics
      interval: 30s
      path: /metrics
```

Both ServiceMonitors target the `kube-prometheus-stack` release (the label tells Prometheus which
scrape config to use) and scrape the `/metrics` endpoint on the CrowdSec services every 30 seconds.
Once applied, you'll see CrowdSec metrics in your Grafana instance — blocked IPs over time, scenario
triggers, and agent health.

### What CrowdSec actually blocks

CrowdSec doesn't block everything — it blocks what the community blocklist and your configured
scenarios flag as malicious. In practice, within the first few hours of running in front of a
publicly reachable ingress, you'll see it block:

- Known scanner IPs (the kind that probe every port and path on a new IP)
- CVE exploit attempts against common web frameworks
- Brute-force patterns against any exposed login endpoints
- Rate-limit violators (clients hitting your API too fast)

The blocklist is dynamic — CrowdSec pulls updates from the community API regularly, so new threats
are added without you doing anything.

!!! warning "CrowdSec is a complement, not a substitute"
    CrowdSec blocks known-bad traffic based on patterns and community intelligence. It does not
    replace: keeping your images patched (Renovate's job), least-privilege RBAC, removing exposed
    admin interfaces, or network segmentation. Think of it as the guy at the door checking IDs
    against a watchlist — useful, but the building still needs good locks.

## Putting it all together

Once all three are running, your cluster gains three automation layers that work silently in the
background:

- **Renovate** wakes up at 2am London time, scans for updates, and opens PRs. You review the next
  day.
- **Reloader** watches for config changes and rolls pods automatically. You change a Secret or
  ConfigMap and don't think about restarting anything.
- **CrowdSec** absorbs malicious traffic at the ingress, pulling from the community blocklist and
  logging what it blocks to Grafana.

None of these require daily attention. They're the "set up once, benefit forever" layer of the
homelab.

## What's next

The next episode is the capstone: we deploy a real application end-to-end, wiring together
everything we've built so far — a namespace, a Deployment, a Service, an Ingress with TLS,
a PersistentVolumeClaim, a SOPS-encrypted Secret, and the monitoring we set up in [episode 9](/monitoring-that-pages-you-prometheus--grafana--ntfy/).
That's [episode 11: Deploy a real app end-to-end (capstone)] — the link will go live once it's published.

## Acknowledgments

This episode draws on the real HomeOps configuration for Renovate (including the dedicated
`renovate-token-fetcher` ServiceAccount pattern and the `github-homeops-broker` token flow),
Stakater Reloader, and CrowdSec. The specific HelmRelease values, acquisition configs, and
ServiceMonitor setup are adapted from the real HomeOps configuration for Renovate, Reloader, and
CrowdSec.
