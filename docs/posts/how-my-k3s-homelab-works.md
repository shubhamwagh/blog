---
date: 2026-08-21 02:19:05
description: A beginner-friendly tour of a 3-node k3s homelab — how k3s, Cilium, Traefik, cert-manager, Longhorn, and Flux fit together, with a simple architecture diagram.
categories:
  - Homelab Journal
  - Homelab
  - Kubernetes
tags:
  - homelab
  - kubernetes
  - k3s
  - networking
  - architecture
comments: true
series: Building a Self-Hosted Homelab
---

# How My 3-Node k3s Homelab Actually Works

In my [last post](/hello-world/) I described *why* I built a Kubernetes homelab from three mini
PCs. This post is the *what* — a tour of the moving parts and how they fit together, drawn as
simply as I can.

If you have basic Linux knowledge and have maybe touched Docker once, you'll be fine. I'll
explain each piece before we connect them.

<!-- more -->

## The one big idea: a cluster, not a box

A single server running Docker is easy to understand. A **Kubernetes cluster** is harder, but
the payoff is big: instead of logging into one machine and starting containers, you describe
*what* you want running, and the cluster figures out *where* and *how* to keep it running.

My cluster has **three nodes** — small PCs on a shelf:

- **one control-plane node** (it runs the "brain" of Kubernetes: the API server, scheduler,
  and the database that stores cluster state)
- **two worker nodes** (they run the actual applications)

If the control-plane node reboots, the workers keep serving traffic. If a worker dies, its
work moves to the other one. That redundancy is the whole point of using a cluster instead of
one box.

!!! info "What is k3s?"
    [k3s](https://k3s.io/) is a lightweight, certified Kubernetes distribution. It packs the
    same core API as "full" Kubernetes but is small enough to run on a Raspberry Pi-class
    machine. For a homelab it is the usual starting point — less to maintain, same concepts.

## How traffic gets in: from the internet to a pod

Let's follow a single web request, because that path touches most of the stack.

```text
   Internet
      │
      ▼
   Cloudflare (DNS + proxy)      ← hides your home IP; you point the domain here
      │   request for blog.example.com
      ▼
   Cilium load balancer          ← hands out a LAN IP to in-cluster services
      │
      ▼
   Traefik  (ingress)            ← reads the hostname, picks the right app
      │
      ▼
   Your app pod  (e.g. the blog)
```

Here is what each hop does:

- **Cloudflare (DNS + proxy).** You point your domain (say `blog.example.com`) at Cloudflare,
  not directly at your home. Cloudflare then proxies the traffic to your network, so visitors
  see Cloudflare's IP — your home IP stays hidden. You also get caching and a bit of
  protection for free.
- **Cilium (networking).** Inside the cluster, Cilium is the **CNI** — the component that
  gives every pod an IP and moves packets between them. It also acts as a **load balancer**:
  when Traefik asks for an external IP, Cilium assigns one from your LAN and routes traffic to
  the right place.
- **Traefik (ingress).** Traefik is the front door. It looks at the incoming hostname
  (`blog.example.com` vs `notes.example.com`) and forwards each request to the correct app.
  You declare these routes in config; Traefik does the routing.
- **The app pod.** Finally the request reaches your container, which replies. The reader never
  sees any of the plumbing.

## Making the web safe: automatic TLS

A self-hosted site should still use HTTPS. Doing TLS by hand — generating certificates,
renewing them every few months, restarting services — gets old fast. So I let
**cert-manager** handle it.

cert-manager watches for "I need a certificate for `*.example.com`" requests and talks to a
public certificate authority (Let's Encrypt) to obtain and renew them automatically. It uses
the **DNS-01** method: instead of serving a file from your site, it proves ownership by
creating a temporary DNS record. That works even behind a home connection where port 80 is
blocked, and it lets you get a **wildcard** certificate (`*.example.com`) that covers every
subdomain at once.

The result: every ingress gets a valid, auto-renewing certificate, and I never touch OpenSSL.

!!! tip "Staging first"
    Let's Encrypt rate-limits requests. cert-manager has a "staging" issuer for testing (it
    issues fake-but-valid certificates) so you can perfect your config without burning your
    real quota. Move to the production issuer once it works.

## Where data lives: Longhorn storage

Containers are **ephemeral** — when a pod restarts, its local disk is gone. That's fine for a
stateless blog, but a database or a notes app needs somewhere persistent.

**Longhorn** turns the disks across your three nodes into a distributed storage system. When
you create a **PersistentVolume**, Longhorn stores it as replicas spread across nodes. If one
node fails, the volume is still available from the others. You get "a disk that survives pod
and node restarts" without a separate NAS.

I set the storage class to **Retain**, which means Kubernetes will not automatically delete the
underlying volume when an app is removed — a safety choice so I don't lose data by accident.

## The brain: GitOps with Flux

Here is the part I like most. **Nothing in this cluster is configured by hand.**

All the configuration — what apps exist, what images they use, what ingress routes exist — lives
in a **Git repository**. A tool called **Flux** runs inside the cluster, watches that repo, and
continuously makes the cluster match it.

```text
   Git repo (the source of truth)
        │  Flux reads it
        ▼
   Flux applies changes in stages:
        infrastructure   →  core platforms (CNI, ingress, storage, TLS)
        infrastructure-config → settings for those platforms
        apps             →  the actual applications
        │
        ▼
   Kubernetes cluster (always converging toward the Git state)
```

This pattern is called **GitOps**. The benefits are practical:

- **Audit trail.** Every change is a Git commit. Want to know who changed the ingress last
  Tuesday? It's in the history.
- **Rollback is free.** Break something? `git revert` and Flux puts it back.
- **Disaster recovery.** Wipe the cluster, reinstall k3s, point Flux at the repo — it rebuilds
  everything.

!!! info "Why stages?"
    Flux applies in order: first the platforms (Cilium, Traefik, cert-manager, Longhorn), then
    their configuration, then the apps that depend on them. Ordering matters — an app can't
    get an IP from Cilium before Cilium exists.

## Putting it together

Zooming out, the whole system is a loop:

```text
   You write config ──▶ Git repo
                              │
                        Flux (watches)
                              │
                              ▼
                   k3s cluster
                      ├─ Cilium      (network + load balancer)
                      ├─ Traefik     (ingress / routing)
                      ├─ cert-manager (TLS)
                      ├─ Longhorn    (storage)
                      └─ your apps

   Internet ──▶ Cloudflare ──▶ Cilium IP ──▶ Traefik ──▶ app
```

Each layer has one job. Cilium moves packets, Traefik routes by name, cert-manager keeps TLS
fresh, Longhorn keeps data safe, and Flux keeps the *desired* state and the *actual* state in
sync. You mostly interact with the Git repo, not the servers.

## What this sets up for next time

With the *what* covered, the natural next questions are *how do I manage it* and *how do I keep
it safe*:

- **GitOps deeper:** how Flux really reconciles, and why Git becomes your control panel.
- **Secrets:** how to keep passwords and tokens in Git **without** putting them in plaintext
  (encrypted, but still version-controlled).

Then — and only then — we'll get to the fun part: handing some of this operation to an AI agent,
and the guardrails that make that safe.

---

*This is part of the [Building a Self-Hosted Homelab](/) series — start with [Why I Built a
Kubernetes Homelab](/hello-world/).*
