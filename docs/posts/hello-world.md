---
date: 2026-05-19
categories:
  - Meta
---

# Hello World

Hi, I am Shubham Wagh. I work at the intersection of robotics, machine learning, and computer vision. My day to day does not involve managing Kubernetes directly - but it involves enough interaction with infra teams, and enough use of tools like SkyPilot for batch ML jobs, to make the underlying infrastructure hard to ignore.

Watching infra engineers manage GPU clusters and deployment pipelines got me curious: how does this actually work? And could I build something like it myself, at home, from scratch?

So I started a homelab - bare-metal servers running a Kubernetes cluster, built with the same tools used in production. Not just a NAS. An actual GitOps setup with proper secrets management, TLS, VPN, monitoring, and storage redundancy.

The goal: treat it like a real system and learn by doing.

## Why write about it

Building this has involved a lot of debugging and wrong turns. Writing it down forces me to understand what I actually built, and hopefully saves someone else the same headaches.

Posts will cover specific problems, setup walkthroughs, and things I picked up along the way.

## Meta

This blog runs on the homelab. It is a [MkDocs Material](https://squidfunk.github.io/mkdocs-material/) site served by nginx, running as a pod in the same Kubernetes cluster. It is publicly accessible via a Cloudflare tunnel - an outbound-only connection from the cluster to Cloudflare's edge, so no ports are open on my home network.

Writing about self-hosted infrastructure on self-hosted infrastructure feels right.

## What is coming next

The next post will be a brief overview of the homelab stack - what is running and why.

## Follow along

Subscribe via [RSS](https://blog.shublab.com/feed_rss_created.xml).
