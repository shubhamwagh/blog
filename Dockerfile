FROM python:3.12-slim AS builder
RUN apt-get update && apt-get install -y --no-install-recommends git && rm -rf /var/lib/apt/lists/*
WORKDIR /src
COPY . .
RUN pip install --no-cache-dir mkdocs-material mkdocs-rss-plugin
RUN mkdocs build

FROM nginx:alpine
COPY --from=builder /src/site /usr/share/nginx/html
