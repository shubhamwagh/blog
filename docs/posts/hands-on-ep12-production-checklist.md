---
date: 2026-09-13
description: An honest look at what you've built across 12 episodes — what's genuinely production-grade, what's still missing, and what "production for a homelab" really means.
categories:
  - Homelab
  - Kubernetes
  - Hands-On Tutorial
  - Homelab Journal
tags:
  - homelab
  - kubernetes
  - hardening
  - production
comments: true
series: Homelab From Scratch (Hands-On Build)
---

# Is this "production"? Hardening checklist + what HomeOps adds next

You've built a real Kubernetes cluster from scratch. Three mini PCs, a CNI with a load-balancer VIP, GitOps driving every change, wildcard TLS from Let's Encrypt, replicated block storage, encrypted secrets, remote VPN access, monitoring that actually pages you, automated dependency patching, a WAF, and a real application deployed end-to-end through every layer. That's not nothing.

So — is it "production"?

The honest answer is: it depends on what you mean by production. This post walks through what you actually have, what's still missing, and where the line sits between "production for a homelab" and "production for a business." It also closes out the series with a hardening checklist you can run through, and a look at what the real HomeOps repo adds on top of what you've built here.

!!! info "What this episode covers"
    A walk through the 12-episode build, an honest production-grade assessment with explicit limits, a hardening checklist you can run today, and what HomeOps adds beyond the simplified snippets in this series.

<!-- more -->

## What you've actually built

Across the last 11 episodes you installed:

- **k3s across 3 nodes** — one control-plane, two workers, all on cheap mini PCs (via `k3sup` over SSH, the real underlying commands behind whatever wrapper your own setup uses).
- **Cilium as the CNI** with an L2 load-balancer VIP so services get a stable LAN IP that survives pod restarts.
- **Flux GitOps** — three layered Kustomizations (`infrastructure` → `infrastructure-config` → `apps`), every cluster change driven by a git push, SOPS-encrypted secrets decrypted at apply time.
- **Traefik ingress** with **cert-manager** issuing a Let's Encrypt wildcard certificate via Cloudflare DNS-01, plus Reflector syncing the cert across namespaces.
- **Longhorn** for distributed replicated storage — three replicas, one per node, so a node loss doesn't lose your data.
- **SOPS + age** so secrets live in git encrypted, never plaintext — the `sops-age` Secret in the cluster is the only private key, and it never leaves the cluster.
- **Headscale** — a self-hosted Tailscale control plane on an Oracle Free Tier VPS, giving you WireGuard-based remote access to the whole LAN without opening a single port on your router.
- **kube-prometheus-stack** (Prometheus, Alertmanager, Grafana) with one real alert routed to ntfy so a disk-pressure event actually wakes you up.
- **Renovate** opening daily PRs for outdated Helm charts, **Reloader** restarting workloads when their configmap/secret changes, and **CrowdSec** reading Traefik's access logs for abusive patterns.
- **A real application** deployed end-to-end: namespace, Deployment, Service, Ingress with TLS, PersistentVolumeClaim, a SOPS-encrypted Secret, and Grafana dashboards watching it.

That's the full stack. Every component is real, every command you ran was copy-pasteable, and the cluster is doing actual work.

## What "production-grade" means here — and where it stops

When I say this homelab is "production-grade," I mean something specific and limited:

- **Three nodes** with replicated storage and a CNI that gives services a stable VIP.
- **GitOps** so the cluster's desired state is in git, auditable, and recoverable by re-syncing.
- **TLS everywhere** on the ingress path, issued and renewed automatically.
- **Secrets encrypted at rest in git**, decrypted only inside the cluster.
- **Monitoring + alerting** that can page you, not just dashboards you stare at.
- **Remote access** without exposing ports on your router.
- **Automated patching** via Renovate so dependency updates don't sit forgotten.
- **A deployed app** proving every layer actually works together.

That's a lot. For a homelab — a personal, self-hosted environment you control completely — this is a solid, credible baseline. The cluster can lose a worker node and keep serving. It can recover from a git push. It pages you when something is actually wrong.

**But there are honest limits.** Name them so you don't silently assume more than the build delivers:

