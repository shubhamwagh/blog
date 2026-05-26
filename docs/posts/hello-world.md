---
date: 2026-05-19
description: Why a robotics engineer built a bare-metal Kubernetes homelab — and started writing about it.
categories:
  - Meta
tags:
  - homelab
  - kubernetes
  - introduction
comments: true
---

# Hello World

I work on the software side of robotics — machine learning, computer vision, perception pipelines. Day-to-day that means training models, wrangling datasets, and running batch jobs on GPU clusters.

Managing Kubernetes is not my job. But using infrastructure is.

<!-- more -->

## The itch

Tools like [SkyPilot](https://skypilot.readthedocs.io/) abstract away a lot of the cluster complexity — but they don't hide it completely. Watching infra engineers debug GPU node affinity, manage secrets rotation, and wire up monitoring dashboards made me curious about what was actually happening underneath.

**Could I build something like that myself, from scratch?**

So I bought three HP G2 mini PCs, shoved them in a corner, and started building.

## What I built

Not a NAS. Not a home media server. A proper Kubernetes cluster — bare metal, GitOps, the works:

- **k3s** on three nodes, provisioned with Ansible
- **FluxCD** for GitOps — every change goes through git
- **SOPS + age** for secrets — encrypted and committed, never plaintext
- **Cilium** for networking, with a virtual IP for load balancing
- **Traefik** for ingress, **cert-manager** for automatic TLS
- **Longhorn** for distributed storage, **Prometheus + Grafana** for monitoring
- **Headscale** (self-hosted Tailscale) for VPN access from anywhere

The goal: treat it like a real production system and learn by doing.

## Why write about it

Building this involved a lot of debugging, wrong turns, and moments of "why does this only break at 2am." Writing forces me to actually understand what I built — and hopefully saves someone else the same headaches.

Posts will cover specific problems, setup walkthroughs, and things I picked up along the way. No fluff.

## About this blog

!!! info "Meta"
    This blog runs on the homelab. It is a [MkDocs Material](https://squidfunk.github.io/mkdocs-material/) site, built by GitHub Actions and served as a pod in the same Kubernetes cluster — publicly accessible via Cloudflare DNS pointing at the cluster's Traefik ingress. Writing about self-hosted infrastructure on self-hosted infrastructure feels right.

## Follow along

Subscribe via [RSS](https://blog.shublab.com/feed_rss_created.xml) or leave a comment below.
