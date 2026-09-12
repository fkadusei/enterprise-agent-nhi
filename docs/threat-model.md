# Threat model — what this stops, and the one secret it doesn't

Each threat below maps to an executable check in `scripts/attack-tests.sh`.
A mitigation you can't demonstrate is a hope, not a mitigation.

## Threats and mitigations

### T1. Stolen agent API key → attacker impersonates the agent from anywhere
**The classic breach:** a static key in an env var or `.env` file leaks into
logs, a repo, a screenshot — and works from any machine on earth.
**Mitigation:** there is no key. The agent's credential is a JWT-SVID,
minted on demand by SPIRE only after Kubernetes attests the pod (namespace +
service account), TTL 5 minutes, delivered over a node-local socket.
**Demonstrated by:** *Attack 1* — a rogue pod in the SAME namespace mounts
the SAME socket and requests an SVID. No registration entry matches its
service account → **SPIRE refuses**. Identity is a property of the workload,
not a thing it holds.

### T2. Token forwarding / replay → lateral movement
**The classic breach:** a service passes its inbound token to the next
service; anyone who captures one token pivots through the whole mesh.
**Mitigation:** every hop performs its own RFC 8693 token exchange for a
token with exactly one audience; every resource server enforces its own
`aud`. (Forwarding is an explicit anti-pattern in the IETF agent-auth drafts.)
**Demonstrated by:** *Attack 2* — the agent's valid `aud=tool-server` token
is replayed directly at the customer API → **403, audience mismatch**.

### T3. Prompt injection / LLM misjudgment → agent calls a dangerous tool
**The classic breach:** the LLM is talked into (or fumbles into) invoking
something the user never authorized — "read payments", "delete account".
**Mitigation:** the LLM's reach is bounded by OPA policy, deny-by-default,
keyed on the *agent's identity and the human's identity* — not on anything
the LLM says. Prompt injection can change what the agent ASKS for; it cannot
change what the policy PERMITS.
**Demonstrated by:** *Attack 3* — the agent calls `customer.payments.read`
with a perfectly valid token for alice → **403 from OPA** (alice isn't in the
payments row of the policy table).

### T4. "Something happened" → forensic dead end
**Mitigation:** every hop logs the full delegation binding
`(spiffe_id, sub, azp, tool, decision)`. One query reconstructs the incident.
**Demonstrated by:** `demo.sh` beat 3 prints the audit trail.

## The last static credential (honest accounting)

The LLM is provider-agnostic. The default (`LLM_PROVIDER=ollama`) runs a local
model and needs **no credential at all**. If you instead point the agent at a
remote, OpenAI-compatible provider (`LLM_PROVIDER=openai-compatible` with
`LLM_BASE_URL`/`LLM_MODEL`), that provider's API key sits in a K8s Secret
mounted into the agent pod. That is a real static credential — the one
remaining exception, kept because **third-party SaaS that only accepts API keys
is exactly where SPIFFE stops helping.**

The production pattern that eliminates it: an **LLM gateway** inside your
trust domain. The agent authenticates to the gateway with its SVID; the
gateway holds the provider key, enforces per-agent model/spend policy, and
logs every call. The agent goes back to zero secrets; the key's blast radius
shrinks to one auditable component. (Several commercial AI gateways work
exactly this way; the pattern mirrors what we already do for the tool server.)

**Default path is Ollama** (local model, zero credentials) so the demo's
headline claim — "this agent holds no secrets" — is literally true.

## Deliberately out of scope for this demo

- mTLS everywhere (X.509-SVIDs) — HTTP in-cluster is a demo simplification
- Multi-tenant / cross-domain federation (SPIFFE bundle federation,
  OAuth identity chaining across domains)
- Hardware attestation (TPM/TEE) for the nodes themselves
- Keycloak hardening (this is `start-dev`); HA; persistent SPIRE data

Each is a known next step, not a hidden gap — see
[architecture.md "Deliberate demo simplifications"](architecture.md#deliberate-demo-simplifications-each-flagged-in-place).
