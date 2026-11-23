#!/bin/sh
# Создаёт kind-кластер dev01 (без kube-proxy, с audit) + локальный registry localhost:5001.
# Основано на ../archive/e2e/dev01-with-registry.sh. Запускать из корня директории kind/: make cluster-create
set -o errexit -o nounset

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CTX=kind-dev01
. "$ROOT/versions.env"

# kind create/delete переключают current-context — запоминаем и восстанавливаем.
PREV_CTX="$(kubectl config current-context 2>/dev/null || true)"

mkdir -p "$ROOT/.build"
sed -e "s|__ROOT__|$ROOT|g" -e "s|__IMAGE__|$KIND_NODE_IMAGE|g" \
  "$ROOT/cluster/kind-dev01.yaml.tmpl" > "$ROOT/.build/kind-dev01.yaml"

reg_name='kind-registry'
reg_port='5001'
if [ "$(docker inspect -f '{{.State.Running}}' "${reg_name}" 2>/dev/null || true)" != 'true' ]; then
  docker run -d --restart=always -p "127.0.0.1:${reg_port}:5000" --network bridge --name "${reg_name}" registry:2
fi

kind create cluster --config "$ROOT/.build/kind-dev01.yaml" ${KIND_FLAGS:-}

# Алиас localhost:5001 -> контейнер registry для containerd на каждой ноде (docker exec, как в исходном скрипте).
REGISTRY_DIR="/etc/containerd/certs.d/localhost:${reg_port}"
for node in $(kind get nodes --name dev01); do
  docker exec "${node}" mkdir -p "${REGISTRY_DIR}"
  printf '[host."http://%s:5000"]\n' "${reg_name}" | docker exec -i "${node}" cp /dev/stdin "${REGISTRY_DIR}/hosts.toml"
done

if [ "$(docker inspect -f='{{json .NetworkSettings.Networks.kind}}' "${reg_name}")" = 'null' ]; then
  docker network connect "kind" "${reg_name}"
fi

kubectl --context "$CTX" apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: local-registry-hosting
  namespace: kube-public
data:
  localRegistryHosting.v1: |
    host: "localhost:${reg_port}"
    help: "https://kind.sigs.k8s.io/docs/user/local-registry/"
EOF

if [ -n "$PREV_CTX" ] && [ "$PREV_CTX" != "$CTX" ]; then
  kubectl config use-context "$PREV_CTX" >/dev/null
fi
echo "Кластер создан. Ноды NotReady до установки Cilium: make cilium-install"
