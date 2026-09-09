---
date: 2026-09-09
description: My dependency-update bot was opening pull requests that could never be merged — because it was authoring them as me, and branch protection blocks self-approval. Here's the real root cause, the architecture that finally gave Renovate a real identity, and the chmod bug that almost break it.
categories:
  - Homelab Journal
  - Homelab
  - Kubernetes
  - Automation
tags:
  - homelab
  - kubernetes
  - gitops
  - renovate
  - github-actions
  - automation
comments: true
series: Building a Self-Hosted Homelab
---

# The Bot That Couldn't Be Reviewed: How Renovate's PRs Went Permanently Stale — and How I Fixed It

My dependency-update bot was opening pull requests every morning that nobody could merge.

Not because they were bad. Not because they needed changes. Because the bot was opening them **as me** — and branch protection on my own repo was set up to require a human review, which means a human other than the author. The bot had handed me a stack of perfectly good PRs and then quietly made them all permanently unmergeable.

This is the story of how I found that out, what was actually happening, and the identity architecture that finally gave my bot a real, separate GitHub identity — plus the one chmod bug that almost broke the whole fix on its first real run.

<!-- more -->

## The symptom: PRs piling up, forever

For a while I had a vague sense that Renovate's PRs were piling up without getting merged. I'd log in some morning, see three or four dependency updates sitting open from the previous night, glance at them, think "I'll get to those," and move on. Over time the backlog grew.

What I didn't notice — what's easy to miss when you're the only reviewer in the loop — is that the reason they weren't getting merged wasn't that I was busy. It was that they were **structurally unmergeable**.

Here's the chain:

- My homelab repo's `main` branch has branch protection: PR required, 1 approving review required, the CI `Validate` check required. This is the gate that keeps automated changes from landing without a human looking at them.
- Renovate was opening those PRs **as `shubhamwagh`** — my own GitHub account — because it was using a personal access token (PAT) that belonged to me.
- GitHub's branch protection says: the author cannot approve their own PR. That's the whole point — a four-eyes gate needs two different people.
- So every Renovate PR was author = `shubhamwagh`, reviewer required = `shubhamwagh`. The only person who could approve was the same person who opened it. **Every single one was stuck by design.**

I had built a bot that produced reviewable work and then made itself unreviewable.

## How it happened: the path of least resistance

This wasn't a deliberate decision. It was the path of least resistance at the time Renovate got wired up.

The old setup looked like this:

- A GitHub personal access token with broad `repo` scope, stored as a Kubernetes Secret in the cluster.
- Renovate's CronJob referenced that secret via `envFrom`, so every time it ran, it used **my** token.
- Renovate opened PRs. They showed up authored by me. I reviewed them (when I got around to it) and merged them.

"Works" is a dangerous word in automation. It worked, so the fact that it was architecturally wrong stayed invisible.

The only reason I noticed was that the backlog got annoying enough to look at closely — and when I did, the author/reviewer identity collision jumped out immediately.

## Why it's worse than "inconvenient"

A PAT with broad `repo` scope in a cluster Secret is already not great. But the merge-blocker was the part that actually mattered day to day, because it was silent.

The bot wasn't broken. Its PRs were fine. They had green CI. They were just waiting on a review that the rules said could never come from the only available reviewer. I had accidentally built a system where "doing its job" and "being mergeable" were mutually exclusive.

That's a worse failure mode than a bot that visibly errors out. A bot that errors tells you something is wrong. A bot that silently produces unmergeable work looks healthy for weeks while quietly wasting its own effort.

## The fix: a real, separate bot identity

The goal was simple: Renovate should open PRs as **itself**, not as me. That single change makes the four-eyes gate work the way it's supposed to — the bot proposes, a human (me) reviews and merges.

To do that without giving the bot a long-lived static credential, I built on top of the GitHub App token broker pattern the homelab already uses for Hermes itself. The broker is a tiny service in the cluster that:

1. Authenticates the caller using its own Kubernetes ServiceAccount token (via a `TokenReview` — the cluster confirms "yes, this really is the identity you claim").
2. Signs a GitHub App JWT with a private key it holds (never returned, never logged).
3. Exchanges that JWT for a short-lived GitHub App installation token scoped to exactly one repo.

The key properties that make this preferable to a PAT:

- **No long-lived credential in a Secret.** The token is minted fresh each run, expires in about an hour, and never sits around.
- **Scoped to one repo.** Even if something went wrong, the token only has access to `shubhamwagh/homeops`, not everything I own.
- **Identity comes from the ServiceAccount, not from a file.** The broker checks the caller's real cluster identity, so the bot can't just copy a token file and impersonate something else.

