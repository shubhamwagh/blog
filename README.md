# blog

**Building things, breaking things, writing it down.**

Live at [blog.shublab.com](https://blog.shublab.com)

---

## How it is hosted

The blog runs self-hosted on a bare-metal k3s homelab and is publicly accessible via Cloudflare Tunnel - no ports open on the home network.

```mermaid
flowchart LR
    subgraph github["GitHub"]
        REPO["shubhamwagh/blog\nmarkdown posts"]
        ACTIONS["GitHub Actions\nbuild Docker image"]
        GHCR["ghcr.io/shubhamwagh/blog\n:latest"]
    end

    subgraph cluster["k3s Cluster (LAN)"]
        POD["blog pod\nnginx + MkDocs static site"]
        CLOUDFLARED["cloudflared\n2 replicas"]
    end

    subgraph cf["Cloudflare"]
        EDGE["Cloudflare Edge\nblog.shublab.com"]
    end

    INTERNET["🌐 Public Internet"]

    REPO -- "git push" --> ACTIONS
    ACTIONS -- "push image" --> GHCR
    GHCR -- "pulled by k8s" --> POD
    POD -- "HTTP" --> CLOUDFLARED
    CLOUDFLARED -- "outbound tunnel\n(no open ports)" --> EDGE
    EDGE -- "HTTPS" --> INTERNET
```

## Writing a post

```bash
# create a new post
cd docs/posts
cp hello-world.md my-new-post.md
# edit, commit, push - GitHub Actions builds and deploys automatically
git add . && git commit -m "post: my new post" && git push
```

## Stack

- [MkDocs Material](https://squidfunk.github.io/mkdocs-material/) - static site generator
- [GitHub Actions](https://github.com/features/actions) - CI/CD, builds Docker image on push
- [ghcr.io](https://ghcr.io) - container registry
- [k3s](https://k3s.io) - lightweight Kubernetes
- [Cloudflare Tunnel](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/) - public exposure without open ports
- [giscus](https://giscus.app) - comments powered by GitHub Discussions