| What you have | What you don't have (yet) |
|---|---|
| 3 nodes, 1 control-plane | Stacked etcd / HA control-plane — if the single control-plane node dies, the cluster is down until it's restored |
| Longhorn with 3 replicas | Longhorn needs all 3 nodes for full replica distribution — on fewer nodes you lose that guarantee |
| GitOps-driven drift correction | No formal disaster-recovery runbook beyond "rebuild from git" — a restore drill is a good next exercise |
| Single LAN (`192.168.1.0/24` in this series) | No multi-region, no real load-balancing across locations, no formal failover |
| One alert to ntfy | Alerting policy is whatever you've wired — there's no on-call rotation, escalation, or paging SLA |
| CrowdSec reading Traefik logs | WAF is a first line, not a complete security program — no runtime policy enforcement, no supply-chain signing, no network-policy deny-by-default yet |

"Production for a homelab" is not the same claim as "production for a business." A business needs staged rollouts, rollback runbooks, on-call rotations, incident postmortems, compliance evidence, and a tolerance for downtime that this setup doesn't promise. What you have is a homelab that behaves like production in the ways that matter most for a personal environment: it's persistent, it's observable, it's recoverable from git, and it pages you when something breaks.

!!! warning "The line to remember"
    This cluster is production-grade **for a homelab** — meaning it's built with the same components and practices real environments use, in a form you can actually operate. It is not production-grade for a business that depends on it for revenue, compliance, or customer-facing SLAs. Don't deploy a revenue-critical service onto it without closing the gaps that matter for that service.

## Hardening checklist

If you've followed the series and want to tighten things up before calling the build "done," run through this list. Each item is something you can do today with the skills you've built.

### 1. Close the control-plane gap (if it matters to you)

k3s here runs a single control-plane node. For a homelab that's usually fine — you're around to reboot it. If you want higher control-plane availability, the path is stacked etcd or an external etcd cluster, which k3s supports but turns the setup from "3 cheap mini PCs" into something more involved. Decide whether the extra complexity is worth it for your use case.

### 2. Run a restore drill

GitOps means the cluster is recoverable from git — but "recoverable in principle" and "I've done it under pressure" are different. Pick a non-critical app, delete its Deployment, and watch Flux re-sync it. Then try deleting a whole namespace and restoring it. The goal isn't to break anything real; it's to confirm the recovery path you'll need if something actually goes wrong.

### 3. Add a second alert

One alert (disk pressure → ntfy) is a start, not a complete alerting posture. Add at least one more that matters to you — common candidates: a pod stuck in `CrashLoopBackOff` for more than a few minutes, a Longhorn volume replica that falls behind, or a cert-manager certificate expiring within 14 days. The pattern from episode 9 generalizes: write the alert rule, wire it to Alertmanager, route it to ntfy.

### 4. Back up `age.agekey` somewhere durable

The age private key is the only thing that decrypts your secrets. It lives in the `sops-age` Secret in the cluster and in a local `age.agekey` file (if you still have one). If both are lost, the secrets in git are gone for practical purposes. Copy `age.agekey` to a second location you trust — a USB drive, a password manager, an encrypted backup — and test that you can still decrypt a `*.sops.yaml` with it.

### 5. Wire Longhorn backups to an off-cluster target

Longhorn replicates across nodes, which protects against a node loss. It doesn't protect against a simultaneous loss of the whole cluster (power event, rack issue, accidental `kubectl delete namespace longhorn-system`). Configure a Longhorn backup target — an S3-compatible bucket, another NFS share, anything off-cluster — and schedule recurring snapshots. Episode 6 touched on the storage side; the backup target is the next logical step.

### 6. Review network policies

By default, pods in a Kubernetes cluster can talk to each other across namespaces unless you say otherwise. For a homelab that's convenient; for anything handling sensitive data it's a gap. Start small: apply a deny-by-default policy in one namespace (e.g. the app namespace from episode 11) and only allow the traffic that namespace actually needs. Cilium makes this straightforward — the L2LB VIP you set up in episode 3 is Cilium, and CiliumNetworkPolicy is the same family.

### 7. Audit what Renovate is patching

Renovate opens daily PRs for outdated Helm charts. That's great for keeping up to date, but a PR auto-merged without review can pull in a broken chart version. For a homelab, the right balance is usually: let Renovate open the PR, review it yourself (or via the HomeOps PR pipeline if you've wired that up), and merge when the build is green. The CrowdSec and Reloader pieces from episode 10 don't replace that review — they complement it.

### 8. Check your backup restore, not just your backups

