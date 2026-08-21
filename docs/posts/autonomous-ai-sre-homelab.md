---
date: 2026-08-21
description: How I deployed Hermes Agent as an autonomous, least-privilege SRE for my k3s homelab — and the guardrails that keep it safe.
categories:
  - Homelab
  - Kubernetes
  - AI
tags:
  - homelab
  - kubernetes
  - k3s
  - gitops
  - ai-agent
  - sre
comments: true
---

# An Autonomous AI SRE for a k3s Homelab

Most homelab posts stop at "I installed Kubernetes." This one goes a step further: I gave an
AI agent a seat in the cluster — with just enough power to help, and not enough to break
anything. Here is how I built an autonomous SRE using Hermes Agent and what I learned about
keeping it safe.

<!-- more -->

## Introduction

A homelab is a great place to learn, but it is also a place where small problems quietly
pile up: a pod stuck in `CrashLoopBackOff`, a certificate that forgot to renew, a disk slowly
filling up. I did not want to be the one manually poking at `kubectl` every time something
wiggled.

So I deployed **Hermes Agent** — a persistent AI agent — *inside* my own cluster, gave it
read access everywhere and careful write access in a few places, and taught it to operate the
homelab the way I would: investigate first, understand, then act.

The interesting part is not "an AI can run kubectl." It is how you let an AI touch your
infrastructure **without handing it the keys to the kingdom**.

## Architecture

The big picture is a loop:

```text
HomeOps Git repo
      │  (source of truth)
      ▼
   Flux CD  ──▶  k3s cluster  ──▶  runs the blog, Vaultwarden, and everything else
      ▲                              │
      │                              ▼
   Hermes  ── kubectl / flux ──▶  Kubernetes API  (as a ServiceAccount)
```

And the agent's own view of the world:

```text
Hermes (in-cluster pod)
   │
   ├─ kubectl / flux / helm      →  Kubernetes API
   │                                 │
   └─ runs as a ServiceAccount  ──▶  RBAC + Admission Policies decide what it may do
```

Hermes is just another workload in the cluster. It talks to the Kubernetes API the same way
`kubectl` does — but the *identity* it uses (a Kubernetes ServiceAccount) is what limits it.

!!! info "What is a ServiceAccount?"
    In Kubernetes, every process that talks to the API does so as an identity called a
    ServiceAccount. RBAC rules attach to that identity. Give an agent a narrowly-scoped
    ServiceAccount and it physically cannot do anything outside that scope — even if it
    "wants to."

## Why Not Give the Agent cluster-admin?

It is tempting. `kubectl apply` works, the agent can fix anything, job done. But
cluster-admin is the "delete the whole cluster" button. If the agent ever misunderstands a
task, or if a prompt gets twisted by content it read from the internet, cluster-admin turns a
small mistake into a total outage.

So I used **least privilege**: the agent gets exactly the access it needs for ordinary app
operations, and nothing more. This is the same principle you already use for human operators
and CI systems — an AI operator is no different.

## Read vs Operator Access

The agent has two distinct levels of access:

- **Cluster-wide read.** It can *see* almost everything: nodes, pods, events, logs, Flux
  state, storage, certificates. Observation is cheap and safe, so the agent is allowed to look
  widely. This is how it diagnoses problems.
- **Scoped application write.** It can *change* things only inside a small set of ordinary
  application namespaces (the blog, a homepage dashboard, a notification service, and a few
  others). Platform namespaces — the control plane, Flux, cert-manager, storage — are
  **read-only to the agent**, with one narrow exception: a tightly-scoped `patch` permission
  that lets it trigger Flux *reconcile / suspend / resume* on Kustomizations and HelmReleases,
  including in a handful of platform namespaces. It cannot edit the workloads or config there —
  only ask Flux to re-sync.

That split matters. Reading the database credentials is forbidden; restarting a stuck blog pod
is allowed. The blast radius of any mistake is bounded to a few apps.

## Autonomous vs Critical Operations

Not every action deserves the same scrutiny. The agent classifies work into three colours:

- **GREEN — normal autonomous actions.** Routine, reversible, low risk. Restart an unhealthy
  pod, read logs, check health, roll out an ordinary app change. The agent does these without
  asking, then reports what it did. Example: "the blog pod was crash-looping, I deleted it, the
  Deployment recreated it, it is healthy again."
- **YELLOW — higher risk but recoverable.** Things like restarting an infrastructure
  controller or rolling back a non-critical release. The agent may proceed, but only after it
  has checked the actual problem, the dependencies, the blast radius, and how to roll back.
- **RED — human approval required.** Anything with real risk of data loss, a major outage, or
  security exposure: deleting storage volumes, deleting namespaces, granting cluster-admin,
  disabling TLS. The agent stops and asks a human first.

This is written down as policy, not left to mood. An autonomous agent is only useful if it
knows the difference between "restart a pod" and "delete the database."

## Break-Glass Access

Some emergencies need more power than the agent's day-to-day identity has. The clean way to
handle that is **break-glass**: a higher-privilege role exists in the cluster, but it is
*unbound* by default — no identity is attached to it. A human can explicitly "elevate" the
agent for a specific fix, the agent does the work, and the elevation is automatically revoked
afterwards.

Crucially, the agent **cannot elevate itself**. Only a human controls that switch. The
agent's normal identity is permanently non-admin, so a compromised or confused agent cannot
quietly grab destructive power.

## Preventing Secret Access

Secrets are the crown jewels: database passwords, API tokens, TLS private keys. The agent
must never be able to read them. Two layers enforce this:

- **No Kubernetes Secret API access.** RBAC simply does not grant the agent `get` on Secrets.
  It cannot list or read them.
- **Encrypt-only model.** The homelab keeps secrets in git using **SOPS + age**: files are
  encrypted with an *age public key* and committed. Flux decrypts them at apply time. The
  agent holds only the **public** recipient, so it can *encrypt* a new value if asked, but it
  can never *decrypt* existing secrets — it does not have the private key.

```text
Public key  →  can ENCRYPT only   (what the agent has)
Private key →  can DECRYPT        (lives only in the cluster / a password manager, never with the agent)
```

Even if the agent were tricked into trying, there is no key for it to use.

## Admission Policies

RBAC says "what identities may do." **Admission policies** are a second gate that says "what
kinds of objects may enter the cluster at all" — and they apply regardless of who is asking.

For the agent, an admission policy blocks workloads it tries to create or edit from:

- running **privileged** containers,
- using **host networking** (reaching the node's network directly),
- adding dangerous Linux **capabilities**,
- mounting a **host filesystem**,
- or introducing a **new Secret reference** (a sneaky way to exfiltrate a credential via logs).

So even though the agent has write access to ordinary app namespaces, these policies stop it
from abusing that access to escalate. Admission control is the safety net under the safety net.

!!! tip "RBAC and admission policies are friends"
    RBAC limits *who*. Admission policies limit *what*. You want both: RBAC keeps an ordinary
    app identity ordinary, and admission policies stop that identity from doing something
    silly even within its own namespace.

## Giving Hermes Its Own SRE Toolbox

The agent runs in a custom container image that ships the command-line tools a Kubernetes
operator actually needs, so it is not constantly installing things:

- `kubectl` — talk to the cluster
- `flux` — watch and reconcile GitOps
- `helm` — inspect chart releases
- `git` — read the source of truth
- `curl` — probe endpoints and TLS
- `jq` / `yq` — parse JSON and YAML
- `kustomize` — render desired state
- `sops` / `age` — handle encrypted secrets safely

Bundling the toolbox means the agent can go from "I notice a problem" to "I have evidence" in
one step, instead of first fighting with missing dependencies.

## Persistent Agent State

The agent stores its memory and configuration on a **persistent volume** (a host-mounted data
directory that survives pod restarts), not on the container's ephemeral filesystem. If the pod is
restarted or rescheduled,
the agent wakes up with its profile, skills, and history intact — it is a *persistent* agent,
not a fresh chatbot every time.

That persistence is what lets it learn your preferences and accumulate project knowledge
across sessions, instead of starting from zero each time.

## Agent Teams

One agent does not have to do everything. Hermes can act as a **Lead** and delegate to
specialist subagents for parallel investigation:

- **Platform** — Kubernetes, Flux, ordinary workloads
- **Incident** — outages and multi-system failures
- **Storage** — Longhorn, volumes, backups
- **Security** — ingress, TLS, network exposure
- **Release** — upgrades and version drift

For a cluster-wide health check, the Lead can fan these out in parallel and combine the
results. Each specialist gets a bounded task and the same safety rules; the Lead stays
responsible for the final answer.

## Testing the Agent

Before letting it operate freely, I ran a bootstrap test suite — all read-only:

- **live kubectl** — confirm it can actually talk to the cluster
- **Flux visibility** — confirm it can see reconciliation state
- **metrics** — confirm `kubectl top` works
- **RBAC checks** — enumerate exactly what it may and may not do
- **subagent test** — prove delegation works and matches direct observation
- **admission dry-run** — prove a forbidden manifest is rejected *before* anything is created
- **persistence** — confirm its state survives a pod restart

Then a single **controlled remediation test**: delete one ordinary app pod and watch the
controller recreate it, verifying the app comes back healthy. Small, reversible, and proof the
autonomy loop actually closes.

## Lessons Learned

A few things stood out:

- **Scope first, power later.** Give read access, prove the agent is useful and careful, then
  add narrow write access. Never the reverse.
- **Admission policies earn their keep.** RBAC alone is not enough when an identity can write
  workloads. The "no new Secret reference" rule closed a real exfiltration path.
- **Encrypt-only secrets are elegant.** Shipping only a public key means the agent can help
  with secrets without ever seeing them.
- **Persistence makes it an agent, not a script.** Memory across sessions is what turns a
  tool into a teammate.
- **Stay honest about limits.** The agent has no off-cluster backup today, and it cannot
  self-elevate. Those are features, not bugs — they keep "autonomous" from meaning "unaccountable."

## Getting Started

A simplified path if you want to build something similar:

1. Deploy Kubernetes (k3s is great for bare metal).
2. Establish GitOps (Flux) so config lives in git.
3. Deploy Hermes (or a similar agent) as a normal in-cluster workload.
4. Give it **read-only** Kubernetes access first.
5. Add the operator tooling (kubectl, flux, helm, git, sops/age).
6. Test it thoroughly with read-only checks.
7. Add **scoped** operator privileges — only in ordinary app namespaces.
8. Add safety guardrails: admission policies, encrypt-only secrets, break-glass.
9. Introduce autonomy **gradually**, starting with GREEN-tier actions.

This is a learning homelab, not a universal production blueprint. Tune the boundaries to your
own risk tolerance — but the shape (least privilege + admission control + human-in-the-loop for
the scary stuff) travels well.

---

*Built on a real k3s homelab running Flux, Cilium, Traefik, cert-manager, Longhorn, and
Headscale. The agent operates it; the guardrails keep it honest.*
