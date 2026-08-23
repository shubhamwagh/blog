---
date: 2026-08-23
description: The moment the metal becomes a cluster — install k3s across 3 nodes with k3sup over SSH, grab a kubeconfig, and let Cilium take over networking. Makefile wrapper and raw commands shown side-by-side.
categories:
  - Hands-On Tutorial
  - Homelab
  - Kubernetes
tags:
  - homelab
  - kubernetes
  - k3s
  - k3sup
  - cilium
comments: true
series: Homelab From Scratch (Hands-On Build)
---

# Install k3s across 3 nodes

In the [previous post](/before-you-start-hardware--os-baseline/) we woke the metal: three mini PCs
with static IPs, SSH keys, and the boring-but-mandatory OS prep. Now the fun part — turning those
three boxes into one Kubernetes cluster.

If "install Kubernetes" sounds like a weekend of YAML and regret, good news: **k3s** is a
single-binary, certified Kubernetes distro that boots in seconds, and a tiny tool called
**k3sup** installs it over SSH so you never touch a node's console again. By the end of this
episode you'll have a working 3-node cluster and a `kubeconfig` on your laptop.

<!-- more -->

## What we're building (and why k3s)

"Kubernetes" usually conjures up a control-plane of five etcd nodes, a load balancer, and a
support contract. k3s throws most of that away: it's the same APIs, but packaged as one small
binary (~100 MB) with the heavy enterprise bits stripped out. For a homelab that's perfect — it
runs on a Raspberry Pi-class box and still speaks real Kubernetes.

The architecture we're aiming for:

```text
        ┌─────────────┐
        │  Router     │  192.168.1.1
        │   (LAN)     │
        └──────┬──────┘
               │
        ┌──────▼──────┐        k3s API (6443)
        │  node1      │◄───────────────┐
        │  control-   │                │
        │  plane      │                │
        │   .21       │                │
        └─────────────┘                │
              ▲                        │
       k3s API│                        │
              ├───────────────►┌───────┴──────┐
              │                │  node2        │
              │                │  worker       │
              │                │   .22         │
              │                └───────────────┘
              │                ┌───────────────┐
              └───────────────►│  node3        │
                               │  worker       │
                               │   .23         │
                               └───────────────┘
         (all on 192.168.1.0/24 — illustrative; use your LAN)
```

One node is the **control-plane** (it runs the API server + scheduler). The other two are
**workers** (they run your actual workloads). The workers "join" the control-plane over the k3s
API port (6443).

