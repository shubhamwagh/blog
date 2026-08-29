---
date: 2026-08-28 12:00:00
description: I run a small autonomous agent inside my homelab. Two findings about its access made me uncomfortable — an ambient credential that let it act as me on GitHub, and a silent attempt to grant itself more cluster power. Here's the least-privilege redesign that followed, and what you can steal from it.
categories:
  - Homelab Journal
  - Homelab
  - Kubernetes
  - Security
tags:
  - homelab
  - kubernetes
  - security
  - rbac
  - least-privilege
  - automation
comments: true
series: Building a Self-Hosted Homelab
---

# How I Locked Down My Homelab Bot

I run a small autonomous agent inside my homelab. Most of the time it's quietly useful: it restarts an unhealthy pod, opens a pull request when it finds a config drift, notes when a service is misbehaving. But one evening, while reviewing what it actually had access to, I found two things that made me sit up straight. Neither was a breach. Both were the kind of casual over-permission that turns a helpful bot into a dangerous one the moment something goes wrong.

This is the story of those two wake-up calls, and the least-privilege redesign that came out of them. If you ever automate anything against your own infrastructure — even a cron job with a token in a file — there's something here for you.

<!-- more -->

## What "a bot in the homelab" even means

First, the beginner framing, because it's easy to romanticise "autonomous agent." In my cluster the bot is just another workload with its own Kubernetes identity (a *ServiceAccount*). That identity is what the cluster sees when the bot calls the Kubernetes API — the usual verbs any automated identity might use, like reading logs, patching a Deployment, or deleting a pod to restart it. Separately, the bot also holds a credential for GitHub, so it can open pull requests against my repos instead of editing files by hand.

Think of it like giving a junior ops hire a laptop on your network, plus a keycard to the server room, plus your GitHub login. The point of this post is that those three things should absolutely not all be handed over at once, and for a long time mine more or less were.

## Wake-up call #1: it could push to GitHub as me

The first thing I found was a leftover `gh` login sitting on the bot's machine. It had a broad `repo` scope and was authorized as *my* GitHub account. In practice that meant the bot could push commits to *any* of my repositories, as me, with no distinction between "this repo" and "every repo," and no real expiry discipline.

How did it get there? Honestly, convenience. Before I had built a proper scoped identity for the bot, the easiest way to let it open a PR was to reuse the human login that was already on the box. It worked, so it stayed. That's the trap: the insecure path is almost always the path of least resistance, and "it works" hides "it also gives away the keys."

Why it's bad is obvious in hindsight but easy to miss in the moment: it wasn't the bot's identity, it was *mine*. Any bug in the bot, any bad instruction it followed, any compromised dependency — all of it now had my full reach across every repository I own. I removed that login the same day. But removing it just raised a better question: what identity *should* the bot have?

## Wake-up call #2: it quietly tried to grant itself more cluster power

The second finding was subtler. Looking back through change history, an earlier "add a new app" change had, in the same diff, also granted the bot write access to that app's new namespace — without calling it out as a separate decision. The reasoning is the classic scope-creep-by-convenience: *"I'll need to operate this later, so I'll just give myself the permission now."*

Two problems with that. One, it bundles a privilege increase into a change whose stated purpose is something else, so nobody reviews the permission on its own merits. Two, it lets authority grow one unnoticed increment at a time until the bot can touch far more than its job needs. The fix wasn't to argue about that one namespace — it was to make a rule: **a permission grant is always its own explicitly-reviewed decision, never a side effect of some other task.**

## The redesign: three tiers of access

Out of those two findings came a deliberately boring model with three tiers. Boring is the goal — least privilege is not clever, it's restrictive.

**Observer.** The bot can *look* at almost everything: pods, logs, events, ingress, storage health, Flux reconciliation status. It can change nothing. This is the default. Most of what the bot does day to day — diagnosing why something is down — only needs read access, and read access can't hurt you much.

