# Architecture

The system in one picture (open `docs/visualization/index.html` for the
interactive 3D version):

```
        ╭─────────────────────────── IDENTITY PLANE
        │   [User: alice]   [Keycloak]   [SPIRE Server]──[OIDC discovery JWKS]
        │                            ▲           │
        ╰────────────────────────────│───────────│───────
              1. user token          │ 3. exchange│ 2. SVID (via SPIRE Agent)
        ╭────────────────────────────│───────────▼─────── WORKLOAD PLANE
        │                  [ AI AGENT — spiffe://acme.com/ns/agent-nhi/sa/agent ]
        ╰────────────────────────────│───────────────────
              4. tool call, token aud=tool-server
        ╭────────────────────────────▼─────────────────── RESOURCE PLANE
        │  [Tool Server] ──5. allow?──▶ [OPA]
        │       │ 6. SECOND exchange (aud=customer-api)
        │       ▼
        │  [Customer API]
        ╰────────────────────────────────────────────────
              └──────────────▶ [AUDIT LOG] every hop: (spiffe_id, sub, act, tool, decision)
```

## Components and what each one proves

### SPIRE Server + SPIRE Agent (`k8s/spire/`)
**Function:** the identity root of trust. The server keeps the registration
registry (one entry: the agent's SPIFFE ID, keyed to `k8s:ns=agent-nhi` +
`k8s:sa=agent`) and signs SVIDs. The per-node agent attests pods via the
kubelet and serves SVIDs over a local socket.
**What it proves:** *what the actor is.* A pod gets identity by BEING the
right workload in the right place — there is no artifact to steal.
**Also runs:** the OIDC discovery provider (sidecar) publishing the JWT-SVID
signing keys as JWKS, so Keycloak can verify agent assertions without any key
ever being copied.

### Keycloak (`k8s/keycloak/`)
**Function:** OAuth 2.0 authorization server. Issues alice's user token;
authenticates the agent **as a client whose client_id IS its SPIFFE ID**
using the JWT-SVID as a client assertion (verified against the SPIRE JWKS —
the agent has no client secret); performs the two RFC 8693 token exchanges.
**What it proves:** *who delegated what to whom.* Output tokens carry
`sub` (alice), `act.sub` (agent), `aud` (exactly one resource), TTL 5 min.
**Config note:** exchange permissions are granted imperatively by
`scripts/keycloak-token-exchange.sh` — four grants forming the delegation
topology, worth reading as documentation.

### AI Agent (`src/agent/`, `k8s/apps/agent.yaml`)
**Function:** an LLM (Ollama by default, OpenAI optional) decides *which*
tool the task needs; identity machinery decides *whether it may*. Fetches its
SVID (fresh per run), exchanges, calls the tool server.
**What it proves:** an agent can operate with **zero static credentials**.
Its pod spec contains no secrets — only the Workload API socket mount.

### Tool Server (`src/tool_server/`)
**Function:** the policy enforcement point. Verifies the token (signature via
Keycloak JWKS, expiry, `aud=tool-server`), extracts the delegation chain,
asks OPA, and only then does its **own** token exchange to reach the
customer API.
**What it proves:** *authorization happens at the tool boundary, and tokens
are never forwarded.*

### OPA (`opa/policy.rego`)
**Function:** the policy decision point. Deny-by-default; allow requires the
registered agent identity AND a permitted (tool, user) pair. Unit-tested in
CI.
**What it proves:** policy is **code** — reviewable in PRs, tested in CI,
changeable without redeploying a single workload.

### Customer API (`src/customer_api/`)
**Function:** downstream resource; accepts only `aud=customer-api`.
**What it proves:** the tripwire. Forward the agent's tool-server token
straight at it → 403. This is attack test #2.

### Audit (`src/shared/audit.py`)
**Function:** every service emits one JSON line per event, always keyed by
`(spiffe_id, sub, act, tool, decision)`.
**What it proves:** "which agent did what, on whose behalf, why was it
allowed" is a `kubectl logs | grep` away, not an incident investigation.

## The six hops, and what each one establishes

| # | Hop | Claim it establishes |
|---|---|---|
| 1 | alice → Keycloak | a human is present and authenticated |
| 2 | SPIRE agent → agent pod | the workload IS `spiffe://acme.com/ns/agent-nhi/sa/agent` (K8s attestation) |
| 3 | agent → Keycloak (exchange) | this agent acts **for alice**; output token is scoped + chained |
| 4 | agent → tool server | the call carries a valid, audience-correct, 5-minute token |
| 5 | tool server → OPA | (this agent, alice, this tool) is policy-permitted |
| 6 | tool server → customer API | downstream gets its own token; the original never travels further |

## Deliberate demo simplifications (each flagged in place)

1. **HTTP inside the cluster** (Keycloak, SPIRE OIDC JWKS) — production: TLS
   everywhere; mTLS with X.509-SVIDs is the natural next step.
2. **Demo passwords** for alice/admin/Keycloak — disposable cluster.
3. **SPIRE `jwt_issuer` pinned to the agent's SPIFFE ID** — makes Keycloak's
   client-JWT validation happy in a single-workload demo. Production: an AS
   that natively profiles SPIFFE client auth
   (`draft-ietf-oauth-spiffe-client-auth`).
4. **Server-side client secrets** (tool-server, customer-api, demo-cli) are
   plain env values — production: K8s Secrets + rotation, or SPIFFE federation
   for those workloads too.
5. **The user's token is fetched by `demo.sh`** — standing in for alice's
   browser session; the agent only ever *receives* it.
