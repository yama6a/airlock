# syntax=docker/dockerfile:1

# Its own stage because BuildKit refuses a variable in COPY --from, only in FROM.
ARG UV_VERSION=0.12.0
FROM ghcr.io/astral-sh/uv:${UV_VERSION} AS uv

FROM ubuntu:26.04

ARG TARGETARCH

# renovate: datasource=github-releases depName=kubernetes/kubernetes
ARG KUBECTL_VERSION=v1.35.7
# renovate: datasource=github-releases depName=helm/helm
ARG HELM_VERSION=v3.21.3
# renovate: datasource=github-releases depName=derailed/k9s
ARG K9S_VERSION=v0.51.0
# renovate: datasource=github-releases depName=kubernetes-sigs/kustomize
ARG KUSTOMIZE_VERSION=v5.8.1
# renovate: datasource=github-releases depName=ahmetb/kubectx
ARG KUBECTX_VERSION=v0.11.0
# renovate: datasource=github-releases depName=mikefarah/yq
ARG YQ_VERSION=v4.53.3
# renovate: datasource=github-releases depName=cli/cli
ARG GH_VERSION=2.96.0
# renovate: datasource=github-tags depName=golang/go versioning=regex:^go(?<major>\d+)\.(?<minor>\d+)(\.(?<patch>\d+))?$
ARG GO_VERSION=go1.26.5
# renovate: datasource=github-tags depName=nodejs/node
ARG NODE_VERSION=v26.7.0
# renovate: datasource=go depName=golang.org/x/tools/gopls
ARG GOPLS_VERSION=v0.23.0
# renovate: datasource=go depName=github.com/oapi-codegen/oapi-codegen/v2
ARG OAPI_CODEGEN_VERSION=v2.8.0
# renovate: datasource=go depName=mvdan.cc/gofumpt
ARG GOFUMPT_VERSION=v0.11.0
# renovate: datasource=go depName=golang.org/x/vuln
ARG GOVULNCHECK_VERSION=v1.1.4
# renovate: datasource=github-releases depName=golangci/golangci-lint
ARG GOLANGCI_LINT_VERSION=2.13.1
# renovate: datasource=npm depName=playwright
ARG PLAYWRIGHT_VERSION=1.62.0
# renovate: datasource=pypi depName=pgcli
ARG PGCLI_VERSION=4.5.0
ARG PG_MAJOR=18

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
      apt-transport-https bash build-essential ca-certificates coreutils curl \
      dnsutils fd-find findutils gawk git git-lfs gnupg gosu grep iputils-ping jq \
      less locales make netcat-openbsd openssh-client pkg-config procps psmisc \
      python3 python3-pip python3-venv ripgrep rsync sed socat sqlite3 sudo tig tree unzip vim wget \
      xz-utils zip \
    && ln -s /usr/bin/fdfind /usr/local/bin/fd \
    && sed -i 's/^# *en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen && locale-gen \
    && rm -rf /var/lib/apt/lists/*

