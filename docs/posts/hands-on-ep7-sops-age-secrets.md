---
date: 2026-08-28
description: Encrypt your Kubernetes secrets with SOPS and age so you can commit them to Git without ever storing credentials in plaintext.
categories:
  - Homelab
  - Kubernetes
  - Hands-On Tutorial
tags:
  - homelab
  - kubernetes
  - sops
  - age
  - secrets
  - gitops
  - flux
comments: true
series: Homelab From Scratch (Hands-On Build)
---

# Secrets without plaintext: SOPS + age

So far every config we've committed to Git has been public-friendly. But a real cluster needs
*real* secrets: database passwords, API tokens, app keys. If you commit those as plain
`Secret` manifests, anyone with your repo (or a leaked backup) gets the keys to the kingdom.

The fix we use here is **SOPS + age**: you encrypt the secret *before* it goes into Git. The
repo only ever holds ciphertext. Your GitOps controller (Flux, from
[the last episode](/distributed-storage-with-longhorn/)) decrypts it on the way into the
cluster using a private key that lives *only* in the cluster, never in Git.

By the end of this episode you'll have a secret committed to Git that is unreadable to anyone
who doesn't hold the cluster's private key — and Flux will apply it as a normal `Secret`.

<!-- more -->

## The idea in one picture

```mermaid
flowchart LR
    A[Plaintext secret<br/>myapp-secret.sops.yaml] -->|sops --encrypt<br/>age PUBLIC key| B[Encrypted file<br/>committed to Git]
    B -->|Flux pulls + decrypts<br/>age PRIVATE key in sops-age Secret| C[Real Secret<br/>in the cluster]
    D[you@example.com] -. never in Git .- B
```

Two keys, clearly separated:

- The **public key** (a `age1...` string) lives openly in `.sops.yaml` and in every encrypted
  file. Anyone can *encrypt* with it. That's fine — encryption is the safe operation.
- The **private key** (`AGE-SECRET-KEY-...`) lives *only* in a Kubernetes `Secret` called
  `sops-age`, in your `flux-system` namespace. Flux uses it to decrypt. It is never committed.

!!! info "What are SOPS and age?"
    **SOPS** ("Secrets OPerationS") is a tool from Mozilla that encrypts the *values* inside a
    YAML/JSON file while leaving the structure readable. **age** is a small, modern encryption
    tool; its keys are short `age1...` strings, far simpler than GPG. Together they let you keep
    secrets in Git without a separate vault.

## Step 1 — Install the tools

You need `sops` and `age` on the machine where you'll write secrets (your laptop or the
"admin" box from episode 1).

```text
# macOS
brew install sops age

# Debian/Ubuntu
sudo apt install sops age
```

Verify both are present:

```text
sops --version
age-keygen --version
```

## Step 2 — Generate your age keypair

The private key stays on your machine (and later in the cluster). The public key goes into Git.

```text
age-keygen -o age.agekey
```

Output looks like:

```text
Public key: age1examplepublickeyf0rth3bl0gdem0nl0ngr3adabl3str1ng
```

- `age.agekey` now holds **both** the public and private key. Guard this file like a password.
- Copy the `Public key:` value — you'll paste it into `.sops.yaml` next.

!!! warning "Back up `age.agekey` immediately"
    If you lose this file, every secret encrypted to it becomes **unrecoverable**. Copy it to a
    password manager or an encrypted backup *before* you encrypt anything. There is no recovery.

## Step 3 — Tell SOPS which key to use (`.sops.yaml`)

Create `.sops.yaml` at the root of your cluster Git repo. This is the one file that contains
your public key *in plaintext* — that's expected and safe.

```yaml
creation_rules:
  - path_regex: .*.sops.yaml
    age: age1examplepublickeyf0rth3bl0gdem0nl0ngr3adabl3str1ng
```

The `path_regex` means: "any file ending in `.sops.yaml` gets encrypted with this age key."
That naming convention is what makes the next step automatic.

## Step 4 — Write and encrypt a secret

Create a plaintext secret file. The name *must* end in `.sops.yaml` so the rule above applies.

```yaml
# myapp-secret.sops.yaml  (still plaintext right now)
apiVersion: v1
kind: Secret
metadata:
  name: myapp-secret
  namespace: myapp
stringData:
  API_TOKEN: this-is-a-fake-token-do-not-use
  ADMIN_EMAIL: you@example.com
```

Encrypt it in place:

```text
sops --encrypt --in-place myapp-secret.sops.yaml
```

The file now contains ciphertext — the `API_TOKEN` value is gone, replaced by `ENC[...]`. The
structure (kind, metadata, field names) is still visible, which is what makes encrypted secrets
easy to review in PRs.

## Step 5 — Verify you can decrypt it

