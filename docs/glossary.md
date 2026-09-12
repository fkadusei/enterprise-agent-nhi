# Glossary — the vocabulary of agent identity, in plain language

**NHI (Non-Human Identity).** Any identity that isn't a person: service
accounts, workloads, bots, API keys, and now AI agents. NHIs already
outnumber humans in most enterprises by an order of magnitude, and agents
multiply them further. *Why you care:* every NHI is a potential unmonitored
backdoor if it's just a shared key.

**Workload identity.** An identity bound to a running piece of software —
verified by the platform it runs on (here: Kubernetes namespace + service
account), not by a secret it carries. *Why you care:* a stolen API key works
anywhere; a workload identity only works for that workload, on that platform.

**SPIFFE.** *Secure Production Identity Framework for Everyone* — the open
standard for workload identity. Defines the ID format (a URI like
`spiffe://acme.com/ns/agent-nhi/sa/agent`) and the document formats that
prove it. *Analogy:* the passport standard.

**SVID (SPIFFE Verifiable Identity Document).** The actual, signed proof of a
SPIFFE ID. Two flavors: X.509 (for mTLS) and JWT (for OAuth-style flows —
this demo uses JWT-SVIDs). Short-lived: ours live 5 minutes. *Analogy:* the
passport itself, stamped fresh every few minutes.

**SPIRE.** The reference implementation of SPIFFE: a server (signs identities,
keeps the registry) plus per-node agents (attest workloads, deliver SVIDs
over a local socket). *Analogy:* the passport office.

**Attestation.** Proving *what* a workload is before issuing it anything. The
SPIRE agent asks the kubelet about the pod: namespace, service account, node.
No secret is presented — the platform's testimony is the proof. *Why you
care:* this is what makes "no keys on disk" possible.

**Token exchange (RFC 8693).** An OAuth flow that swaps one token for another
with different audience/scope, preserving *who is acting through whom*. Our
agent exchanges alice's token for one scoped to the tool server. *Why you
care:* it's the standards-based answer to "the agent acts on behalf of the
user" — without handing the agent the user's credentials.

**The `azp` claim (the actor).** Inside an exchanged token: the workload the
token was **issued to** — i.e. the workload that performed the exchange. Our
tool tokens read `sub: alice` (the human), `azp: spiffe://.../sa/agent` (the
agent). RFC 8693 calls this the actor and uses an `act` claim; Keycloak's
Standard Token Exchange V2 surfaces it as `azp`, so that is what we validate.
*Why you care:* audit and policy become precise: not "some client did X" but
"THIS agent did X FOR alice."

**`jti` (JWT ID).** A unique identifier for a single JWT. Keycloak requires it
on `private_key_jwt` client assertions and rejects reuse — which is why this
demo runs a tiny SPIRE plugin that adds one (see `spire-plugin/`).

**Audience (`aud`).** Who a token is minted *for*. The tool server only
accepts `aud=tool-server`; the customer API only `aud=customer-api`. *Why you
care:* this is the tripwire that makes token forwarding explode (attack #2).

**Token forwarding.** Sending a token you received onward to another service.
An explicit anti-pattern (called out in IETF drafts): it turns one stolen
token into lateral movement. *Our rule:* every hop exchanges, never forwards.

**OPA (Open Policy Agent).** A general-purpose policy engine. You write
policy as data (Rego), services ask it "is this allowed?" *Why you care:*
authorization becomes reviewable, testable code in git — our policy has unit
tests that run in CI.

**Deny by default.** If no rule says yes, the answer is no. The safe failure
mode for anything an LLM can talk into existence.

**MCP (Model Context Protocol).** The standard way agents discover and call
tools. Our tool server is a plain HTTP version of the same boundary; the
migration to real MCP is a transport swap — see
[docs/mcp-migration.md](mcp-migration.md).

**PEP / PDP.** *Policy Enforcement Point* (the tool server — where requests
are stopped and checked) vs *Policy Decision Point* (OPA — where the answer
comes from). Keeping them separate is what lets policy change without
redeploys.

**Delegation chain.** The full "who → through whom → for whom" of a request:
`alice → spiffe://.../agent → tool-server → customer-api`. The thing every
audit log line records.
