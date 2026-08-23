---
date: 2026-08-22
description: The boxes, the OS, and the four boring-but-mandatory steps (static IPs, SSH keys, hostnames, firewall) that make a homelab reliable. Includes the 1-node starter path and how to grow to 3.
categories:
  - Hands-On Tutorial
  - Homelab
  - Kubernetes
tags:
  - homelab
  - kubernetes
  - k3s
  - ubuntu
comments: true
series: Homelab From Scratch (Hands-On Build)
---

# Before you start: hardware + OS baseline

In the [previous post](/start-here-a-hands-on-homelab-from-3-mini-pcs/) I laid out what we're
going to build across this series: a small but real Kubernetes cluster you actually run at home.
Before any of that is fun, we need a boring-but-mandatory foundation — the metal, the OS, and
four things that quietly decide whether your cluster is reliable or a source of 2 a.m. surprises.

If you skip the baseline, everything downstream (networking, storage, GitOps) becomes
mysteriously flaky. So we do this part properly, once.

<!-- more -->

## What you actually need: 3 mini PCs

You don't need a rack, enterprise switches, or a loud server in the hallway. The whole cluster
in this series runs on three cheap 1-litre mini PCs — the kind of HP EliteDesk 800 G2 DM
(35 W) boxes you can pick up second-hand for pocket change. Specs that work well:

| Role | What it does | Minimum I'd buy |
| --- | --- | --- |
| control-plane | runs the Kubernetes API + scheduler | 4 cores, 8 GB RAM, 120 GB SSD |
| worker ×2 | runs your actual workloads | 4 cores, 8 GB RAM, 240 GB SSD/NVMe |

Why three? One node teaches you k3s. Two gives you room to reschedule when one reboots. Three is
the smallest number where storage can be replicated and you survive a single node dying — which
is the difference between "a toy" and "production *for a homelab*" (honest limits discussed in the
final episode).

!!! tip "Start with one if you're unsure"
    You can absolutely begin with a single mini PC. k3s, Cilium, and Traefik all run happily on
    one node. You only *need* three once we get to replicated storage (Longhorn) and want a node
    to fail without taking your apps down. Build the first node now, learn the flow, then clone
    it twice. I'll show both paths below.

Here's the shape of the target cluster (IPs are illustrative — use whatever your LAN gives you):

```text
        ┌─────────────┐
        │  Router     │  192.168.1.1
        │   (LAN)     │
        └──────┬──────┘
     ┌─────────┼─────────┐
     ▼         ▼         ▼
  ┌──────┐  ┌──────┐  ┌──────┐
  │node1 │  │node2 │  │node3 │
  │ ctrl │  │worker│  │worker│
  │ .21  │  │ .22  │  │ .23  │
  └──────┘  └──────┘  └──────┘
   (all on 192.168.1.0/24)
```

## Step 0 — Install the OS

