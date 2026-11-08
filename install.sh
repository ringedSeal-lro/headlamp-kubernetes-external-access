#!/usr/bin/env bash
set -Eeuo pipefail

# Kubernetes External Access
# Requer install.sh, IPPool.yaml e headlamp-ingress.yaml no mesmo diretório.

METALLB_VERSION="${METALLB_VERSION:-0.15.3}"
NGINX_CHART_VERSION="${NGINX_CHART_VERSION:-2.5.1}"
EXTERNAL_IP="${EXTERNAL_IP:-192.168.1.240}"
HEADLAMP_HOST="${HEADLAMP_HOST:-headlamp.local}"
KUBEPROXY_CONFIGURE="${KUBEPROXY_CONFIGURE:-true}"
CONFIGURE_LOCAL_NODE="${CONFIGURE_LOCAL_NODE:-false}"

METALLB_NAMESPACE="metallb-system"
NGINX_NAMESPACE="nginx-ingress"
HEADLAMP_NAMESPACE="kube-system"
NGINX_RELEASE="nginx-ingress"
HEADLAMP_RELEASE="my-headlamp"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
IPPOOL_FILE="${SCRIPT_DIR}/IPPool.yaml"
INGRESS_FILE="${SCRIPT_DIR}/headlamp-ingress.yaml"

log() {
  printf '[INFO] %s\n' "$*"
}

warn() {
  printf '[AVISO] %s\n' "$*" >&2
}

die() {
  printf '[ERRO] %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 ||
    die "Comando obrigatório não encontrado: $1"
}

check_prerequisites() {
  require_command kubectl
  require_command helm
  require_command curl
  require_command python3

  [[ -f "$IPPOOL_FILE" ]] ||
    die "Arquivo não encontrado: $IPPOOL_FILE"

  [[ -f "$INGRESS_FILE" ]] ||
    die "Arquivo não encontrado: $INGRESS_FILE"

  if [[ "$KUBEPROXY_CONFIGURE" == "true" ]]; then
    python3 -c 'import yaml' 2>/dev/null ||
      die "PyYAML não encontrado. Instale-o ou execute com KUBEPROXY_CONFIGURE=false."
  fi

  kubectl cluster-info >/dev/null ||
    die "Não foi possível acessar o cluster Kubernetes."

  log "Contexto Kubernetes: $(kubectl config current-context)"
  kubectl get nodes

  # Confere se o IP solicitado está dentro do pool usado neste tutorial.
  python3 - "$EXTERNAL_IP" <<'PY'
import ipaddress
import sys

ip = ipaddress.ip_address(sys.argv[1])
start = ipaddress.ip_address("192.168.1.240")
end = ipaddress.ip_address("192.168.1.250")

if ip.version != 4 or not start <= ip <= end:
    raise SystemExit(
        "EXTERNAL_IP deve estar no intervalo "
        "192.168.1.240-192.168.1.250. "
        "Se você modificar IPPool.yaml, ajuste essa validação."
    )
PY

  log "IP externo solicitado: ${EXTERNAL_IP}"
}

configure_local_node() {
  if [[ "$CONFIGURE_LOCAL_NODE" != "true" ]]; then
    warn "CONFIGURE_LOCAL_NODE=false: módulos do kernel não serão configurados nesta máquina."
    warn "Garanta que os módulos IPVS estejam carregados nos nós relevantes."
    return
  fi

  [[ "$(uname -s)" == "Linux" ]] ||
    die "A configuração dos módulos só é suportada em Linux."

  require_command sudo

  for module in ip_vs ip_vs_rr ip_vs_wrr ip_vs_sh nf_conntrack; do
    sudo modprobe "$module"
  done

  printf 'ip_vs\nip_vs_rr\nip_vs_wrr\nip_vs_sh\nnf_conntrack\n' |
    sudo tee /etc/modules-load.d/ipvs.conf >/dev/null

  log "Módulos IPVS carregados e configurados para persistência nesta máquina."
}

configure_kube_proxy() {
  if [[ "$KUBEPROXY_CONFIGURE" != "true" ]]; then
    warn "KUBEPROXY_CONFIGURE=false: configuração do kube-proxy ignorada."
    return
  fi

  if ! kubectl get configmap kube-proxy -n kube-system >/dev/null 2>&1; then
    warn "ConfigMap kube-system/kube-proxy não encontrado (cluster não-kubeadm ou sem kube-proxy)."
    warn "Configuração do kube-proxy ignorada; ajuste-a manualmente se necessário."
    return
  fi

  log "Configurando kube-proxy para IPVS e strictARP..."

  local tmp_json
  tmp_json="$(mktemp)"
  local patched_json
  patched_json="$(mktemp)"

  kubectl get configmap kube-proxy \
    -n kube-system -o json > "$tmp_json"

  python3 - "$tmp_json" "$patched_json" <<'PY'
import json
import sys
from pathlib import Path
import yaml

source = Path(sys.argv[1])
destination = Path(sys.argv[2])

obj = json.loads(source.read_text())
data = obj.setdefault("data", {})
raw_config = data.get("config.conf")

if not raw_config:
    raise SystemExit(
        "O ConfigMap kube-proxy não contém data.config.conf. "
        "Configure o kube-proxy manualmente."
    )

config = yaml.safe_load(raw_config) or {}
config["mode"] = "ipvs"
config.setdefault("ipvs", {})["strictARP"] = True

data["config.conf"] = yaml.safe_dump(
    config,
    sort_keys=False
)

destination.write_text(json.dumps(obj))
PY

  kubectl apply -f "$patched_json"

  rm -f "$tmp_json" "$patched_json"

  log "ConfigMap kube-proxy atualizado."

  # Recria os pods e aguarda que voltem a funcionar com a nova configuração.
  # Se os módulos IPVS não estiverem disponíveis nos nós, o kube-proxy não
  # fica pronto e o restante da instalação falharia de forma menos clara.
  if kubectl get daemonset kube-proxy -n kube-system >/dev/null 2>&1; then
    kubectl rollout restart daemonset/kube-proxy -n kube-system
    kubectl rollout status daemonset/kube-proxy \
      -n kube-system --timeout=180s ||
      die "kube-proxy não ficou pronto em modo IPVS. Verifique se os módulos ip_vs, ip_vs_rr, ip_vs_wrr, ip_vs_sh e nf_conntrack estão carregados em todos os nós (kubectl logs -n kube-system -l k8s-app=kube-proxy). Restaure o backup do ConfigMap se necessário."
  else
    warn "DaemonSet kube-system/kube-proxy não encontrado; reinicie o kube-proxy manualmente."
  fi
}

