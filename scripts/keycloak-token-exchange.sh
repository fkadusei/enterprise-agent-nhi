#!/bin/bash
# =============================================================================
# configure-token-exchange.sh — grants the four RFC 8693 token-exchange
# permissions this demo needs. Runs INSIDE the Keycloak pod via:
#     kubectl exec -i deploy/keycloak -n agent-nhi -- bash -s < this-file
#
# Why a script and not realm.json: Keycloak's fine-grained exchange
# permissions are awkward to express in a realm import; doing them
# imperatively with kcadm is the documented approach and doubles as
# readable documentation of WHO may exchange WHAT.
#
# The delegation topology this creates:
#
#   alice's token (client: demo-cli)
#        │  exchange #1 by THE AGENT (client: spiffe://.../sa/agent)
#        ▼
#   token aud=tool-server  (act: spiffe://.../sa/agent)
#        │  exchange #2 by TOOL SERVER (client: tool-server)
#        ▼
#   token aud=customer-api (act: tool-server, chain preserved)
#
# So the four grants are:
#   1. demo-cli     : token-exchange ← agent       (agent may exchange alice's token)
#   2. tool-server  : token-exchange ← agent       (agent may target aud=tool-server)
#   3. agent client : token-exchange ← tool-server (tool-server may exchange hop-1 token)
#   4. customer-api : token-exchange ← tool-server (tool-server may target aud=customer-api)
# =============================================================================
set -euo pipefail

KCADM=/opt/keycloak/bin/kcadm.sh
REALM=agent-nhi
AGENT_CLIENT_ID="spiffe://acme.com/ns/agent-nhi/sa/agent"

# No jq in the Keycloak image — tiny sed extractors instead.
json_id() { sed -n 's/.*"id" *: *"\([^"]*\)".*/\1/p' | head -1; }
json_perm() { sed -n 's/.*"token-exchange" *: *"\([^"]*\)".*/\1/p' | head -1; }

$KCADM config credentials --server http://localhost:8080 --realm master \
  --user admin --password admin >/dev/null

client_uuid() { # client_id -> internal uuid
  $KCADM get clients -r "$REALM" -q "clientId=$1" --fields id | json_id
}

grant_exchange() { # grant_exchange <target_client_id> <requester_client_id>
  local target_id="$1" requester_id="$2"
  local target req_uuid perm policy
  target=$(client_uuid "$target_id")
  req_uuid=$(client_uuid "$requester_id")
  echo ">>> grant: [$requester_id] may exchange/target [$target_id]"

  # Enable fine-grained permissions on the target client; response carries
  # the id of the auto-created "token-exchange" scope permission.
  perm=$($KCADM update "clients/$target/management/permissions" -r "$REALM" \
           -s enabled=true | json_perm)
  if [ -z "$perm" ]; then # fallback: look it up explicitly
    perm=$($KCADM get "clients/$target/authz/resource-server/permission/scope" \
             -r "$REALM" -q name=token-exchange --fields id | json_id)
  fi

  # Client policy: "the requester is allowed".
  policy=$($KCADM create "clients/$target/authz/resource-server/policy/client" \
             -r "$REALM" -i \
             -s "name=allow-$requester_id" -s "clients=[\"$requester_id\"]")

  # Attach policy to the token-exchange permission.
  $KCADM update "clients/$target/authz/resource-server/permission/scope/$perm" \
    -r "$REALM" -s "policies=[\"$policy\"]" -s decisionStrategy=AFFIRMATIVE >/dev/null
  echo "    ok (permission $perm, policy $policy)"
}

grant_exchange "demo-cli"              "$AGENT_CLIENT_ID"   # 1
grant_exchange "tool-server"           "$AGENT_CLIENT_ID"   # 2
grant_exchange "$AGENT_CLIENT_ID"      "tool-server"        # 3
grant_exchange "customer-api"          "tool-server"        # 4

echo "Token-exchange topology configured."
