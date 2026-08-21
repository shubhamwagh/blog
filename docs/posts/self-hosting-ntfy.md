---
date: 2026-08-21 09:13:51
description: Why and how I run my own push-notification server with ntfy — private, tiny, and scriptable, sitting behind the same Traefik/cert-manager/Longhorn stack as the rest of the homelab.
categories:
  - Homelab
  - Self-Hosted Apps
tags:
  - homelab
  - self-hosting
  - ntfy
  - notifications
  - privacy
comments: true
series: Building a Self-Hosted Homelab
---

# Self-Hosting ntfy: Your Own Push Notification Server

In the [last post](/how-my-3-node-k3s-homelab-actually-works/) I walked through the moving parts of the
cluster — k3s, Cilium, Traefik, cert-manager, Longhorn, Flux. This one is a concrete example
of that architecture doing something useful: a **push-notification server** I run myself,
called [ntfy](https://ntfy.sh).

The pitch is simple. Most apps "notify" you by handing your message to Apple or Google's push
service. That means the content of "your car's MOT is due" or "a gym slot just opened" travels
through someone else's servers. ntfy lets you cut that out: you run a small server, and your
scripts and phone talk to *it* directly.

<!-- more -->

## What problem does it solve?

Picture the loop I actually wanted:

> A script on the homelab notices something → my phone buzzes → I act.

The usual way to close that loop is Firebase Cloud Messaging or Apple Push Notification service.
Both work, but they require a vendor project, an app registration, and — the part that bothers
me — your message content leaving your network. For a homelab, where half the fun is *owning*
the stack, that's a weird place to leak control.

ntfy is one binary (or one container) that speaks plain HTTP. No vendor account, no SDK tax. A
script can notify you with a single `curl`.

## The mental model: pub/sub over HTTP

ntfy is, at its heart, **publish/subscribe where a topic is just a URL path**. There's no broker
config and no topic provisioning.

```text
   publish                        subscribe
scripts/app ──POST body──▶  ntfy server  ──▶  phone app (UnifiedPush)
curl -d "msg" https://ntfy.example.com/cartopic
```

- **Publish:** `POST https://ntfy.example.com/<topic>` with your message as the body.
- **Subscribe:** install the ntfy app, point it at your server's base URL, and subscribe to
  `<topic>`. Or just `curl -N https://ntfy.example.com/<topic>` to long-poll from a terminal.
- **Web UI:** the same base URL opens a browser view of any topic.

That's the whole interface. Anything that can make an HTTP request can now alert you.

## A privacy nuance worth knowing (especially on iOS)

Here's the one gotcha that surprises people. On iOS, Apple won't wake an app in the background
unless the push came through **Apple's** push service (APNs). So a purely self-hosted ntfy can
be *silent* on an iPhone until you reopen the app.

ntfy solves this without giving up privacy: you can tell your server to route only the
**wake-up ping** through ntfy.sh's public relay, while the **message content** still comes from
your own server. ntfy.sh then learns "something arrived for this device" — never *what*. It's a
clean split: the wake-up is metadata, the content is yours.

On Android, UnifiedPush can let ntfy deliver messages locally as the distributor, so you can
often skip the relay entirely.

## How it runs in my homelab

This is where the [architecture from the last post](/how-my-3-node-k3s-homelab-actually-works/) pays off. ntfy
is just one tiny pod that reuses the existing platform services:

```text
   Internet
      │
      ▼
   Cloudflare (DNS + proxy)     ← hides the home IP
      │
      ▼
   Traefik (ingress)            ← routes ntfy.example.com
      │
      ▼
   ntfy pod  (single replica)
      │
      └─▶ Longhorn volume       ← stores cache + auth database
```

It sits in its own namespace, uses a **Longhorn** persistent volume for its cache and auth
database, is exposed through **Traefik** with automatic TLS from **cert-manager** (the same
Let's Encrypt wildcard as everything else), and Cloudflare sits in front so my home IP stays
hidden.

The entire resource request is almost nothing — tens of millicores of CPU and a few tens of
megabytes of memory. It's one of the cheapest "services" in the cluster.

### The settings that matter for safety

Because the server is reachable from the internet (via Cloudflare), I lock it down at the app
level:

```yaml
env:
  - name: NTFY_BASE_URL
    value: "https://ntfy.example.com"
  - name: NTFY_CACHE_FILE
    value: "/var/lib/ntfy/cache.db"
  - name: NTFY_AUTH_FILE
    value: "/var/lib/ntfy/auth.db"
  - name: NTFY_AUTH_DEFAULT_ACCESS
    value: "deny-all"        # nobody can publish/subscribe unless explicitly allowed
  - name: NTFY_ENABLE_SIGNUP
    value: "false"           # no public account creation
  - name: NTFY_BEHIND_PROXY
    value: "true"            # trust X-Forwarded headers from Traefik/Cloudflare
  - name: NTFY_UPSTREAM_BASE_URL
    value: "https://ntfy.sh" # iOS wake-up relay only (see above)
```

Two lines do most of the work: `NTFY_AUTH_DEFAULT_ACCESS=deny-all` and
`NTFY_ENABLE_SIGNUP=false`. An internet-exposed notification server with open signup is an
invitation to spam, so both are non-negotiable here. (Authentication itself is configured through
ntfy's auth database — I won't paste credentials here, but the project docs cover user and token
creation clearly.)

!!! tip "Pin your image"
    The deployment pulls `binwiederhier/ntfy:latest`. For anything internet-facing I'd pin a
    specific version tag in real life so a surprise upstream change can't silently alter
    behaviour. Beginner-friendly, but worth knowing.

## The 30-second version to try at home

You don't need a cluster to see ntfy work. This runs the server locally with no TLS, just to
feel the loop:

```bash
docker run -p 8080:80 binwiederhier/ntfy serve
```

In another terminal, publish a message:

```bash
curl -d "hello from my own server" http://localhost:8080/mytopic
```

Open `http://localhost:8080/mytopic` in a browser (or subscribe with the app pointed at
`http://<your-machine>:8080`) and the message shows up. That's the entire product in one
command.

## What I actually use it for

The homelab already has several scripts that `curl` a message to my ntfy server when something
happens:

- **car-health-check** pings me when my car's annual test is coming due or a recall shows up.
- **better-booking-bot** alerts me the moment a gym class slot opens.
- Even the automation that helps write this blog notifies me when a post is ready or when
  something blocks it.

None of those need a Firebase project. They're `curl` calls in a cron job. The privacy win is
that the *content* of those alerts — "MOT due", "slot open" — never leaves my network except to
my own phone.

## Lessons learned

A few things I'd tell past-me:

- **Lock it down before exposing it.** `deny-all` + signups off, always, if it's
  internet-reachable.
- **Pin the image tag.** `latest` is convenient until it isn't.
- **Put Cloudflare (or similar) in front** to hide your home IP and terminate TLS.
- **Know the iOS relay trick.** It's the difference between "I got the alert" and "I opened the
  app and *then* saw the alert."

## Wrapping up

ntfy is a small, high-leverage addition to a homelab. It turns "some script detected something"
into "my phone buzzed" without handing your messages to a third party. And because it just
reuses Traefik, cert-manager, and Longhorn, it slots into the cluster I already described — no
new moving parts to babysit.

If you've followed along with the series, you've now seen the architecture *and* a real app
living in it. Next time I'll go a level deeper into how Flux keeps all of this — ntfy included —
in sync from Git.

---

*This is part of the [Building a Self-Hosted Homelab](/) series — the previous post was
[How My 3-Node k3s Homelab Actually Works](/how-my-3-node-k3s-homelab-actually-works/).*