install_metallb() {
  log "Instalando MetalLB ${METALLB_VERSION}..."

  kubectl apply -f \
    "https://raw.githubusercontent.com/metallb/metallb/v${METALLB_VERSION}/config/manifests/metallb-native.yaml"

  kubectl rollout status deployment/controller \
    -n "$METALLB_NAMESPACE" --timeout=240s

  kubectl rollout status daemonset/speaker \
    -n "$METALLB_NAMESPACE" --timeout=240s

  log "Aplicando pool de IPs e anúncio Layer 2..."

  # O webhook de validação do MetalLB pode levar alguns segundos para aceitar
  # conexões mesmo após o rollout do controller; tenta novamente até ~2 min.
  local attempt
  for attempt in $(seq 1 24); do
    if kubectl apply -f "$IPPOOL_FILE"; then
      break
    fi
    [[ "$attempt" -lt 24 ]] ||
      die "Não foi possível aplicar $IPPOOL_FILE (webhook do MetalLB indisponível?)."
    warn "Webhook do MetalLB ainda não está pronto; nova tentativa em 5s (${attempt}/24)..."
    sleep 5
  done

  kubectl get ipaddresspools,l2advertisements \
    -n "$METALLB_NAMESPACE"
}

install_nginx() {
  log "Instalando NGINX Ingress Controller ${NGINX_CHART_VERSION}..."

  helm upgrade --install "$NGINX_RELEASE" \
    oci://ghcr.io/nginx/charts/nginx-ingress \
    --version "$NGINX_CHART_VERSION" \
    --namespace "$NGINX_NAMESPACE" \
    --create-namespace \
    --set controller.service.type=LoadBalancer \
    --set controller.service.loadBalancerIP="$EXTERNAL_IP" \
    --set controller.replicaCount=1 \
    --wait \
    --timeout 5m

  kubectl get svc -n "$NGINX_NAMESPACE"
}

install_headlamp() {
  log "Instalando Headlamp..."

  helm repo add headlamp \
    https://kubernetes-sigs.github.io/headlamp/ \
    --force-update

  helm repo update headlamp

  helm upgrade --install "$HEADLAMP_RELEASE" \
    headlamp/headlamp \
    --namespace "$HEADLAMP_NAMESPACE" \
    --wait \
    --timeout 5m

  log "Aplicando regra Ingress do Headlamp..."
  kubectl apply -f "$INGRESS_FILE"
}

validate_setup() {
  log "Verificando recursos instalados..."

  kubectl get pods -n "$METALLB_NAMESPACE"
  kubectl get ipaddresspools,l2advertisements -n "$METALLB_NAMESPACE"

  kubectl get pods,svc -n "$NGINX_NAMESPACE"
  kubectl get pods,svc -n "$HEADLAMP_NAMESPACE"
  kubectl get ingress -n "$HEADLAMP_NAMESPACE"

  log "Testando HTTP em ${EXTERNAL_IP}..."

  local http_code
  http_code="$(
    curl -sS -o /dev/null -w '%{http_code}' \
      --connect-timeout 5 \
      --max-time 15 \
      -H "Host: ${HEADLAMP_HOST}" \
      "http://${EXTERNAL_IP}/" || true
  )"

  if [[ "$http_code" =~ ^[23][0-9][0-9]$ ]]; then
    log "Teste HTTP retornou ${http_code}."
  else
    warn "Teste HTTP retornou '${http_code:-sem resposta}'."
    warn "Verifique os serviços, o Ingress e a conectividade da rede."
  fi

  log "Endereço de acesso esperado: http://${HEADLAMP_HOST}"
  log "No cliente, associe ${EXTERNAL_IP} a ${HEADLAMP_HOST} no DNS ou /etc/hosts."
}

main() {
  check_prerequisites
  configure_local_node
  configure_kube_proxy
  install_metallb
  install_nginx
  install_headlamp
  validate_setup

  log "Execução concluída. Confira os avisos e valide o acesso."
}

main "$@"
