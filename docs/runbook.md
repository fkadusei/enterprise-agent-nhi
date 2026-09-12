# Runbook

## Setup / teardown

```sh
./scripts/setup.sh       # full build, ~5 min, gated at each identity step
./scripts/teardown.sh    # kind delete cluster --name agent-nhi
```

Prereqs: Docker Desktop running, `kind`, `kubectl`. For the default LLM path:
`brew install ollama && ollama pull llama3.2:3b` (Ollama must be RUNNING on
the host during the demo — the agent reaches it at `host.docker.internal:11434`).

For the API-key LLM path instead: `cp .env.example .env`, add your key, set
`LLM_PROVIDER: openai` in `k8s/apps/agent.yaml`, re-run setup.

## Browser access (optional)

```sh
kubectl -n agent-nhi port-forward deploy/keycloak 8080:8080
# http://localhost:8080 — admin console login admin / admin (demo-only)
# Realm: agent-nhi. Worth showing: the client whose ID is a SPIFFE URI —
# open its Credentials tab: "Signed JWT", JWKS URL pointing at SPIRE.
```

## What to expect when it works

| Check | Command | Healthy sign |
|---|---|---|
| SPIRE | `kubectl -n agent-nhi exec spire-server-0 -- /opt/spire/bin/spire-server entry show` | one entry, `spiffe://acme.com/ns/agent-nhi/sa/agent` |
| JWKS | `kubectl -n agent-nhi exec deploy/tool-server -- python -c "import httpx;print(httpx.get('http://spire-oidc-discovery:11080/keys').json())"` | a `keys` array with an EC P-256 key |
| Audit | `kubectl -n agent-nhi logs deploy/tool-server \| grep '^{'` | JSON lines with spiffe_id/sub/tool/decision |

## Troubleshooting

**`token exchange failed: 400 ... invalid_client`**
Keycloak rejected the agent's client assertion. Almost always the JWKS fetch:
verify the row above returns a key. If the OIDC provider isn't serving, check
`kubectl -n agent-nhi logs spire-server-0 -c oidc-discovery-provider`.
Workaround if Keycloak refuses the plain-HTTP JWKS URL in your version:
import SPIRE's bundle public key directly onto the client
(Admin Console → the SPIFFE client → Keys → use JWKS emitted at
`http://spire-oidc-discovery:11080/keys` via a one-off
`kubectl exec` + `kcadm.sh`), accepting that it goes stale when SPIRE
rotates its key (~hours). The plain-HTTP URL works on the pinned Keycloak
26.6.4 with `start-dev`.

**`invalid_client: Token jti claim is required`**
The `jti` CredentialComposer plugin isn't loaded. Check
`kubectl -n agent-nhi logs spire-server-0 -c spire-server | grep -i jti` for
`Plugin loaded`, and confirm the custom server image is in use
(`kubectl -n agent-nhi get sts spire-server -o jsonpath='{.spec.template.spec.containers[0].image}'`).

**`invalid_client: Token reuse detected`**
The SPIRE agent is serving a cached JWT-SVID (same `jti`). Confirm the custom
agent image is in use (`... containers[0].image` on the spire-agent DaemonSet)
— it disables the JWT-SVID cache so every fetch mints a fresh SVID.

**`invalid_token: subject_token validation failure`**
Issuer mismatch. Keycloak derives `iss` from the request Host header, so every
client must use the same service name. This demo uses `http://keycloak:8080`
everywhere (see `KC_ISSUER` in `src/shared/tokens.py` and `src/agent/agent.py`).
Mixing `keycloak` and `keycloak.agent-nhi.svc.cluster.local` produces different
`iss` values and breaks validation.

**Agent pod can't fetch SVID (`workload api ... no identity issued`)**
The registration entry doesn't match the pod. Entry must be
`k8s:ns:agent-nhi` + `k8s:sa:agent`; check
`spire-server entry show` output and that the agent pod runs
`serviceAccountName: agent`.

**Ollama errors in the agent log (`llm.fallback`)**
Ollama isn't running on the host, or the model isn't pulled. The demo still
works — the agent falls back to the deterministic default tool, which is
itself a talking point (the LLM chooses; it never governs).

**Re-running setup after a crash**
`setup.sh` is idempotent for manifests and the registration entry; if the
Keycloak grant script double-applies and errors, fastest clean slate is
`teardown.sh && setup.sh` — the cluster is disposable by design.

## Pinned versions

kind (any recent), SPIRE 1.11.2 (server + agent are CUSTOM builds — see
`docker/spire-server.Dockerfile` and `docker/spire-agent.Dockerfile`),
oidc-discovery-provider 1.11.2, Keycloak 26.6.4, OPA 0.68.0, python:3.13-slim
images, Go 1.25 (plugin) / 1.23 (SPIRE agent) in the build stages.
Bumping: change tags in `k8s/**` and the Dockerfiles, re-run setup, re-run
attack tests.