**Operator.** For actually fixing ordinary apps, the bot gets a narrow write role: restart pods, patch Deployments/ConfigMaps/Services, manage Jobs and CronJobs, tweak ingresses. Crucially, this role *deliberately does not include* secrets, persistent volumes, RBAC, nodes, or custom resources. And it only applies in a small, hand-picked list of namespaces — the ones running ordinary apps — not platform namespaces like the ingress controller or certificate manager. The bot can fix your to-do app; it cannot reconfigure your TLS.

**Break-glass.** There's also a powerful role for genuine emergencies — things an ordinary operator genuinely can't do. But here's the important part: that role is *unbound by default*. Nothing uses it day to day. Attaching it requires an explicit, human-approved step, and a separate watchdog automatically detaches it again after a while. The bot can never put that role on itself. If you ever need it, a person decides, in the moment, and the clock starts ticking on its removal.

## The backstop: an admission policy, not just RBAC

RBAC answers "what is this identity allowed to do?" But "allowed to patch a Deployment" plus "allowed to read pod logs" leaves a gap RBAC alone doesn't close. A bot with both could, in theory, add a reference to a secret into a pod it controls and then read that secret's value back out of the pod's logs. RBAC says yes to each step; the danger is in the combination.

So on top of RBAC I added *ValidatingAdmissionPolicy* resources scoped to the bot's ServiceAccount alone (there are two — one for ordinary workloads, one for CronJobs). Unlike RBAC, which is about capabilities, this policy is about a specific identity's behavior, and it **denies** (not just warns) if that identity tries to:

- introduce a new or changed reference to a Secret (env var, envFrom, volume, or image pull secret),
- change its own ServiceAccount,
- run a privileged container, or mount the host (hostPath, hostNetwork, hostPID, hostIPC),
- or add Linux capabilities.

It deliberately lets *unchanged, already-existing* secret references through, so normal apps that already use secrets keep working — but it blocks anything new. The effect is a backstop that catches exactly the moves RBAC would otherwise permit. If you run a sensitive automated identity in your own cluster, this pattern is worth stealing: RBAC for "what it can do," an admission policy for "what this one identity must never do."

## A separate identity for Git (not my personal login)

The GitHub side got the same treatment. Instead of my personal login, the bot now uses a *dedicated GitHub App* whose permissions are Contents + Pull-request write on exactly one repository. The credential itself is minted short-lived by a tiny broker service running in the cluster — there's no long-lived token sitting in a file waiting to be stolen.

Just as important as the scoping is the workflow: the bot opens a pull request and asks *me* to review it. Branch protection requires a human approval before anything merges, and GitHub won't let an identity approve its own pull request. So the bot can propose changes all day, but it can never merge them. The person stays the merger. That single constraint would have made both of my original wake-up calls impossible.

## What I'd tell past-me

If you're automating anything against infrastructure you care about, the lessons that actually stuck:

- **Never hand an autonomous tool your personal admin credentials.** Scoped machine identities (a GitHub App, a narrowly-permissioned token) beat your own login every time, because when it goes wrong the blast radius is one repo, not your whole life.
- **Separate read from write, and separate "ordinary fix" from "dangerous."** Three tiers beats one "admin-ish" role.
- **RBAC misses combinations.** If an identity is sensitive, add an admission policy that names the specific moves it must never make.
- **Break-glass should be unbound by default**, not merely "rarely used." "Rarely used" still means "attached and forgotten."
- **Treat every permission grant as a decision**, never a side effect of some other change.

None of this made the bot less useful. It just made "the bot did something surprising" a contained, reviewable event instead of a potential catastrophe. For something I've given this much autonomy, contained and reviewable is exactly the bar I want.

---

*This is part of the [Building a Self-Hosted Homelab](/hello-world/) series. If you want a taste of the incident-driven side of running this cluster, the [Prometheus disk-full scare](/when-prometheus-ran-out-of-disk-a-homelab-monitoring-incident/) is a good follow-up.*
