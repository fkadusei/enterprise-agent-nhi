#!/bin/bash
# =============================================================================
# attack-tests.sh — three attacks, three failures. This script IS the threat
# model made executable (docs/threat-model.md explains each one).
# Usage: ./scripts/attack-tests.sh
# =============================================================================
set -uo pipefail   # NOTE: no -e — we EXPECT failures here
cd "$(dirname "$0")/.."
NS=agent-nhi
SPIFFE_ID="spiffe://acme.com/ns/agent-nhi/sa/agent"

beat() { printf "\n\033[1;31m━━ ATTACK %s ━━\033[0m\n" "$*"; }
good() { printf "\033[1;32m   BLOCKED ✓  %s\033[0m\n" "$*"; }
bad()  { printf "\033[1;31m   SUCCEEDED — THAT IS A BUG ✗ %s\033[0m\n" "$*"; }

# -----------------------------------------------------------------------------
beat "1 — ROGUE WORKLOAD tries to fetch a workload identity"
# A pod in the same namespace but with the default service account mounts the
# same Workload API socket. No registration entry matches it -> no SVID.
kubectl -n $NS delete pod rogue --ignore-not-found >/dev/null 2>&1
kubectl -n $NS run rogue --image=agent-nhi/agent:demo --restart=Never \
  --overrides='{"spec":{"serviceAccountName":"default","containers":[{"name":"rogue","image":"agent-nhi/agent:demo","command":["sleep","infinity"],"volumeMounts":[{"name":"sock","mountPath":"/run/spire/sockets","readOnly":true}]}],"volumes":[{"name":"sock","hostPath":{"path":"/run/spire/sockets","type":"Directory"}}]}}' >/dev/null
kubectl -n $NS wait --for=condition=Ready pod/rogue --timeout=120s >/dev/null
OUT=$(kubectl -n $NS exec rogue -- python -c "
from spiffe.workloadapi.workload_api_client import WorkloadApiClient
c = WorkloadApiClient(socket_path='unix:///run/spire/sockets/agent.sock')
try:
    s = c.fetch_jwt_svid(audience={'x'}); print('GOT', s.spiffe_id)
except Exception as e:
    print('REFUSED')
c.close()" 2>/dev/null)
if echo "$OUT" | grep -q REFUSED; then
  good "SPIRE issued nothing. No identity, no token, no access."
else
  bad "rogue workload got an SVID: $OUT"
fi
kubectl -n $NS delete pod rogue --wait=false >/dev/null 2>&1

# -----------------------------------------------------------------------------
beat "2 — TOKEN FORWARDING: agent's tool-token replayed straight at customer-api"
ALICE_TOKEN=$(kubectl -n $NS exec deploy/agent -- python -c "
import httpx
r = httpx.post('http://keycloak:8080/realms/agent-nhi/protocol/openid-connect/token',
  data={'grant_type':'password','client_id':'demo-cli',
        'client_secret':'demo-cli-secret-demo',
        'username':'alice','password':'alice123'}, timeout=10)
print(r.json()['access_token'])")
STATUS=$(kubectl -n $NS exec deploy/agent -- env USER_TOKEN="$ALICE_TOKEN" python -c "
import os, agent, httpx
tok = agent.exchange_for_tool_server(agent.fetch_jwt_svid(), os.environ['USER_TOKEN'])
r = httpx.get('http://customer-api:9000/customers/c-100',
              headers={'Authorization': f'Bearer {tok}'}, timeout=10)
print(r.status_code)" 2>/dev/null | tail -1)
if [ "$STATUS" = "403" ]; then
  good "customer-api returned 403 — audience mismatch, forwarded token refused."
else
  bad "forwarded token was accepted (HTTP $STATUS)"
fi

# -----------------------------------------------------------------------------
beat "3 — OUT-OF-POLICY TOOL: agent calls customer.payments.read for alice"
OUT=$(kubectl -n $NS exec deploy/agent -- env USER_TOKEN="$ALICE_TOKEN" python -c "
import os, agent, httpx
tok = agent.exchange_for_tool_server(agent.fetch_jwt_svid(), os.environ['USER_TOKEN'])
r = httpx.post('http://tool-server:8000/tools/customer.payments.read',
               headers={'Authorization': f'Bearer {tok}'},
               json={'customer_id': 'c-100'}, timeout=15)
print(r.status_code, r.text[:160])" 2>/dev/null | tail -1)
if echo "$OUT" | grep -q '^403'; then
  good "OPA denied: $OUT"
else
  bad "payments tool was reachable: $OUT"
fi

printf "\n\033[1;32mAttack suite finished — all three should read BLOCKED.\033[0m\n"
