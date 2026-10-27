
#!/usr/bin/env bash

set -Eeuo pipefail

# Versions should match install.sh
METALLB_VERSION="${METALLB_VERSION:-0.15.3}"

# Installation names
METALLB_NAMESPACE="metallb-system"
NGINX_NAMESPACE="nginx-ingress"
NGINX_RELEASE="nginx-ingress"
HEADLAMP_NAMESPACE="kube-system"
HEADLAMP_RELEASE="my-headlamp"

# Files located in the same directory as this script
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
IPPOOL_FILE="${SCRIPT_DIR}/IPPool.yaml"
INGRESS_FILE="${SCRIPT_DIR}/headlamp-ingress.yaml"

CONFIRM=false

log() {
    printf '\n[INFO] %s\n' "$*"
}

warn() {
    printf '\n[WARN] %s\n' "$*" >&2
}

die() {
    printf '\n[ERROR] %s\n' "$*" >&2
    exit 1
}

usage() {
    cat <<EOF
Usage: $0 [--yes] [--help]

Options:
  --yes     Skip the interactive confirmation.
  --help    Show this help message.

This script removes:
  - Headlamp Helm release
  - Headlamp Ingress resource
  - NGINX Ingress Controller Helm release
  - MetalLB IPAddressPool and L2Advertisement
  - MetalLB installation

It does not restore kube-proxy settings or unload IPVS modules.
EOF
}

for arg in "$@"; do
    case "$arg" in
        --yes)  CONFIRM=true ;;
        --help) usage; exit 0 ;;
        *)      die "Unknown argument: $arg" ;;
    esac
done

require_command() {
    command -v "$1" >/dev/null 2>&1 ||
        die "Required command not found: $1"
}

uninstall_helm_release() {
    local release="$1"
    local namespace="$2"

    if helm status "$release" -n "$namespace" >/dev/null 2>&1; then
        log "Uninstalling Helm release '$release' from namespace '$namespace'..."
        helm uninstall "$release" -n "$namespace" --wait
    else
        log "Helm release '$release' not found in namespace '$namespace'; skipping."
    fi
}

main() {
    require_command kubectl
    require_command helm

    kubectl cluster-info >/dev/null 2>&1 ||
        die "Cannot access the Kubernetes cluster. Check your kubeconfig."

    log "Current Kubernetes context:"
    kubectl config current-context

    cat <<EOF

The following components will be removed:
  1. Headlamp and its Ingress
  2. NGINX Ingress Controller
  3. MetalLB IP pool configuration
  4. MetalLB installation

WARNING:
  - MetalLB may be used by other LoadBalancer services.
  - Removing MetalLB can affect other services using its IP addresses.
  - kube-proxy settings and local IPVS modules will NOT be reverted.
  - Other resources in the cluster will NOT be intentionally removed.

EOF

    if [[ "$CONFIRM" != true ]]; then
        read -r -p "Continue with uninstallation? [y/N] " answer
        [[ "$answer" =~ ^[Yy]$ ]] ||
            { log "Uninstallation cancelled."; exit 0; }
    fi

    # 1. Remove Headlamp's Ingress before removing the controller.
    log "Removing Headlamp Ingress..."

    if [[ -f "$INGRESS_FILE" ]]; then
        kubectl delete -f "$INGRESS_FILE" \
            --ignore-not-found=true
    else
        warn "Ingress manifest not found: $INGRESS_FILE"
        kubectl delete ingress headlamp \
            -n "$HEADLAMP_NAMESPACE" \
            --ignore-not-found=true
    fi

    # 2. Uninstall Headlamp.
    uninstall_helm_release \
        "$HEADLAMP_RELEASE" \
        "$HEADLAMP_NAMESPACE"

    # 3. Uninstall NGINX Ingress Controller.
    uninstall_helm_release \
        "$NGINX_RELEASE" \
        "$NGINX_NAMESPACE"

    # 4. Remove MetalLB custom resources before removing MetalLB.
    log "Removing MetalLB IP pool configuration..."

    if [[ -f "$IPPOOL_FILE" ]]; then
        kubectl delete -f "$IPPOOL_FILE" \
            --ignore-not-found=true
    else
        warn "IP pool manifest not found: $IPPOOL_FILE"
        kubectl delete ipaddresspool metallb-single-ip \
            -n "$METALLB_NAMESPACE" \
            --ignore-not-found=true
        kubectl delete l2advertisement metallb-single-ip-adv \
            -n "$METALLB_NAMESPACE" \
            --ignore-not-found=true
    fi

    # 5. Remove the MetalLB installation.
    log "Removing MetalLB installation..."

    METALLB_MANIFEST="https://raw.githubusercontent.com/metallb/metallb/v${METALLB_VERSION}/config/manifests/metallb-native.yaml"

    if kubectl get namespace "$METALLB_NAMESPACE" \
        >/dev/null 2>&1; then
        kubectl delete -f "$METALLB_MANIFEST" \
            --ignore-not-found=true \
            --wait=true
    else
        log "MetalLB namespace not found; skipping manifest removal."
    fi

    log "Uninstallation steps completed."
    log "Review the remaining cluster resources before considering the cleanup complete."

    printf '\nRemaining related resources, if any:\n'
    kubectl get pods,svc,ingress -A 2>/dev/null |
        grep -E 'headlamp|nginx-ingress|metallb' || true
}

main "$@"
