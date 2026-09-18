#!/usr/bin/env bash
set -euo pipefail

CLUSTER_NAME="catcar"
REG_NAME="kind-registry"
REG_PORT="5001"
REG_IMAGE="registry:3"
KIND_CONFIG="${KIND_CONFIG:-kind-config.yaml}"

# 1. Create registry container unless it already exists
if [ "$(docker inspect -f '{{.State.Running}}' "${REG_NAME}" 2>/dev/null || true)" != 'true' ]; then
  if [ "$(docker inspect -f '{{.State.Status}}' "${REG_NAME}" 2>/dev/null || true)" = 'exited' ]; then
    echo "Starting existing registry container '${REG_NAME}'..."
    docker start "${REG_NAME}"
  else
    echo "Creating registry container '${REG_NAME}' on port 127.0.0.1:${REG_PORT}..."
    docker run \
      -d --restart=always -p "127.0.0.1:${REG_PORT}:5000" --network bridge --name "${REG_NAME}" \
      "${REG_IMAGE}"
  fi
fi

# 2. Create kind cluster if it does not already exist
if ! kind get clusters | grep -q "^${CLUSTER_NAME}$"; then
  echo "Creating Kind cluster '${CLUSTER_NAME}' using config '${KIND_CONFIG}'..."
  kind create cluster --name "${CLUSTER_NAME}" --config "${KIND_CONFIG}" --wait 120s
else
  echo "Kind cluster '${CLUSTER_NAME}' already exists."
fi

# 3. Add the registry config to the nodes
REGISTRY_DIR="/etc/containerd/certs.d/localhost:${REG_PORT}"
for node in $(kind get nodes --name "${CLUSTER_NAME}"); do
  docker exec "${node}" mkdir -p "${REGISTRY_DIR}"
  cat <<EOF | docker exec -i "${node}" cp /dev/stdin "${REGISTRY_DIR}/hosts.toml"
[host."http://${REG_NAME}:5000"]
EOF
done

# 4. Connect the registry to the cluster network if not already connected
if [ "$(docker inspect -f='{{json .NetworkSettings.Networks.kind}}' "${REG_NAME}")" = 'null' ]; then
  docker network connect "kind" "${REG_NAME}"
fi

# 5. Document the local registry in kube-public
cat <<EOF | kubectl --context "kind-${CLUSTER_NAME}" apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: local-registry-hosting
  namespace: kube-public
data:
  localRegistryHosting.v1: |
    host: "localhost:${REG_PORT}"
    help: "https://kind.sigs.k8s.io/docs/user/local-registry/"
EOF

echo "Kind cluster '${CLUSTER_NAME}' with local registry on 127.0.0.1:${REG_PORT} is ready."