Use **Ubuntu 24.04 LTS** Server (the real stack does; Debian 12 works too if you prefer it). Flash
the image to a USB stick with [Balena Etcher](https://etcher.balena.io), boot each box, and run
the installer. When it asks for a hostname, give each node a stable name — `node1`, `node2`,
`node3` — because Kubernetes and everything on top will use that name forever.

Create a user during install (we'll call it `ubuntu` in examples) and **make sure you set up an
SSH key or a password you'll remember** — you'll be SSHing in from your laptop a lot.

## Step 1 — Give every node a static IP

Kubernetes nodes must be reachable at a stable address. If your router re-issues DHCP leases and
`node2` suddenly becomes `.87` instead of `.22`, the cluster falls apart. So we pin a static IP on
each node with netplan.

First, find your interface name and gateway:

```bash
ip addr        # look for your primary interface, e.g. eno1 or eth0
ip route       # the "default via" line is your gateway (often 192.168.1.1)
```

Then edit the netplan file (the name varies — `50-cloud-init.yaml` is common):

```bash
sudo nano /etc/netplan/50-cloud-init.yaml
```

```yaml
network:
  version: 2
  ethernets:
    eno1:                 # replace with YOUR interface name
      dhcp4: no
      addresses:
        - 192.168.1.21/24 # set per node: .21, .22, .23
      routes:
        - to: default
          via: 192.168.1.1
      nameservers:
        addresses:
          - 8.8.8.8
          - 8.8.4.4
```

Apply it and confirm it stuck:

```bash
sudo netplan apply
ip a                       # confirm the static address is there
ping -c 3 8.8.8.8          # confirm you still have internet
```

!!! warning "Do this before you walk away"
    A typo in the gateway or subnet will lock you out of the network on next boot. After
    `netplan apply`, verify `ip a` shows the right address and `ping 8.8.8.8` works *before* you
    close the console. Keep a keyboard+monitor handy for the first reboot.

## Step 2 — SSH keys (passwordless, from your laptop)

You'll drive all three nodes from a "control machine" (your laptop). Generate an SSH key once if
you don't have one, then copy it to each node:

```bash
# on your laptop, if you don't already have a key:
ssh-keygen -t ed25519 -C "homelab"

# copy it to every node (type the node's password when prompted):
ssh-copy-id ubuntu@192.168.1.21
ssh-copy-id ubuntu@192.168.1.22
ssh-copy-id ubuntu@192.168.1.23
```

Add friendly aliases to `~/.ssh/config` on your laptop so you can `ssh node1` instead of typing
IPs:

```text
# ~/.ssh/config  (on your laptop, not the nodes)
Host node1
    HostName 192.168.1.21
    User ubuntu

Host node2
    HostName 192.168.1.22
    User ubuntu

Host node3
    HostName 192.168.1.23
    User ubuntu
```

## Step 3 — One-time node prep (do this on EVERY node)

These four steps make the later Kubernetes bits work. Run them on all three boxes (or script it —
the real repo documents these exact steps, and automates the k3s install with Ansible + k3sup in
the next episode):

```bash
# 1. Packages Longhorn storage needs later
sudo apt update && sudo apt install -y open-iscsi nfs-common cifs-utils

# 2. Enable iSCSI (Longhorn uses it for block storage)
sudo systemctl enable --now iscsid

# 3. Kernel modules Cilium needs for eBPF networking
sudo modprobe iptable_raw xt_socket
echo -e "xt_socket\niptable_raw" | sudo tee /etc/modules-load.d/cilium.conf

# 4. Passwordless sudo - k3sup logs in over SSH and needs root without a prompt
echo "ubuntu ALL=(ALL) NOPASSWD:ALL" | sudo tee /etc/sudoers.d/ubuntu

# 5. Turn off the host firewall - k3s + Cilium manage their own network rules
sudo ufw disable
```

!!! info "Why disable the host firewall?"
    Step 5 above runs `sudo ufw disable` on each node. That sounds scary, so here's the honest
    reasoning: k3s opens a pile of ports and Cilium manages its own eBPF networking rules. A host
    `ufw` firewall fighting Cilium is a classic cause of "pods can't talk to each other" bugs.
    **This is safe only because the nodes live on a trusted LAN behind your router** — they are
    not directly exposed to the public internet. If your nodes were public-facing, you'd do this
    very differently. Keep them on your home network.

## Step 4 — Verify the baseline before moving on

Don't proceed until every node answers. From your laptop:

```bash
ssh node1 hostname
ssh node2 hostname
ssh node3 hostname

ssh node1 systemctl is-active iscsid
ssh node2 systemctl is-active iscsid
ssh node3 systemctl is-active iscsid
```

If all three hostnames print and all three report `active` for iscsid, your foundation is solid.

!!! tip "The 1-node path, scaled up"
    If you started with just `node1`: do Steps 1–3 on that one box, and in the next episode
    you'll run `make configure` with a single control-plane IP and no workers. To grow to three
    later, repeat Steps 1–3 on `node2`/`node3`, then point the tooling at all three nodes and
    re-run `make bootstrap` — k3s joins the new workers to the existing cluster with no reinstall.
    (Heads-up: `make configure` only runs once; to add nodes later you either delete and recreate
    the inventory it wrote, or use the dedicated `make add-node` target. Either way, the bootstrap
    playbook skips nodes that already have k3s, so your first node is left untouched.) No need to
    start over.

## Common mistakes

- **DHCP instead of static IPs** — the #1 cause of "my cluster broke overnight." Pin them.
- **Wrong netplan interface name** — `eno1` on one box might be `eth0` on another. Always check
  `ip addr` first.
- **Forgetting iSCSI** — Longhorn won't create volumes without `open-iscsi` + `iscsid` running.
  Fix it now, not at 2 a.m. during the storage episode.
- **Password SSH but no key** — automation (k3sup, Ansible) needs key-based, passwordless auth.
  Set up the key in Step 2.

## What's next

With the metal awake, IPs pinned, and SSH working, we're ready to actually install Kubernetes.
That's [episode 2: install k3s across 3 nodes] — we'll bootstrap k3s over SSH with k3sup and get
a working cluster in minutes.

---

*Part of the [Homelab From Scratch (Hands-On Build)](/) series — start with [What's coming: build a
real homelab from 3 mini PCs](/start-here-a-hands-on-homelab-from-3-mini-pcs/).*
