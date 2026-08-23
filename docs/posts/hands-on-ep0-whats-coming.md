---
date: 2026-08-21
description: The hands-on homelab series intro — start here for what we're building, the hardware, who it's for, the honest "production-grade" limits, and the full 12-episode roadmap.
categories:
  - Homelab
  - Kubernetes
tags:
  - homelab
  - kubernetes
  - k3s
  - tutorial
  - series
comments: true
series: Homelab From Scratch (Hands-On Build)
---

# Start Here: A Hands-On Homelab From 3 Mini PCs

In my [first post](/hello-world/) I explained *why* I built a Kubernetes homelab out of three
mini PCs. In the [tour post](/how-my-3-node-k3s-homelab-actually-works/) I showed *what* it looks like once it's
running. This post is different: it's the start of a **hands-on series** where we actually *build*
the thing, step by step, with copy-pasteable commands.

No theory-only. Every episode ends with something real running on your machines.

<!-- more -->

## What you'll build

By the end of the series you'll have a small but genuinely production-shaped Kubernetes homelab,
using the same components I run at home:

- **k3s** — a lightweight, certified Kubernetes on three nodes
- **Cilium** — the networking layer, including a load-balancer VIP from a small LAN pool so your services get real, reachable IPs
- **Flux** — GitOps, so *git* becomes the control panel for your cluster
- **Traefik** + **cert-manager** — ingress and automatic free TLS via Let's Encrypt (using a DNS
  challenge, so it works even on a normal home connection where port 80 is blocked)
- **Longhorn** — distributed storage that survives a node dying
- **SOPS + age** — secrets committed to git *encrypted*, never in plaintext
- **Headscale** — self-hosted Tailscale, so you can reach your lab from anywhere safely
- **Prometheus + Grafana + ntfy** — monitoring that actually pages you when something breaks
- **Renovate + Reloader + CrowdSec** — automated updates and a basic security layer
- and finally, **deploy a real app** end to end and a **hardening checklist**

That is a lot. But we go one layer at a time, in a teaching order that follows the real
dependency chain, so each episode only assumes what the previous ones already covered. (Two small
reorders for clarity: secrets land alongside Flux in the real setup, and we cover them a few
episodes later once the idea of GitOps has sunk in.)

## The hardware

Three cheap mini PCs. I used HP EliteDesk/G2-class machines — second-hand, low power, silent on a
shelf. You don't need anything exotic. If you only have *one* machine to start (an old laptop, a
mini PC, even a VM), that's fine: episode 1 shows the one-node path and how to grow to three when
you're ready. The whole point is to start small and make it real.

You'll also want one **control machine** — the laptop you already use (I run mine from a MacBook)
— to drive the install over SSH. And for the TLS and remote-access episodes, a registered domain
name (we'll use `example.com` as a placeholder) plus a tiny free-tier VPS for VPN coordination.

## Who this is for

You should be comfortable in a terminal and have maybe touched Docker once. You do **not** need to
know Kubernetes. We explain each piece before we wire it up. If you've ever thought "I'd like to
run my own services instead of paying for twelve subscriptions," this is for you.

## An honest definition of "production-grade"

I'll keep saying this, because it matters: *production for a homelab* is not the same as *production
for a business*.

What this series genuinely delivers:

- git-driven, reproducible infrastructure (no snowflake servers)
- real TLS, real secrets management, real backups
- monitoring + alerting so you find out before your users do
- safe remote access without punching holes in your router

What it deliberately does **not** do (and I'll say so again in the last episode):

- single control-plane node (no HA control-plane — fine at home, not for a 9-to-5 SLA)
- Longhorn needs the three nodes to actually replicate, so don't expect magic on one box
- no multi-region, no formal disaster recovery beyond a basic restore drill

That's the right trade. You'll learn the *real* patterns, and you'll know exactly where the
line is.

## The roadmap

Twelve build episodes, one a day:

1. **Hardware + OS baseline** — the machines, a Debian-based Linux (I use Ubuntu on my nodes), static IPs, SSH keys, the firewall
2. **Install k3s across 3 nodes** — one command per node, talk to your cluster
3. **Networking with Cilium** — how pods talk, and a load-balancer VIP
4. **GitOps with Flux** — let git run your cluster
5. **Ingress + free TLS** — Traefik and cert-manager
6. **Storage with Longhorn** — data that survives restarts
7. **Secrets with SOPS + age** — encrypted, committed, safe
8. **Remote access with Headscale** — your own VPN
9. **Monitoring that pages you** — Prometheus, Grafana, ntfy
10. **Patching & security** — Renovate, Reloader, CrowdSec
11. **Deploy a real app** — the capstone, tying it all together
12. **Is this "production"?** — the hardening checklist and what to add next

## How the series works

Each episode is self-contained and runnable. Where the real setup uses a big `Makefile` to automate
everything (it does — it's how I actually provision my cluster), I'll show you the *underlying
command* first so you understand what's happening, then point you at the shortcut. No black boxes.

The code snippets come straight from a real, working GitOps repo — we just simplify them and explain
the "why" so you're not copying incantations you don't understand.

Ready? The next post in the series covers [episode 1: hardware and OS baseline] — it publishes the day after this one.

---

*This is episode 0 of the [Homelab From Scratch (Hands-On Build)](/) series — a practical,
step-by-step companion to the separate [Building a Self-Hosted Homelab](/hello-world/) journal,
which covers the whys and the story rather than the build steps.*