A backup you've never restored from is a hope, not a plan. Longhorn backups (item 5) and any other backup you set up should be restored at least once to a test namespace or a scratch cluster. The restore drill in item 2 covers git-based recovery; this covers data recovery. They're different failure modes.

### 9. Remove what you're not using

A homelab accumulates things — test namespaces, old ingresses, unused HelmReleases. Periodically audit what's running and remove anything that isn't serving a purpose. Fewer moving parts means fewer things that can break, fewer credentials to rotate, and a smaller attack surface. Flux's `prune: true` already cleans up resources removed from git; the manual part is removing the git definitions themselves.

### 10. Document the stuff you figured out by breaking it

Every homelab has a few things that only make sense after you've hit the edge case. The cert-manager DNS-01 wildcard, the Cilium L2LB VIP, the Cloudflare Tunnel for the one public app, the age key backup — these are the things you now know because you built them. Write down the gotchas you hit. Future-you (or anyone else building the same stack) will thank you.

## What HomeOps adds beyond this series

This series taught you the *what* and *how* of each component using simplified, copy-pasteable snippets. The real [HomeOps](https://github.com/shubhamwagh/homeops) repo — which is private, so you can't clone it directly, but whose structure is described throughout this series — adds the glue that turns these pieces into a single operable system:

- **A Makefile** that wraps the underlying commands (`k3sup install`/`join` for k3s, the Helm invocations for Cilium, the `flux bootstrap` flow, and so on) into coherent tasks like `make bootstrap`, `make gitops`, `make flux-status`. In this series you ran the raw commands; in HomeOps they're organized behind targets so day-to-day operations are one command instead of five.
- **Ansible playbooks** for the provisioning steps (the k3s install over SSH, the headscale install on the VPS) — the same underlying commands, structured for repeatability across node reprovisions.
- **SOPS secret management** with a `secrets-manifest.yaml` that classifies every credential as human-access or machine-only, recoverable or hash-only — the policy layer that decides which secrets get surfaced to a human and which stay machine-only.
- **A Hermès agent** (this one) running in the cluster with scoped RBAC — read-only cluster-wide, write-scoped to specific application namespaces, Flux-reconcile permission on the GitOps objects, and a break-glass elevation path for critical operations. That's the autonomy layer that lets the cluster be operated programmatically without handing out cluster-admin.
- **A GitHub App Token Broker** so Hermès (and Renovate) get short-lived, repo-scoped GitHub tokens instead of long-lived personal tokens — the pattern behind Renovate's init-container flow from episode 10 and the blog PR flow from episode 11.
- **A CrowdSec + Vaultwarden pairing** — CrowdSec reads Traefik logs for abuse patterns, and Vaultwarden (Bitwarden-compatible) stores the human-access credentials that `make secrets-plaintext` surfaces, as the durable second copy of stuff that would otherwise live in a gitignored local file.

None of this is magic — it's the same components you installed, organized into a single repo with a consistent opinion about how they fit together. If you liked building this series, cloning HomeOps (when it's public) or mirroring its structure for your own cluster is the natural next step.

## Where the series goes from here

This is the last numbered episode in the current build order — you've now installed the full HomeOps stack: k3s, Cilium, Flux, Traefik, cert-manager, Longhorn, SOPS+age, Headscale, monitoring, Renovate/Reloader/CrowdSec, and a real app through every layer.

What comes after is less about installing new components and more about operating what you have: running restore drills, tightening alerts, auditing patches, removing unused resources, and documenting the gotchas. The hardening checklist above is a starting point; the real work is the ongoing cycle of "break it, fix it, write down what happened."

If you built along with this series, you now have a cluster that is, by any honest measure, more than a toy. It's a real, persistent, observable, recoverable Kubernetes environment built from commodity hardware on your own terms. That's a solid place to be.

!!! tip "What to do next"
    Pick one item from the hardening checklist and do it this week. The restore drill (item 2) is the highest-leverage first step — it confirms the recovery path you'll need if anything else goes wrong, and it's safe to run on a non-critical app.

---

*Part of the Homelab From Scratch (Hands-On Build) series — a practical, step-by-step companion to building your own Kubernetes homelab. Start with [episode 0: what's coming](/start-here-a-hands-on-homelab-from-3-mini-pcs/), or jump to [episode 11: deploy a real app end-to-end (capstone)](/deploy-a-real-app-end-to-end-capstone/) if you landed here first.*