!!! info "Who is k3sup?"
    [k3sup](https://github.com/alexellis/k3sup) is a little Go tool from Alex Ellis. You run it
    from your laptop; it SSHes into each node, installs k3s, and writes a `kubeconfig` back to
    you. It's the difference between "I clicked through a GUI on every node" and "one command
    provisioned the whole cluster." The `make` commands below are just a friendly wrapper around
    it.

## Step 0 — Get the tools on your laptop

You need two things on your **control machine** (the laptop you SSH from): `k3sup` and `kubectl`.
The repo pins exact versions with [mise](https://mise.jdx.dev) and install them via Homebrew:

```bash
# from the homeops repo root
make tools        # runs `brew bundle` + `mise install`
```

If you're not on a Mac or don't use Homebrew, install them directly:

```bash
# k3sup
curl -sLS https://get.k3sup.dev | sh
sudo install k3sup /usr/local/bin/

# kubectl (Linux example; pick your arch)
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
sudo install kubectl /usr/local/bin/
```

Verify both are on your `PATH`:

```bash
k3sup version
kubectl version --client
```

## Step 1 — Tell the tooling about your nodes (`make configure`)

The installer needs to know your nodes' IPs, SSH user, and a shared cluster token. The repo
captures that in an **inventory** file via an interactive prompt:

```bash
make configure
```

It will ask, one line at a time:

```text
SSH user [ubuntu]:
SSH key path [~/.ssh/id_ed25519]:
Control-plane IPs (space-separated): 192.168.1.21
Worker IPs (space-separated, or blank): 192.168.1.22 192.168.1.23
Cluster name [homelab-cluster]:
k3s token (blank = auto-generate):
```

What it writes (both git-ignored, so they never get committed):

- `infrastructure/metal/inventory.yml` — the list of nodes and their SSH details.
- `infrastructure/metal/group_vars/all.yml` — the cluster name, the shared token, and the
  k3s feature flags below.

The token is what lets workers prove they belong to the cluster. Leave it blank and the script
generates a random one for you with `openssl rand -hex 16`.

!!! tip "1-node? Put one IP in control-plane, leave workers blank"
    Building the cluster on a single mini PC first? Enter just `192.168.1.21` for control-plane
    and hit enter on the worker prompt. You'll get a perfectly valid single-node k3s. To grow to
    three later, delete `infrastructure/metal/inventory.yml` and re-run `make configure`, or hand-edit the inventory to add the worker IPs under `workers:`, then run `make add-node` —
    k3s joins the new workers to the existing cluster with no reinstall.

## Step 2 — Install the cluster (`make bootstrap`)

This is the whole show. One command:

```bash
make bootstrap
```

It runs three things in order:

1. **`install`** — the Ansible playbook SSHes into each node and runs `k3sup install` (control-plane)
   and `k3sup join` (workers) over SSH.
2. **`copy-kubeconfig`** — copies the cluster's kubeconfig off the control-plane and rewrites
   `127.0.0.1` to the node's real IP, so `kubectl` from your laptop can reach it.
3. **`cilium-bootstrap`** — installs Cilium (the CNI/networking layer) with Helm.

Give it a minute. When it finishes, you should be able to talk to your cluster:

```bash
make nodes          # = kubectl get nodes -o wide
```

You're looking for three rows, all `Ready`:

```text
NAME    STATUS   ROLES                  VERSION        INTERNAL-IP
node1   Ready    control-plane,master   v1.32.x        192.168.1.21
node2   Ready    <none>                 v1.32.x        192.168.1.22
node3   Ready    <none>                 v1.32.x        192.168.1.23
```

## What `make bootstrap` actually runs (the 3 lines that matter)

The wrapper hides the details, but it helps to see what k3sup is really doing on each node.

**Control-plane (init node):**

```bash
k3sup install \
  --host 192.168.1.21 \
  --user ubuntu \
  --ssh-key ~/.ssh/id_ed25519 \
  --k3s-extra-args '--cluster-init --token <TOKEN> --tls-san 192.168.1.21 \
    --write-kubeconfig-mode=644 \
    --disable=flannel,local-storage,metrics-server,servicelb,traefik \
    --flannel-backend=none --disable-network-policy \
    --disable-cloud-controller --disable-kube-proxy' \
  --local-path ~/.kube/config --context homelab-cluster --merge
```

**Workers (join the control-plane):**

```bash
k3sup join \
  --host 192.168.1.22 \
  --user ubuntu \
  --ssh-key ~/.ssh/id_ed25519 \
  --server-host 192.168.1.21 \
  --server-user ubuntu \
  --k3s-extra-args '--token <TOKEN>'
```

Two flags deserve a callout, because they shape everything later:

- **`--disable=flannel,...,traefik --disable-kube-proxy --flannel-backend=none`** — we *deliberately*
  turn k3s's built-in networking (flannel), service load-balancer, and ingress (traefik) **off**.
  Why? Because we're going to install **Cilium** as the networking layer and **Traefik** as the
  ingress later, and running two of everything causes fights. Starting clean is the point.
- **`--cluster-init`** on the first control-plane — it tells k3s "you're the first server; others
  will join you." (The repo always passes `--cluster-init` to the init node — including a single-node cluster — so you don't toggle anything.)

!!! info "Going further: what Cilium actually does"
    `cilium-bootstrap` installs Cilium with `kubeProxyReplacement=true` and eBPF-based masquerade.
    In plain terms: Cilium handles pod networking, load-balancing, and network policy *in the
    Linux kernel* instead of via kube-proxy's iptables rules. That's faster and lets us do fancy
    things later (like giving a service a LAN IP). You don't need to understand eBPF today — just
    know that `make bootstrap` wired it in so the cluster has working networking from minute one.

## Verify before you celebrate

Don't trust the exit code — confirm the cluster is actually healthy:

```bash
kubectl get nodes -o wide
kubectl get pods -A          # system pods should be Running, not CrashLoopBackOff
cilium status --wait         # if you installed cilium-cli; otherwise skip
```

A healthy cluster: 3 `Ready` nodes, and the `kube-system` / `cilium` pods all `Running`.

## Common mistakes

- **Wrong SSH key path in `make configure`** — if k3sup can't authenticate, the install hangs or
  fails fast. Double-check the path it printed and that `ssh node1` works from your laptop first.
- **Forgetting the worker IPs** — if you leave workers blank by accident, you get a 1-node cluster
  and wonder why `kubectl get nodes` shows one row. Re-run `make configure` (delete the inventory
  it wrote, or hand-edit it) and `make add-node`.
- **Nodes not `Ready`** — 9 times out of 10 this is the OS baseline from the previous post:
  missing iSCSI (Longhorn will complain later, not now), or the host firewall fighting Cilium.
  Re-check ep1's Step 3.
- **Two networking stacks** — if you ever re-run bootstrap without the `--disable` flags, you'll
  have flannel *and* Cilium both trying to own pod networking. That's a world of packet loss. The
  repo's flags already disable flannel, so don't add it back.

## What's next

You have a real, multi-node Kubernetes cluster in your living room. But right now it's just
infrastructure with no *story* — no GitOps, no ingress, no apps. In [episode 3: networking with
Cilium + a load-balancer VIP] we'll go deeper on Cilium and give a service a real LAN IP so you
can reach it without port-forwarding gymnastics.

---

*Part of the [Homelab From Scratch (Hands-On Build)](/) series — start with [What's coming: build a
real homelab from 3 mini PCs](/start-here-a-hands-on-homelab-from-3-mini-pcs/), then
[Before you start: hardware + OS baseline](/before-you-start-hardware--os-baseline/).*
