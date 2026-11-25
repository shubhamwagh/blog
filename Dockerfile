FROM python:3.12-slim AS builder
RUN apt-get update && apt-get install -y --no-install-recommends \
    git libcairo2 libfreetype6 libjpeg62-turbo libpng16-16 libz1 \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /src
COPY . .
RUN pip install --no-cache-dir "mkdocs-material[imaging]" mkdocs-rss-plugin
RUN mkdocs build

FROM nginx:alpine
COPY --from=builder /src/site /usr/share/nginx/html

# Relative Location on directory redirects; Cloudflare terminates TLS, so absolute ones point at http://
RUN echo "absolute_redirect off;" > /etc/nginx/conf.d/absolute-redirect.conf
