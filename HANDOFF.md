# HANDOFF — Stage 1 review guide

You are reviewing the **scaffold**: every file, none of it yet executed
against a live cluster (that's Stage 2). This page is a 15-minute path
through it. Challenge anything marked ⚠ — those are the judgment calls.

## Read in this order

1. **README.md** — does the elevator pitch match what you wanted built?
2. **docs/architecture.md** — the six hops table is the heart; check the
   "Deliberate demo simplifications" section for the trade-offs I made.
3. **opa/policy.rego** + **opa/tests/policy_test.rego** — the authorization
   contract, in 30 lines. Easiest place to see the security posture.
4. **src/agent/agent.py** — the zero-secrets flow. ⚠ Note: the user's token
   arrives via `USER_TOKEN` (injected by demo.sh) — the agent never handles
   user credentials. Real apps would receive it with the request.
5. **src/tool_server/app.py** — verify → OPA → exchange → downstream.
   ⚠ `TOOL_SERVER_CLIENT_SECRET` is a demo env value (flagged in file).
6. **k8s/spire/spire-server.yaml** — ⚠ the `jwt_issuer` simplification has a
   big comment explaining why (Keycloak client-JWT validation) and what
   production does instead.
7. **scripts/keycloak-token-exchange.sh** — read the header diagram; the four
   grants ARE the delegation topology.
8. **docs/threat-model.md** — check the honest accounting: three executable
   attacks, one remaining static credential (the LLM provider key), and the
   gateway pattern that removes it.
9. **docs/visualization/index.html** — double-click it. Play the flow, click
   nodes, toggle attack mode. This is your presentation surface.
10. **scripts/setup.sh / demo.sh / attack-tests.sh** — you'll be running these
    on a projector; check the pacing and the banner text.

## What to verify by eye (2 min)

- `grep -ri "secret\|password\|key" --include="*.yaml" --include="*.json" k8s/`
  → every hit should be a *documented demo value* or a JWKS/socket reference.
  (CI enforces this with gitleaks on every push, forever.)
- The agent's pod spec (`k8s/apps/agent.yaml`) contains **no** credential
  beyond the optional, absent-by-default LLM key.

## Known Stage 2 risks (already have fallbacks — see runbook)

- Keycloak accepting SPIRE's plain-HTTP JWKS URL (fallback: import bundle key
  via kcadm — scripted guidance in runbook).
- Keycloak's token-exchange permission API being fiddly across versions
  (pinned to 26.0; grant script is the single place to adjust).
- py-spiffe's `fetch_jwt_svid` signature drift (agent code is written
  defensively; first real test is setup.sh GATE step 7).

## Sign off by replying "proceed" (plus any changes). Stage 2 then builds the
cluster, runs the gates and attack tests, and pastes real outputs into the
runbook as proof.