# "noble" tracks the ubuntu tag above; a major bump needs this changed by hand.
RUN install -m 0755 -d /etc/apt/keyrings \
    && curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
         -o /etc/apt/keyrings/docker.asc \
    && chmod a+r /etc/apt/keyrings/docker.asc \
    && echo "deb [arch=${TARGETARCH} signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu noble stable" \
         > /etc/apt/sources.list.d/docker.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
         docker-ce-cli docker-buildx-plugin docker-compose-plugin \
    && rm -rf /var/lib/apt/lists/*

# noble again: PGDG names its suites after the distro, so a base image bump needs this changed too.
# Ubuntu's own postgresql-client is a major behind, and the PGDG one talks to older servers fine.
RUN curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc \
      -o /etc/apt/keyrings/postgresql.asc \
    && chmod a+r /etc/apt/keyrings/postgresql.asc \
    && echo "deb [arch=${TARGETARCH} signed-by=/etc/apt/keyrings/postgresql.asc] https://apt.postgresql.org/pub/repos/apt noble-pgdg main" \
         > /etc/apt/sources.list.d/pgdg.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends "postgresql-client-${PG_MAJOR}" \
    && rm -rf /var/lib/apt/lists/*

# kubectx ships x86_64 and node ships x64 where the rest ship amd64.
RUN set -eux; \
    case "${TARGETARCH}" in \
      amd64) alt_arch=x86_64; node_arch=x64 ;; \
      arm64) alt_arch=arm64;  node_arch=arm64 ;; \
      *) echo "unsupported TARGETARCH: ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    \
    curl -fsSL -o /usr/local/bin/kubectl \
      "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${TARGETARCH}/kubectl"; \
    curl -fsSL -o /usr/local/bin/yq \
      "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_${TARGETARCH}"; \
    chmod 0755 /usr/local/bin/kubectl /usr/local/bin/yq; \
    \
    curl -fsSL "https://get.helm.sh/helm-${HELM_VERSION}-linux-${TARGETARCH}.tar.gz" \
      | tar -xz -C /tmp "linux-${TARGETARCH}/helm"; \
    install -m 0755 "/tmp/linux-${TARGETARCH}/helm" /usr/local/bin/helm; \
    \
    curl -fsSL "https://github.com/derailed/k9s/releases/download/${K9S_VERSION}/k9s_Linux_${TARGETARCH}.tar.gz" \
      | tar -xz -C /tmp k9s; \
    install -m 0755 /tmp/k9s /usr/local/bin/k9s; \
    \
    curl -fsSL "https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize%2F${KUSTOMIZE_VERSION}/kustomize_${KUSTOMIZE_VERSION}_linux_${TARGETARCH}.tar.gz" \
      | tar -xz -C /tmp kustomize; \
    install -m 0755 /tmp/kustomize /usr/local/bin/kustomize; \
    \
    curl -fsSL "https://github.com/ahmetb/kubectx/releases/download/${KUBECTX_VERSION}/kubectx_${KUBECTX_VERSION}_linux_${alt_arch}.tar.gz" \
      | tar -xz -C /tmp kubectx; \
    curl -fsSL "https://github.com/ahmetb/kubectx/releases/download/${KUBECTX_VERSION}/kubens_${KUBECTX_VERSION}_linux_${alt_arch}.tar.gz" \
      | tar -xz -C /tmp kubens; \
    install -m 0755 /tmp/kubectx /tmp/kubens /usr/local/bin/; \
    \
    curl -fsSL "https://github.com/cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION}_linux_${TARGETARCH}.tar.gz" \
      | tar -xz -C /tmp "gh_${GH_VERSION}_linux_${TARGETARCH}/bin/gh"; \
    install -m 0755 "/tmp/gh_${GH_VERSION}_linux_${TARGETARCH}/bin/gh" /usr/local/bin/gh; \
    \
    curl -fsSL "https://github.com/golangci/golangci-lint/releases/download/v${GOLANGCI_LINT_VERSION}/golangci-lint-${GOLANGCI_LINT_VERSION}-linux-${TARGETARCH}.tar.gz" \
      | tar -xz -C /tmp "golangci-lint-${GOLANGCI_LINT_VERSION}-linux-${TARGETARCH}/golangci-lint"; \
    install -m 0755 "/tmp/golangci-lint-${GOLANGCI_LINT_VERSION}-linux-${TARGETARCH}/golangci-lint" /usr/local/bin/golangci-lint; \
    \
    curl -fsSL "https://go.dev/dl/${GO_VERSION}.linux-${TARGETARCH}.tar.gz" \
      | tar -xz -C /usr/local; \
    curl -fsSL "https://nodejs.org/dist/${NODE_VERSION}/node-${NODE_VERSION}-linux-${node_arch}.tar.xz" \
      | tar -xJ -C /usr/local; \
    mv "/usr/local/node-${NODE_VERSION}-linux-${node_arch}" /usr/local/node; \
    \
    rm -rf /tmp/*

ENV PATH=/usr/local/go/bin:/usr/local/node/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# Most Python MCP servers launch with uvx, and gopls backs the Go LSP plugin.
COPY --from=uv /uv /uvx /usr/local/bin/
RUN export GOFLAGS=-trimpath GOBIN=/usr/local/bin \
    && go install "golang.org/x/tools/gopls@${GOPLS_VERSION}" \
    && go install "github.com/oapi-codegen/oapi-codegen/v2/cmd/oapi-codegen@${OAPI_CODEGEN_VERSION}" \
    && go install "mvdan.cc/gofumpt@${GOFUMPT_VERSION}" \
    && go install "golang.org/x/vuln/cmd/govulncheck@${GOVULNCHECK_VERSION}" \
    && rm -rf /root/go /root/.cache/go-build

# uv drops a tool under $HOME, which --rm discards, so bake the venv at a path every user can read.
# UV_TOOL_DIR stays out of ENV: pointing a runtime user at this root-owned dir breaks their own
# `uv tool install`, and the launcher in /usr/local/bin already names the venv by absolute path.
RUN UV_TOOL_DIR=/opt/uv-tools UV_TOOL_BIN_DIR=/usr/local/bin uv tool install --no-cache \
      --python /usr/bin/python3 "pgcli==${PGCLI_VERSION}" \
    && chmod -R a+rX /opt/uv-tools

# Baked at a shared path: the container drops to non-root and --rm discards runtime downloads.
ENV PLAYWRIGHT_BROWSERS_PATH=/opt/ms-playwright
# --with-deps picks the apt list for this distro, so it cannot drift from the browser version.
RUN npx -y "playwright@${PLAYWRIGHT_VERSION}" install --with-deps chromium \
    && chmod -R a+rX /opt/ms-playwright \
    && rm -rf /var/lib/apt/lists/* /root/.npm

# Fixed path, not a user home, so the image carries no user and the entrypoint can pick one.
RUN HOME=/opt/claude sh -c 'mkdir -p /opt/claude && curl -fsSL https://claude.ai/install.sh | bash' \
    && ln -s /opt/claude/.local/bin/claude /usr/local/bin/claude \
    && chmod -R a+rX /opt/claude \
    && claude --version

ENV LANG=en_US.UTF-8 \
    LC_ALL=en_US.UTF-8 \
    DISABLE_AUTOUPDATER=1 \
    CLAUDE_CODE_OAUTH_401_WAIT_MS=60000

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod 0755 /usr/local/bin/entrypoint.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["claude"]
