#!/bin/bash
# =============================================================================
# setup.sh — kind cluster -> SPIRE -> Keycloak -> OPA -> apps, with a
# verification gate after each identity-critical step.
# Usage: ./scripts/setup.sh        (teardown: ./scripts/teardown.sh)
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."

say()  { printf "\n\033[1;34m== %s\033[0m\n" "$*"; }
ok()   { printf "\033[1;32m   ✓ %s\033[0m\n" "$*"; }
die()  { printf "\033[1;31m   ✗ %s\033[0m\n" "$*" >&2; exit 1; }

NS=agent-nhi
SPIFFE_ID="spiffe://acme.com/ns/agent-nhi/sa/agent"

say "0. prerequisites"
for bin in kind kubectl docker; do
  command -v "$bin" >/dev/null || die "$bin not found (kind: brew install kind)"
done
docker info >/dev/null 2>&1 || die "docker daemon not running"
ok "kind, kubectl, docker present"

say "1. kind cluster"
kind get clusters 2>/dev/null | grep -qx agent-nhi || \
  kind create cluster --config kind/cluster.yaml
kubectl cluster-info --context kind-agent-nhi >/dev/null
ok "cluster kind-agent-nhi"

say "2. build + load demo images"
for svc in agent tool-server customer-api; do
  docker build -q -f "docker/$svc.Dockerfile" -t "agent-nhi/$svc:demo" . >/dev/null
  kind load docker-image "agent-nhi/$svc:demo" --name agent-nhi >/dev/null
  ok "agent-nhi/$svc:demo"
done

say "3. namespace + SPIRE"
kubectl apply -f k8s/namespace.yaml >/dev/null
kubectl apply -f k8s/spire/ >/dev/null
kubectl -n $NS rollout status statefulset/spire-server --timeout=180s >/dev/null
kubectl -n $NS rollout status daemonset/spire-agent --timeout=180s >/dev/null
ok "spire-server + spire-agent ready"

# GATE 1: workload registration — the one entry that defines the agent.
if ! kubectl -n $NS exec spire-server-0 -- /opt/spire/bin/spire-server entry show \
      -spiffeID "$SPIFFE_ID" 2>/dev/null | grep -q "$SPIFFE_ID"; then
  kubectl -n $NS exec spire-server-0 -- /opt/spire/bin/spire-server entry create \
    -spiffeID "$SPIFFE_ID" \
    -parentID spiffe://acme.com/ns/spire/sa/spire-agent \
    -selector "k8s:ns:$NS" -selector "k8s:sa:agent" >/dev/null
fi
ok "registration entry: $SPIFFE_ID (k8s:ns=$NS, k8s:sa=agent)"

say "4. Keycloak"
kubectl -n $NS create configmap keycloak-realm \
  --from-file=realm.json=k8s/keycloak/realm.json \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl apply -f k8s/keycloak/ >/dev/null
kubectl -n $NS rollout status deploy/keycloak --timeout=240s >/dev/null
ok "keycloak ready (realm agent-nhi imported)"

kubectl -n $NS exec -i deploy/keycloak -- bash -s < scripts/keycloak-token-exchange.sh \
  >/dev/null
ok "token-exchange permissions configured (4 grants)"

say "5. OPA"
kubectl -n $NS create configmap opa-policy \
  --from-file=policy.rego=opa/policy.rego \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl apply -f k8s/opa/ >/dev/null
kubectl -n $NS rollout status deploy/opa --timeout=120s >/dev/null
ok "opa serving deny-by-default policy"

say "6. demo apps"
# Optional API-key LLM path: only if you created .env with OPENAI_API_KEY.
if [ -f .env ] && grep -q '^OPENAI_API_KEY=' .env; then
  KEY=$(grep '^OPENAI_API_KEY=' .env | cut -d= -f2-)
  kubectl -n $NS create secret generic llm-api-key --from-literal=OPENAI_API_KEY="$KEY" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  ok "llm-api-key secret created (set LLM_PROVIDER=openai in k8s/apps/agent.yaml to use)"
fi
kubectl apply -f k8s/apps/ >/dev/null
kubectl -n $NS rollout status deploy/tool-server deploy/customer-api deploy/agent \
  --timeout=180s >/dev/null
ok "tool-server, customer-api, agent ready"

say "7. GATE: agent pod can fetch its SVID (no secrets involved)"
kubectl -n $NS exec deploy/agent -- python -c "
from pyspiffe.workloadapi.workload_api_client import WorkloadApiClient
c = WorkloadApiClient(spiffe_socket_path='unix:///run/spire/sockets/agent.sock')
s = c.fetch_jwt_svid(audiences=['smoke-test'])
print('SVID for', s.spiffe_id)
c.close()" | grep -q "$SPIFFE_ID" || die "agent could not fetch its SVID"
ok "agent holds a JWT-SVID issued to $SPIFFE_ID"

say "SETUP COMPLETE"
echo "Next: ./scripts/demo.sh        # the happy path"
echo "      ./scripts/attack-tests.sh # watch three attacks fail"