Encryption only needs the public key. To *decrypt* locally you need the private key. Point SOPS
at it with an environment variable:

```text
export SOPS_AGE_KEY_FILE=$PWD/age.agekey
sops -d myapp-secret.sops.yaml
```

You should see your original plaintext printed back. That confirms the round-trip works.

!!! tip "Do you need the env var at encrypt time?"
    No. `sops --encrypt` only reads the **public** key from `.sops.yaml`, so you can encrypt on
    any machine. You only need `SOPS_AGE_KEY_FILE` (or `sops -d --age-key ...`) when *decrypting*
    locally, which you rarely do once Flux is set up.

## Step 6 — Put the private key in the cluster

Flux runs *inside* the cluster, so it needs the private key there. Create a `Secret` named
`sops-age` in the `flux-system` namespace, sourced from your local `age.agekey` file:

```text
kubectl create namespace flux-system --dry-run=client -o yaml | kubectl apply -f -
kubectl create secret generic sops-age \
  --namespace=flux-system \
  --from-file=age.agekey \
  --dry-run=client -o yaml | kubectl apply -f -
```

The `--from-file=age.agekey` uploads your local `age.agekey` file under the key `age.agekey`
inside the Secret. Flux looks for exactly that key.

!!! warning "The private key is now in two places"
    Your laptop (`age.agekey`) and the cluster (`sops-age` Secret). Both must be backed up. The
    cluster copy is what lets Flux decrypt — if you delete it, Flux can't apply any encrypted
    secret until you recreate it.

## Step 7 — Tell Flux to decrypt

Your Flux `Kustomization` objects need a `decryption` block so Flux knows to run SOPS before
applying. Add this to any Kustomization that contains encrypted files:

```yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: apps
  namespace: flux-system
spec:
  interval: 10m
  path: ./apps/staging
  prune: true
  sourceRef:
    kind: GitRepository
    name: flux-system
  decryption:
    provider: sops
    secretRef:
      name: sops-age
```

If you haven't bootstrapped Flux yet (or want to set this globally), you can also pass it at
bootstrap time:

```text
flux bootstrap github \
  --owner=YOUR_GITHUB_USER \
  --repository=YOUR_REPO \
  --branch=main \
  --path=clusters/staging \
  --decryption-provider=sops \
  --decryption-secret=sops-age
```

## Step 8 — Use the secret in a pod

Nothing special here — once Flux decrypts `myapp-secret.sops.yaml`, it's a normal `Secret` in the
`myapp` namespace. A Deployment reads it like any other:

```yaml
env:
  - name: API_TOKEN
    valueFrom:
      secretKeyRef:
        name: myapp-secret
        key: API_TOKEN
```

## Step 9 — Commit and let GitOps do the rest

```text
git add .sops.yaml myapp-secret.sops.yaml
git commit -m "Add encrypted myapp secret"
git push
```

Flux reconciles, decrypts the file with the `sops-age` key, and creates `myapp-secret` in the
cluster. Your Git history holds only ciphertext.

## Common mistakes

- **Forgetting the `.sops.yaml` rule before encrypting.** `sops --encrypt --in-place` fails with
  "no creation rule matched" if the filename doesn't match `*.sops.yaml` or `.sops.yaml` is
  missing. Name the file `something.sops.yaml` and keep `.sops.yaml` at the repo root.
- **Committing `age.agekey` by accident.** Add it to `.gitignore` immediately. The only place the
  private key should live is the `sops-age` Secret.
- **Decryption block pointing at the wrong Secret name.** It must be `sops-age` (matching the
  Secret you created in step 6), or Flux errors with "failed to decrypt".
- **Editing an encrypted file by hand.** Never. Edit the plaintext (or `sops -d` to a temp file,
  edit, re-encrypt) — hand-editing ciphertext corrupts it.

## Lessons learned

- Secrets in Git are fine *if* they're encrypted, and SOPS+age keeps that almost frictionless.
- The public key is not secret; the private key is the whole game — guard and back it up.
- Because the file structure stays visible, code review of a secret change still shows *what
  field* changed, just not the value. That's a nice security/usability balance.

!!! info "Going further"
    In a larger setup you might wrap these steps (key generation, bulk encryption, a manifest of
    which secrets are "human-access" vs "machine-only") in a small task runner. The important
    part is the flow above — the wrapper is optional. You can also encrypt with cloud KMS
    (AWS/Azure/GCP) instead of age if your secrets live in those ecosystems; age is the
    lightest option for a homelab.

---

*Part of the [Homelab From Scratch (Hands-On Build)](/) series — continue with
[episode 6: distributed storage with Longhorn](/distributed-storage-with-longhorn/). Next up:
[episode 8: remote access with Headscale].*
