# ===========================================================================
# K8s-One: Single-Node Kubernetes — Distroless Multi-Stage Build
# ===========================================================================

# --- Versions (all configurable via build args) ---
ARG KUBE_VERSION=v1.36.0
ARG ETCD_VERSION=v3.5.21
ARG CONTAINERD_VERSION=1.7.27
ARG RUNC_VERSION=v1.2.6
ARG CNI_VERSION=v1.6.2
ARG CILIUM_VERSION=v1.19.5
ARG CILIUM_CLI_VERSION=v0.19.4
ARG ROOK_VERSION=v1.20.3
ARG TARGETARCH=amd64

# ===========================================================================
# Stage 1: Builder — download all binaries and manifests
# ===========================================================================
FROM alpine:3.21 AS builder

ARG KUBE_VERSION ETCD_VERSION CONTAINERD_VERSION RUNC_VERSION CNI_VERSION
ARG CILIUM_VERSION CILIUM_CLI_VERSION ROOK_VERSION TARGETARCH

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

# ── Cilium CLI ────────────────────────────────────────────────────────────
RUN mkdir -p /build/manifests && \
    curl -fsSL "https://github.com/cilium/cilium-cli/releases/download/${CILIUM_CLI_VERSION}/cilium-linux-${TARGETARCH}.tar.gz" | \
    tar xz -C /build/bin/ && \
    chmod +x /build/bin/cilium

# ── Manifests ─────────────────────────────────────────────────────────────
# Rook-Ceph operator manifests (crds, common, csi-operator, operator)
RUN for f in crds.yaml common.yaml csi-operator.yaml operator.yaml; do \
      curl -fsSL "https://raw.githubusercontent.com/rook/rook/${ROOK_VERSION}/deploy/examples/${f}" \
        -o "/build/manifests/rook-${f}"; \
    done && \
    curl -fsSL "https://raw.githubusercontent.com/rook/rook/${ROOK_VERSION}/deploy/examples/cluster-test.yaml" \
      -o /build/manifests/rook-cluster-test.yaml && \
    ls -la /build/manifests/

# ===========================================================================
# Stage 2: Runtime — minimal Debian slim
# ===========================================================================
FROM debian:bookworm-slim AS runtime

ARG ROOK_VERSION

# Install ONLY essential runtime dependencies
RUN apt-get update -qq && apt-get install -y -qq --no-install-recommends \
      bash \
      openssl \
      iptables \
      conntrack \
      iproute2 \
      util-linux \
      socat \
      findutils \
      curl \
      ca-certificates \
      udev \
    && \
    # Strip: remove package manager, docs, caches
    rm -rf /var/lib/apt/lists/* \
           /usr/share/man \
           /usr/share/doc \
           /usr/share/info \
           /tmp/* && \
    rm -f /usr/bin/apt /usr/bin/apt-get /usr/bin/dpkg

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
COPY --from=builder /build/bin/cilium                  /usr/local/bin/

# ── CNI plugins ───────────────────────────────────────────────────────────
COPY --from=builder /build/cni/ /opt/cni/bin/

# ── Manifests ─────────────────────────────────────────────────────────────
COPY --from=builder /build/manifests/ /opt/manifests/
COPY manifests/coredns.yaml /opt/manifests/coredns.yaml
COPY manifests/haproxy-ingress.yaml /opt/manifests/haproxy-ingress.yaml
COPY manifests/rook-ceph-cluster.yaml /opt/manifests/rook-ceph-cluster.yaml

# ── Configs & scripts ─────────────────────────────────────────────────────
COPY configs/containerd-config.toml /etc/containerd/config.toml
COPY scripts/entrypoint.sh /scripts/entrypoint.sh
COPY scripts/rbd-device-watch.sh /usr/local/bin/rbd-device-watch.sh
RUN chmod +x /scripts/entrypoint.sh /usr/local/bin/rbd-device-watch.sh

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
      /var/lib/rook \
      /run/containerd

EXPOSE 6443

ENTRYPOINT ["/scripts/entrypoint.sh"]
