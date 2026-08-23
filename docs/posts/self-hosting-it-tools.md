---
date: 2026-08-23
description: Why and how I self-host IT-Tools — a bundle of 100+ developer utilities that run entirely in your browser, so your tokens, JWTs, and payloads never leave your machine.
categories:
  - Homelab Journal
  - Homelab
  - Self-Hosted Apps
tags:
  - homelab
  - self-hosting
  - it-tools
  - developer-tools
  - privacy
comments: true
series: Building a Self-Hosted Homelab
---

# Self-Hosting IT-Tools: 100+ Developer Utilities That Never See Your Data

Following the same pattern as [Self-Hosting ntfy](/self-hosting-ntfy-your-own-push-notification-server/) and [Self-Hosting Mailpit](/self-hosting-mailpit-a-dev-smtp-catch-all-and-email-preview/) — small, self-hosted apps that reuse the homelab's shared platform instead of standing up new infrastructure — here's another one: **IT-Tools**, a bundle of 100+ little developer utilities (JSON formatter, JWT decoder, hash/UUID generator, cron parser, and dozens more) that all run **entirely in your browser**.

The reason to self-host it is the same reason those other posts exist: stop handing your data to strangers.

<!-- more -->

## What problem does it solve?

Every developer has a handful of "quick fix it" websites bookmarked: a JSON pretty-printer, a base64 encoder, a JWT inspector, a regex tester. They're convenient — until you paste something sensitive into one.

Think about what you actually throw at those tools:

- a **JWT** from your app (it carries claims, sometimes an email or a user id)
- a **JSON payload** with internal field names and maybe a token
- the **output of a log line** that includes a customer id
- a **password** you're trying to hash or generate

When that tool is a random website, your input travels to *their* server, gets processed, and is often logged. You've just leaked context you didn't mean to.

IT-Tools flips that. It's a **static single-page app**: every utility is JavaScript that runs locally in your browser tab. There is no backend, no database, and no "send it to the server to compute" step. Your text never leaves the page.

> The mental model: it's a toolbox, not a service. You're not *calling* IT-Tools — you're *opening* IT-Tools, and the work happens on your own machine.

## The mental model: a static single-page app (SPA), no backend

```text
   your browser
   ┌─────────────────────────────┐
   │  IT-Tools page (static JS)  │
   │  ├─ JSON formatter          │   all run IN the browser
   │  ├─ JWT decoder             │   nothing uploaded
   │  ├─ Hash / UUID generator   │
   │  └─ ... 100+ more           │
   └─────────────────────────────┘
        │
        ▼  (only the page itself is fetched once)
   web server  ← just static files, serves HTML/JS/CSS
```

That simplicity has a nice side effect for the homelab: because there's no state and no secrets, the app needs almost nothing to run.

## How it runs in my homelab

This is the same story as the other self-hosted apps: it's one tiny pod that reuses platform services I already run, rather than something bespoke.

```text
   Internet
      │
      ▼
   Cloudflare (DNS + proxy)     ← hides the home IP
      │
      ▼
   Traefik (ingress)            ← routes it-tools.example.com
      │
      ▼
   it-tools pod  (single replica)
      │
      └─▶ (nothing)             ← no volume, no database, no credentials
```

Concretely, in the cluster it's:

- a **Deployment** with a single replica of the `corentinth/it-tools` image,
- a plain **Service** on port 80,
- an **Ingress** on `it-tools.example.com` that gets automatic TLS from **cert-manager** (the same Let's Encrypt wildcard every other service uses),
- and **Cloudflare** in front so my home IP stays hidden.

There is no PersistentVolume and no Secret. The deployment comment in my GitOps repo puts it plainly: *"client-side-only collection of developer utilities… no backend, no database, no persistent state — nothing is sent to a server, so no volume and no credential are required."*

The whole thing asks for **10 millicores of CPU and 32 MiB of memory** as a request — rounding-error territory in a 3-node cluster.

### The settings that matter for safety

Here's the part that surprises people who've read the Mailpit or ntfy posts: **IT-Tools has no authentication in front of it.** No basic-auth popup, no login.

That's not carelessness — it's because there's nothing to protect. With a static, client-side app there's no user account, no stored data, and no action the server performs on your behalf. Putting a login in front of it would protect an empty room.

What *does* protect it:

- **TLS everywhere** — cert-manager issues the wildcard cert, so traffic is encrypted in transit.
- **Cloudflare in front** — terminates TLS and hides the home IP; the cluster never sees direct internet traffic.
- **Security-headers middleware** — Traefik applies a shared harden-the-headers policy to the ingress.

Contrast that with a *stateful* app: Mailpit and ntfy hold data or accept messages, so they sit behind basic-auth. The rule of thumb I've settled on: **if the server holds or acts on anything, put auth in front of it; if it's a pure static page, TLS + Cloudflare is enough.**

!!! tip "Pin your image"
    The deployment currently pulls `corentinth/it-tools:latest` for simplicity. For anything internet-facing I'd normally pin a specific version tag so a surprise upstream change can't silently alter behaviour. Beginner-friendly, but worth knowing.

## The 30-second version to try at home

You don't need a cluster to see IT-Tools work. This runs it locally with no TLS, just to feel the interface:

```bash
docker run -p 8080:80 corentinth/it-tools
```

Open `http://localhost:8080` and you've got the whole toolbox — JSON formatter, JWT debugger, cron expression parser, password/UUID generator, and a lot more. Paste something sensitive into the JWT decoder and watch your browser do all the work locally (you can even disconnect from the network afterward and it still works).

## What I actually use it for

A few I reach for constantly:

- **JWT decoder** — paste a token, see the header/payload claims, without sending it anywhere.
- **Crontab generator / Cron parser** — sanity-check a schedule before committing it to a job.
- **JSON formatter & validator** — pretty-print an ugly API response.
- **Base64 / URL / HTML encoders-decoders** — the everyday glue work.
- **UUID / password / token generators** — and a hash generator to verify what a system *should* have stored.

None of those need a server. Self-hosting just means the toolbox lives on *my* domain, behind *my* TLS, instead of somebody else's website that logs my inputs.

## Lessons learned

A few things I'd tell past-me:

- **Client-side = private by default.** The biggest privacy win here isn't a setting — it's the architecture. No backend means no data leaves the browser.
- **Match the lock to the room.** Don't bolt auth onto a static page; do bolt it onto anything stateful. IT-Tools needs neither auth nor storage; Mailpit and ntfy need both.
- **Reuse the platform.** Traefik, cert-manager, and Cloudflare were already there — IT-Tools slots in with a Deployment, a Service, and an Ingress, and that's the whole deploy.
- **Put Cloudflare (or similar) in front** to hide your home IP and terminate TLS.
- **Pin the image tag** for anything exposed to the internet.

## Wrapping up

IT-Tools is a tiny, high-leverage addition to a homelab: a private developer toolbox that reuses Traefik, cert-manager, and Cloudflare — no new moving parts to babysit, and no third party seeing what you paste. It's the quiet proof that "self-hosting for privacy" isn't only about big apps; sometimes it's just about not pasting your JWT into a random website.

If you've followed along with the series, you've now seen the architecture *and* a few real apps living in it. Next time I'll go a level deeper into how Flux keeps all of this — IT-Tools included — in sync from Git.

---

*This is part of the [Building a Self-Hosted Homelab](/) series — the previous post was [Self-Hosting Mailpit](/self-hosting-mailpit-a-dev-smtp-catch-all-and-email-preview/).*
