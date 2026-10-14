ARG ARGOCD_VERSION="v3.5.5"

# Patched argocd binary.
#
# patches/*.patch are upstream argo-cd commits we need before they ship in a
# release. They are applied on top of the ARGOCD_VERSION tag, the binary
# (server, controller, repo-server and the embedded UI are all one binary) is
# rebuilt, and it replaces /usr/local/bin/argocd in the upstream image below.
# Stages and toolchain pins follow upstream's own Dockerfile. Drop a patch once
# ARGOCD_VERSION contains it; a patch that no longer applies fails the build.
FROM --platform=$BUILDPLATFORM docker.io/library/golang:1.26.9@sha256:f1f0bcc2c524a3ced375fcb4d1ecb7aa371aa7070e112599aaca45cc02d0101b AS argocd-src
ARG ARGOCD_VERSION
WORKDIR /src
RUN git clone --quiet --depth 1 --branch "${ARGOCD_VERSION}" https://github.com/argoproj/argo-cd.git .
COPY patches/ /patches/
RUN for p in /patches/*.patch; do \
      [ -e "$p" ] || continue; \
      git -c user.name=docker-argocd -c user.email=docker-argocd@localhost am "$p" || exit 1; \
    done

FROM --platform=$BUILDPLATFORM docker.io/library/node:24.14.1@sha256:80fc934952c8f1b2b4d39907af7211f8a9fff1a4c2cf673fb49099292c251cec AS argocd-ui
WORKDIR /src
COPY --from=argocd-src /src/ui/package.json /src/ui/pnpm-lock.yaml ./
RUN npm install -g corepack@0.34.6 && corepack enable && pnpm install --frozen-lockfile
COPY --from=argocd-src /src/ui/ .
ARG ARGOCD_VERSION
ENV ARGO_VERSION=$ARGOCD_VERSION
RUN NODE_ENV='production' NODE_ONLINE_ENV='online' NODE_OPTIONS=--max_old_space_size=8192 pnpm build

FROM --platform=$BUILDPLATFORM docker.io/library/golang:1.26.9@sha256:f1f0bcc2c524a3ced375fcb4d1ecb7aa371aa7070e112599aaca45cc02d0101b AS argocd-build
WORKDIR /go/src/github.com/argoproj/argo-cd
COPY --from=argocd-src /src/ .
RUN go mod download
COPY --from=argocd-ui /src/dist/app ui/dist/app
ARG TARGETOS \
    TARGETARCH
RUN GOOS=$TARGETOS GOARCH=$TARGETARCH make argocd-all

FROM quay.io/argoproj/argocd:$ARGOCD_VERSION

# The upstream image symlinks every argocd-* entrypoint to this one binary.
COPY --from=argocd-build /go/src/github.com/argoproj/argo-cd/dist/argocd /usr/local/bin/argocd

LABEL org.opencontainers.image.source="https://github.com/snapp-incubator/docker-argocd" \
      org.opencontainers.image.description="Argo CD with helm-secrets (SOPS/vals) baked in"

ARG SOPS_VERSION=3.9.0
ARG KUBECTL_VERSION=1.30.2
ARG VALS_VERSION=0.37.3
ARG HELM_SECRETS_VERSION=4.7.7
# Pin curl instead of pulling "latest" so builds are reproducible.
ARG CURL_VERSION=8.17.0

# vals or sops
ENV HELM_SECRETS_BACKEND=sops \
    HELM_SECRETS_VALUES_ALLOW_SYMLINKS=false \
    HELM_SECRETS_VALUES_ALLOW_ABSOLUTE_PATH=true \
    HELM_SECRETS_VALUES_ALLOW_PATH_TRAVERSAL=false \
    HELM_SECRETS_WRAPPER_ENABLED=true \
    HELM_SECRETS_DECRYPT_SECRETS_IN_TMP_DIR=true \
    HELM_SECRETS_LOAD_GPG_KEYS=/app/config/gpg/privkey.asc \
    HELM_PLUGINS=/gitops-tools/helm-plugins/ \
    HELM_SECRETS_HELM_PATH=/usr/local/bin/helm \
    HELM_SECRETS_CURL_PATH=/gitops-tools/curl \
    HELM_SECRETS_SOPS_PATH=/gitops-tools/sops \
    HELM_SECRETS_VALS_PATH=/gitops-tools/vals \
    HELM_SECRETS_KUBECTL_PATH=/gitops-tools/kubectl \
    PATH="$PATH:/gitops-tools"

USER root
RUN apt-get update && \
    apt-get install -y \
      wget && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/* && \
    mkdir -p /gitops-tools/helm-plugins

RUN \
    GO_ARCH=$(uname -m | sed -e 's/x86_64/amd64/') && \
    wget -qO "/gitops-tools/curl" "https://github.com/moparisthebest/static-curl/releases/download/v${CURL_VERSION}/curl-${GO_ARCH}" && \
    true

RUN \
    GO_ARCH=$(uname -m | sed -e 's/x86_64/amd64/' -e 's/\(arm\)\(64\)\?.*/\1\2/' -e 's/aarch64$/arm64/') && \
    wget -qO "/gitops-tools/kubectl" "https://dl.k8s.io/release/v${KUBECTL_VERSION}/bin/linux/${GO_ARCH}/kubectl" && \
    true