## Giving Renovate its own ServiceAccount

The broker authenticates callers by their Kubernetes ServiceAccount username. So Renovate needed its own, not the shared `default` one that everything in the namespace shares by default.

The chart supports `serviceAccount.create: true` with a custom name, so Renovate now runs as `renovate-token-fetcher` — a dedicated identity that exists for exactly this purpose. The broker's allowlist of expected caller usernames was extended to include it alongside Hermes's own identity.

## Per-run token minting in an initContainer

The Renovate CronJob now has an initContainer that runs before the main Renovate process:

1. Reads its own projected ServiceAccount token from the standard Kubernetes path.
2. Calls the broker's `/v1/token` endpoint with that token as a Bearer credential.
3. Writes the short-lived GitHub token to a shared `emptyDir` volume.
4. The main container's `preCommand` reads that file and exports it as `RENOVATE_TOKEN` in the same shell session Renovate runs in.

The token is never stored in a Secret, never persisted, never reused across runs. Each nightly run gets a fresh one.

There's an `emptyDir` between the initContainer and the main container, but that's fine — it's scoped to this one pod only, and the token expires in about an hour regardless. The value isn't sensitive after the run finishes because it's already expired.

## The chmod bug: first real run, silent failure

The first time I ran this new setup manually to test it, Renovate failed with its own "must configure a GitHub token" error.

The token was being minted and written to the shared file just fine. The problem was the file's permissions.

The initContainer ran as UID 10000 (a non-root user, as it should). It created the token file and set permissions to `0600` — owner read/write only, the "secure" choice. But the Renovate image's main container ran as a **different UID**, and there was no shared `fsGroup` on the volume. So when the main container tried to `cat /shared/token`, it got `Permission denied`, `RENOVATE_TOKEN` ended up empty, and Renovate fell back to its own error.

The fix: `0644` — world-readable within the pod. That sounds alarming until you remember the context: the file is in a pod-scoped `emptyDir`, the token expires in about an hour, and the only reader is the main container in the same pod. `0600` is the "correct" permission in the abstract; `0644` is what actually works here, and the blast radius is negligible because the secret doesn't live past the run.

It's a useful reminder that "secure defaults" can still be wrong in context, and that a first manual test caught a real failure that I'd have missed if I'd just trusted the config and waited for the next scheduled run.

## Removing the old PAT

With the new setup working, the old PAT-based wiring was removed — the `envFrom` reference to the `renovate-github-token` Secret is gone from the CronJob. The actual PAT itself should be revoked on GitHub; the Secret file is left in place for now, unreferenced, until that's confirmed done.

This matters because the old PAT was still a broad `repo`-scope credential sitting in the cluster, even if nothing was using it anymore. "Unreferenced" is not the same as "gone."

## The reviewer config now actually works

One side effect of the identity change: Renovate's config now says `reviewers: ["shubhamwagh"]`, which it always did. But before the fix that setting was silently useless — asking the author to review its own PR is a no-op under branch protection. Now that Renovate opens PRs as a different identity, the reviewer config actually does something: the PR shows up in my review queue as a real request from a separate actor, and the four-eyes gate works.

## What I'd tell past-me

A few things I'd tell the person who first wired up Renovate with a PAT:

- **A bot that authors PRs as you is a review-blocker, not a convenience.** If branch protection requires a separate reviewer, the bot needs a separate identity or it will silently produce unmergeable work.
- **Long-lived static tokens in cluster Secrets are a liability even when they "work."** Short-lived, per-run, scoped tokens via a broker are strictly better, and not much harder once the broker exists.
- **Give automation its own identity, not the default one.** A dedicated ServiceAccount is cheap insurance against identity confusion later.
- **Test the first run manually.** The chmod bug was real and obvious in a manual run; it would have been harder to diagnose from a cron failure log alone.
- **Removing the old credential is part of the fix, not optional cleanup.** An unreferenced PAT is still a credential.

None of this made Renovate less capable. It just made its PRs actuallly mergeable again — which, for a dependency-update bot, is the whole point.

---

*This is part of the [Building a Self-Hosted Homelab](/hello-world/) series — a journal of building and operating this homelab, in the first person. The previous post in this series was [How I Locked Down My Homelab Bot](/how-i-locked-down-my-homelab-bot/).*
