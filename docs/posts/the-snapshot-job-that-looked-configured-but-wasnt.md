---
date: 2026-09-12 17:00:00
description: The snapshot job looked configured — a daily cron, retain 7, applied by Flux. But it silently didn't run on 13 of 14 volumes, and the one orphaned snapshot on Prometheus's disk is what filled it up. The missing `groups:` field, and why "looks configured" isn't "is configured".
categories:
  - Homelab Journal
  - Homelab
  - Kubernetes
  - Storage
  - Monitoring
tags:
  - homelab
  - kubernetes
  - longhorn
  - storage
  - snapshots
  - incident
  - gitops
comments: true
series: Building a Self-Hosted Homelab
---

# The Snapshot Job That Looked Configured — But Wasn't

The thing that was supposed to prevent the disk-full incident… wasn't doing its job.

In a [previous post](/when-prometheus-ran-out-of-disk-a-homelab-monitoring-incident/) I wrote about Prometheus's volume hitting 97.6% full and the GitOps gotcha that almost left the fix undone. What I didn't know then — and only figured out weeks later — was *why* the disk had been creeping up in the first place. The snapshot job that was supposed to prune old copies silently wasn't running on almost any volume in the cluster.

<!-- more -->

## The job that looked right

Longhorn's snapshot system is configured with a `RecurringJob` resource — a cron schedule, a task type, a retain count. The one in this cluster looked like this:

```yaml
apiVersion: longhorn.io/v1beta2
kind: RecurringJob
metadata:
  name: snapshot-daily
  namespace: longhorn-system
spec:
  name: snapshot-daily
  cron: "0 2 * * *"
  task: snapshot
  retain: 7
  concurrency: 1
  labels:
    category: critical-data
    type: snapshot
```

Daily at 2am, keep 7 snapshots, one at a time. Applied by Flux, present in git, showing up in `kubectl get recurringjob`. It looked correct. It *was* correct — for a single volume that happened to be manually enrolled.

The problem: **there was no `groups:` field.**

## How Longhorn RecurringJobs actually target volumes

A Longhorn `RecurringJob` doesn't automatically apply to every volume. It applies to *groups*. If you don't specify `groups:`, the job targets… nothing. No volumes. The job runs on schedule, does its work on zero objects, and reports success.

The only reason *any* snapshot existed on *any* volume was that one volume had been manually added to a group at some point. The other 13 volumes — including Prometheus's — had a single orphaned one-off snapshot from a redeploy in August that nothing ever touched again.

So the job was "running" every night. It just had nothing to run *on*.

## The connection to the Prometheus incident

Prometheus's volume was one of the 13 that never got a recurring snapshot. The one-off snapshot from the 2026-08-20/21 redeploy sat there, unpruned, for 20 days. It grew to ~48 GiB — almost the entire disk. That's what pushed the volume past the threshold and started the incident I wrote about before.

The disk-full wasn't just a retention-size misconfiguration. It was a snapshot-pruning failure that had been silent for months.

## The fix

Two lines:

```yaml
spec:
  name: snapshot-daily
  groups:
    - default
  cron: "0 2 * * *"
```

`groups: [default]` tells Longhorn to apply this job to every volume in the default group — which is every volume that doesn't explicitly opt out. After that, the job started snapshotting and pruning on schedule across all 14 volumes.

The Prometheus snapshot that was already there had to be deleted directly against the live cluster to reclaim the space immediately. The RecurringJob fix prevents it from coming back.

## Why this is sneakier than an overt failure

A job that errors is loud — you see the error. A job that runs successfully on zero objects is silent. `kubectl get recurringjob` shows it exists and is applied. Flux shows it reconciled. There's no signal that it's doing nothing.

The only way to catch this is to look at the actual volumes and check whether they have snapshots:

```bash
kubectl get volumes -n longhorn-system \
  -o custom-columns=NAME:.metadata.name,SIZE:.spec.size,STATE:.status.state
```

Then for any volume that should be snapshotted, check its snapshot count. If it's zero (or stuck at one from months ago), the job isn't reaching it.

## Lessons learned

- **"Present in git" ≠ "doing work."** A resource can be applied, reconciled, and still operate on zero objects. Verify the actual effect, not just the definition.
- **Longhorn RecurringJobs need explicit `groups:`.** Without it, the job is a no-op. This isn't obvious from the schema — the field is optional, and the job applies cleanly without it.
- **Silent no-ops are the worst failure mode.** No error, no alert, no signal. The only symptom is the *absence* of the thing that should have happened (rotating snapshots).
- **Pruning is part of the feature.** Snapshots without retention are just disk leaks. The snapshot feature is only half-useful without a working RecurringJob behind it.

## Wrapping up

The Prometheus disk incident had two root causes, not one. The retention-size misconfiguration I wrote about was the immediate trigger. But the reason the disk had been creeping up at all was a snapshot job that looked configured but silently did nothing on 13 of 14 volumes. Two lines fixed it — after weeks of not knowing it was broken.

This is part of the Building a Self-Hosted Homelab series — the previous post was [When Prometheus Ran Out of Disk: A Homelab Monitoring Incident](/when-prometheus-ran-out-of-disk-a-homelab-monitoring-incident/).