# sops backend installation (optional)
RUN \
    GO_ARCH=$(uname -m | sed -e 's/x86_64/amd64/' -e 's/\(arm\)\(64\)\?.*/\1\2/' -e 's/aarch64$/arm64/') && \
    wget -qO "/gitops-tools/sops" "https://github.com/getsops/sops/releases/download/v${SOPS_VERSION}/sops-v${SOPS_VERSION}.linux.${GO_ARCH}" && \
    true

# vals backend installation (optional)
RUN \
    GO_ARCH=$(uname -m | sed -e 's/x86_64/amd64/' -e 's/\(arm\)\(64\)\?.*/\1\2/' -e 's/aarch64$/arm64/') && \
    wget -qO- "https://github.com/helmfile/vals/releases/download/v${VALS_VERSION}/vals_${VALS_VERSION}_linux_${GO_ARCH}.tar.gz" | tar zxv -C /gitops-tools vals && \
    true

# helm-secrets installation.
#
# Helm 4 (shipped with Argo CD 3.5) redesigned the plugin system and no longer
# loads the single legacy `helm-secrets.tar.gz` bundle: it registers as
# `getter/v1` with apiVersion `legacy`, `helm secrets` is not registered as a
# command at all, and the wrapper below dies with
#   Error: unknown command "secrets" for "helm"
# on every render of a chart that uses a secrets:// value file.
# The plugin is now published as three separate archives that each carry a v1
# manifest, and all three have to be unpacked into HELM_PLUGINS.
# See https://github.com/jkroepke/helm-secrets/issues/859 and the upstream
# "ArgoCD Integration" wiki page, which this block follows.
RUN \
    wget -qO- "https://github.com/jkroepke/helm-secrets/releases/download/v${HELM_SECRETS_VERSION}/secrets-${HELM_SECRETS_VERSION}.tgz" | tar -C /gitops-tools/helm-plugins -xzf- && \
    wget -qO- "https://github.com/jkroepke/helm-secrets/releases/download/v${HELM_SECRETS_VERSION}/secrets-getter-${HELM_SECRETS_VERSION}.tgz" | tar -C /gitops-tools/helm-plugins -xzf- && \
    wget -qO- "https://github.com/jkroepke/helm-secrets/releases/download/v${HELM_SECRETS_VERSION}/secrets-post-renderer-${HELM_SECRETS_VERSION}.tgz" | tar -C /gitops-tools/helm-plugins -xzf- && \
    true

RUN chmod +x /gitops-tools/* && ln -sf /gitops-tools/helm-plugins/secrets/scripts/wrapper/helm.sh /usr/local/sbin/helm

USER 999
