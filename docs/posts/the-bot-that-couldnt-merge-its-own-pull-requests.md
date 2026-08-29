---
date: 2026-08-29 14:00:00
description: I gave Renovate a job — keep my cluster's dependencies updated. It did, diligently, every morning. The problem: none of its pull requests could ever be merged, and nothing told me. A story about branch protection, bot identities, and the quiet deadlock that ate a month of updates.
categories:
  - Homelab Journal
  - Homelab
  - Kubernetes
  - GitOps
tags:
  - homelab
  - kubernetes
  - gitops
  - renovate
  - ci-cd
  - github
comments: true
series: Building a Self-Hosted Homelab
---

# The Bot That Couldn't Merge Its Own Pull Requests

I have a small robot whose only job is to keep my homelab's software up to date. Every morning it scans my cluster's GitOps repository, spots a dependency that's fallen behind, and opens a tidy little pull request with the bump already done. Set and forget, right?

For weeks it was. The robot worked. Too quietly.

What I didn't notice — because nothing told me — was that **not one of those pull requests was ever mergeable**. They were piling up in a silent traffic jam, and the mechanism behind it is a really good lesson about how "bots" and "branch protection" interact.

<!-- more -->

## The setup: a robot that keeps my dependencies fresh

The robot is [Renovate](https://docs.renovatebot.com/), the standard open-source dependency-update bot. In my cluster it runs as a normal scheduled workload: once a day it looks at everything I track — the Kubernetes components, the Helm charts, the little side utilities — and proposes version bumps as pull requests against the Git repository that drives the cluster (GitOps: git is the source of truth, and the cluster reconciles to whatever's in the repo).

This is exactly the kind of tedious, repetitive task you want automated. I'm not going to manually notice that Cilium shipped a patch release. So I pointed Renovate at the repo and walked away.

And it did its job. New pull requests appeared like clockwork. Green checks. Neat summaries. Everything *looked* healthy.

## The symptom: a silent traffic jam of pull requests

The first hint that something was wrong was mundane: I glanced at the repo and noticed an unusual number of open PRs. Dozens. For dependencies I was *sure* I'd updated.

So I clicked one. It looked fine — tests passed, the diff was a one-line version bump. I went to merge it, and the merge button was… disabled. "Review required by a CODEOWNER or an approving reviewer." But I'm the only maintainer. I'm literally looking at it. Why can't I approve?

Because I *hadn't* opened this PR. My robot had.

## Why "self-approval" is the trap

Here's the trap, and it's beautifully subtle.

My repository enforces **branch protection** on its main branch. That's a GitHub setting (see [About protected branches](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-protected-branches/about-protected-branches)) that says: *you cannot merge a pull request directly; it needs a passing status check and at least one approving review from someone who is not the author of the PR.* This is good hygiene — it stops a careless `git push` (human or bot) from shipping to production unreviewed. I want it on.

The catch is the phrase "**not the author**."

Renovate was authenticating with a **personal access token** — a credential tied to *my* GitHub account. So when it opened a pull request, GitHub recorded the author as me, `shubhamwagh`. Branch protection then looked at the one person available to review — also me — and said: *that's the author, you can't approve your own pull request.* And there was no second human account around to break the tie.

Result: a perfect, silent deadlock. The bot opens PRs as me → I'm barred from approving them → they sit forever → I assume they merged because the checks are green and nobody screamed.

The green checkmarks are the cruel part. Everything about the PR *looked* fine. The only signal that it wasn't mergeable was a greyed-out button I'd never think to click on a bot I trusted.

## The fix: give the bot its own identity

The root cause isn't branch protection (keep that). It's that my robot was wearing *my* identity.

The fix is to give the bot its **own, distinct GitHub identity** — a GitHub App, not a personal token. A GitHub App is a first-class actor: it has its own name, its own permissions, and crucially, its own authorship. When Renovate opens a PR now, it's authored by `app/...`, a separate entity from my human account.

Suddenly the deadlock dissolves:

- The PR is authored by the bot identity.
- *My* human review is now a legitimate, independent approval — exactly what branch protection wanted all along.
- The bot still can't merge (it has no merge permission; that stays with me), but now there's someone who *can* review and merge it: me.

In my setup the bot doesn't even hold a long-lived secret. It asks a small in-cluster broker for a short-lived token at the start of each run, does its work, and the token expires. No PAT sitting in a vault waiting to be abused. The broker only mints tokens for callers it recognizes, and the robot's workload is one of exactly two things allowed to ask. The other is my assistant agent — same broker, its own identity.

## The lesson (and a quiet companion mistake)

Two things stuck with me:

1. **A bot should never share your human identity.** The moment an automation authors changes *as you*, every "author can't review their own change" guardrail you've carefully built becomes a self-inflicted trap. Give automations their own narrowly-scoped GitHub App identities. It's less convenient than a PAT, and that's the point.
2. **Green checks are not "done."** A CI pass proves the change builds. It proves nothing about whether the change can *ship*. I now treat "open PRs from bots" as something to actually look at, not something to assume away.

This pairs with another quiet failure I wrote about — [when Prometheus quietly ran out of disk](/when-prometheus-ran-out-of-disk-a-homelab-monitoring-incident/) and stopped ingesting metrics without a single alarm. The theme of this homelab lately has been *failures that don't announce themselves.* Branch protection didn't fail; my assumption about who the bot was did.

If you run Renovate (or Dependabot, or any bot that opens PRs) on a repo with branch protection, go check who the bot is authoring *as*. If it's you, you've got the same time bomb I had.

---

*Part of the [Building a Self-Hosted Homelab](/hello-world/) series. If you want the big-picture architecture first, start with [how my 3-node k3s homelab actually works](/how-my-3-node-k3s-homelab-actually-works/).*
