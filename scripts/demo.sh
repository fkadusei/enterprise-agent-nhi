#!/bin/bash
# =============================================================================
# demo.sh — the happy path, paced for presenting to an audience.
# Run docs/visualization/index.html in a browser alongside this.
# Talk track that pairs with each beat: docs/presenting-the-demo.md
# Usage: ./scripts/demo.sh ["task for the agent"]   (AUTO=1 skips pauses)
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."

NS=agent-nhi
TASK="${1:-Get the profile of customer c-100}"

beat()  { printf "\n\033[1;36m━━ %s ━━\033[0m\n" "$*"; }
pause() { [ "${AUTO:-0}" = "1" ] || { printf "\033[2m[enter]\033[0m"; read -r _; } ; }

beat "0. THE CAST"
kubectl -n $NS get pods -o wide
pause

beat "1. ALICE LOGS IN (this is her app/browser, not the agent)"
# The agent never handles user credentials; demo.sh fetches alice's token
# exactly the way a frontend session would.
ALICE_TOKEN=$(kubectl -n $NS exec deploy/agent -- python -c "
import httpx
r = httpx.post('http://keycloak:8080/realms/agent-nhi/protocol/openid-connect/token',
  data={'grant_type':'password','client_id':'demo-cli',
        'client_secret':'demo-cli-secret-demo',
        'username':'alice','password':'alice123'}, timeout=10)
r.raise_for_status(); print(r.json()['access_token'])")
echo "alice has a user token (5 min TTL, aud: demo-cli)"
pause

beat "2. THE AGENT RUNS — LLM decides, identity permits"
echo "task: \"$TASK\""
kubectl -n $NS exec deploy/agent \
  -- env USER_TOKEN="$ALICE_TOKEN" python agent.py "$TASK"
pause

beat "3. THE AUDIT TRAIL — who did what, on whose behalf"
kubectl -n $NS logs deploy/tool-server --tail=6 | grep '^{' || true
kubectl -n $NS logs deploy/customer-api --tail=3 | grep '^{' || true

printf "\n\033[1;32mDemo complete. Now run ./scripts/attack-tests.sh\033[0m\n"
