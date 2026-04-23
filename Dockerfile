# ===========================================================================
# K8s-One: Single-Node Kubernetes — Distroless Multi-Stage Build
# ===========================================================================

# --- Versions (all configurable via build args) ---
ARG KUBE_VERSION=v1.36.0
ARG ETCD_VERSION=v3.5.21
ARG CONTAINERD_VERSION=1.7.27
ARG RUNC_VERSION=v1.2.6
ARG CNI_VERSION=v1.6.2
ARG CALICO_VERSION=v3.29.2
ARG LOCAL_PATH_VERSION=v0.0.35
ARG TARGETARCH=amd64

# ===========================================================================
# Stage 1: Builder — download all binaries and manifests
# ===========================================================================
FROM alpine:3.21 AS builder

ARG KUBE_VERSION ETCD_VERSION CONTAINERD_VERSION RUNC_VERSION CNI_VERSION
ARG CALICO_VERSION LOCAL_PATH_VERSION TARGETARCH

RUN apk add --no-cache curl tar gzip

WORKDIR /build

# ── Kubernetes binaries ───────────────────────────────────────────────────
RUN mkdir -p /build/bin && \
    for comp in kube-apiserver kube-controller-manager kube-scheduler kubelet kube-proxy kubectl; do \
      echo "Downloading $comp ${KUBE_VERSION}..." && \
      curl -fsSL "https://dl.k8s.io/${KUBE_VERSION}/bin/linux/${TARGETARCH}/${comp}" \
        -o "/build/bin/${comp}" && \
      chmod +x "/build/bin/${comp}"; \
    done

# ── etcd ──────────────────────────────────────────────────────────────────
RUN curl -fsSL "https://github.com/etcd-io/etcd/releases/download/${ETCD_VERSION}/etcd-${ETCD_VERSION}-linux-${TARGETARCH}.tar.gz" | \
    tar xz --strip-components=1 -C /build/bin/ \
      "etcd-${ETCD_VERSION}-linux-${TARGETARCH}/etcd" \
      "etcd-${ETCD_VERSION}-linux-${TARGETARCH}/etcdctl"

# ── containerd ────────────────────────────────────────────────────────────
RUN curl -fsSL "https://github.com/containerd/containerd/releases/download/v${CONTAINERD_VERSION}/containerd-${CONTAINERD_VERSION}-linux-${TARGETARCH}.tar.gz" | \
    tar xz -C /build/bin/ --strip-components=1

# ── runc ──────────────────────────────────────────────────────────────────
RUN curl -fsSL "https://github.com/opencontainers/runc/releases/download/${RUNC_VERSION}/runc.${TARGETARCH}" \
    -o /build/bin/runc && chmod +x /build/bin/runc

# ── CNI plugins ──────────────────────────────────────────────────────────
RUN mkdir -p /build/cni && \
    curl -fsSL "https://github.com/containernetworking/plugins/releases/download/${CNI_VERSION}/cni-plugins-linux-${TARGETARCH}-${CNI_VERSION}.tgz" | \
    tar xz -C /build/cni/

# ── Manifests ─────────────────────────────────────────────────────────────
RUN mkdir -p /build/manifests && \
    curl -fsSL "https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/calico.yaml" \
      -o /build/manifests/calico.yaml && \
    curl -fsSL "https://raw.githubusercontent.com/rancher/local-path-provisioner/${LOCAL_PATH_VERSION}/deploy/local-path-storage.yaml" \
      -o /build/manifests/local-path-storage.yaml

# ===========================================================================
# Stage 2: Runtime — minimal Alpine stripped to distroless-like
# ===========================================================================
FROM alpine:3.21 AS runtime

# Install ONLY essential runtime dependencies
RUN apk add --no-cache \
      bash \
      openssl \
      iptables \
      ip6tables \
      conntrack-tools \
      iproute2 \
      util-linux \
      socat \
      findutils \
      curl \
      ca-certificates \
      gcompat \
      libc6-compat \
    && \
    # Strip the image: remove package manager, docs, caches
    rm -rf /var/cache/apk/* \
           /lib/apk \
           /usr/share/man \
           /usr/share/doc \
           /usr/share/info \
           /tmp/* && \
    # Remove apk itself to make it "distroless" (no package manager)
    rm -f /sbin/apk /usr/bin/apk 2>/dev/null; \
    rm -rf /etc/apk

# ── Copy binaries from builder ────────────────────────────────────────────
COPY --from=builder /build/bin/kube-apiserver          /usr/local/bin/
COPY --from=builder /build/bin/kube-controller-manager /usr/local/bin/
COPY --from=builder /build/bin/kube-scheduler          /usr/local/bin/
COPY --from=builder /build/bin/kubelet                 /usr/local/bin/
COPY --from=builder /build/bin/kube-proxy              /usr/local/bin/
COPY --from=builder /build/bin/kubectl                 /usr/local/bin/
COPY --from=builder /build/bin/etcd                    /usr/local/bin/
COPY --from=builder /build/bin/etcdctl                 /usr/local/bin/
COPY --from=builder /build/bin/containerd              /usr/local/bin/
COPY --from=builder /build/bin/containerd-shim-runc-v2 /usr/local/bin/
COPY --from=builder /build/bin/ctr                     /usr/local/bin/
COPY --from=builder /build/bin/runc                    /usr/local/bin/

# ── CNI plugins ───────────────────────────────────────────────────────────
COPY --from=builder /build/cni/ /opt/cni/bin/

# ── Manifests ─────────────────────────────────────────────────────────────
COPY --from=builder /build/manifests/ /opt/manifests/
COPY manifests/coredns.yaml /opt/manifests/coredns.yaml
COPY manifests/haproxy-ingress.yaml /opt/manifests/haproxy-ingress.yaml

# ── Configs & scripts ─────────────────────────────────────────────────────
COPY configs/containerd-config.toml /etc/containerd/config.toml
COPY scripts/entrypoint.sh /scripts/entrypoint.sh
RUN chmod +x /scripts/entrypoint.sh

# ── Create required directories ──────────────────────────────────────────
RUN mkdir -p \
      /var/lib/etcd \
      /var/lib/containerd \
      /var/lib/kubelet \
      /var/lib/kubelet/pods \
      /var/log/pods \
      /var/log/containers \
      /etc/kubernetes/pki/etcd \
      /etc/cni/net.d \
      /opt/local-path-provisioner \
      /run/containerd

EXPOSE 6443

ENTRYPOINT ["/scripts/entrypoint.sh"]
