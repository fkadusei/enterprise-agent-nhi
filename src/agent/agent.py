"""The AI agent — a workload with an IDENTITY instead of a KEY.

What this process owns at startup: nothing. No API key, no client secret,
no token file. When it needs to act it:

  1. asks the SPIRE Workload API for a JWT-SVID (its SPIFFE identity,
     attested by Kubernetes itself: right namespace, right service account)
  2. authenticates to Keycloak AS that identity (the SVID is its client
     assertion — Keycloak verifies it against SPIRE's published JWKS)
  3. exchanges the user's token (RFC 8693) for a 5-minute token scoped to
     the tool server, carrying the delegation chain sub=user, act=agent
  4. calls the tool the LLM decided on

An LLM picks WHICH tool to call. Identity decides WHETHER it may.
LLM_PROVIDER=ollama (default, zero credentials) or openai (the documented
"last static credential" — see docs/threat-model.md).
"""
import json
import os
import sys

import httpx

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from shared.audit import audit  # noqa: E402

# --- configuration -----------------------------------------------------------
SPIFFE_SOCKET = os.environ.get("SPIFFE_SOCKET", "unix:///run/spire/sockets/agent.sock")
KC_ISSUER = os.environ.get(
    "KC_ISSUER", "http://keycloak.agent-nhi.svc.cluster.local:8080/realms/agent-nhi"
)
TOOL_SERVER_URL = os.environ.get(
    "TOOL_SERVER_URL", "http://tool-server.agent-nhi.svc.cluster.local:8000"
)
LLM_PROVIDER = os.environ.get("LLM_PROVIDER", "ollama")
OLLAMA_URL = os.environ.get("OLLAMA_URL", "http://host.docker.internal:11434")
OLLAMA_MODEL = os.environ.get("OLLAMA_MODEL", "llama3.2:3b")
OPENAI_MODEL = os.environ.get("OPENAI_MODEL", "gpt-4o-mini")
TOKEN_URL = f"{KC_ISSUER}/protocol/openid-connect/token"

TOOLS = {
    "customer.profile.read": "Read a customer's profile. Args: customer_id",
    "customer.payments.read": "Read a customer's payment history. Args: customer_id",
}
USER_TOKEN = os.environ.get("USER_TOKEN", "")  # delivered by demo.sh — the agent
# never handles the user's credentials, it receives her token like a real app.


# --- 1. the LLM decides which tool it wants ----------------------------------
def decide_tool(task: str) -> dict:
    prompt = (
        "You are a customer-support agent. Available tools:\n"
        + "\n".join(f"- {name}: {desc}" for name, desc in TOOLS.items())
        + f'\n\nTask: "{task}"\n'
        'Reply with ONLY JSON: {"tool": "<name>", "customer_id": "c-100", '
        '"reason": "<short>"}'
    )
    try:
        if LLM_PROVIDER == "openai":
            resp = httpx.post(
                "https://api.openai.com/v1/chat/completions",
                headers={"Authorization": f"Bearer {os.environ['OPENAI_API_KEY']}"},
                json={
                    "model": OPENAI_MODEL,
                    "messages": [{"role": "user", "content": prompt}],
                    "response_format": {"type": "json_object"},
                },
                timeout=30,
            )
            content = resp.json()["choices"][0]["message"]["content"]
        else:  # ollama — local model, no credentials at all
            resp = httpx.post(
                f"{OLLAMA_URL}/api/generate",
                json={"model": OLLAMA_MODEL, "prompt": prompt,
                      "stream": False, "format": "json"},
                timeout=120,
            )
            content = resp.json()["response"]
        decision = json.loads(content)
        if decision.get("tool") in TOOLS:
            return decision
    except Exception as exc:  # small models are flaky at JSON — never block the demo
        audit("llm.fallback", reason=str(exc)[:200])
    return {"tool": "customer.profile.read", "customer_id": "c-100",
            "reason": "fallback: default profile lookup"}


# --- 2. workload identity (the zero-secrets part) -----------------------------
def fetch_jwt_svid() -> str:
    from pyspiffe.workloadapi.workload_api_client import WorkloadApiClient

    client = WorkloadApiClient(spiffe_socket_path=SPIFFE_SOCKET)
    try:
        svid = client.fetch_jwt_svid(audiences=[KC_ISSUER])
        audit("svid.issued", spiffe_id=str(svid.spiffe_id), aud=list(svid.audience))
        return svid.token
    finally:
        client.close()


# --- 3. RFC 8693: user token -> agent-scoped token ----------------------------
def exchange_for_tool_server(svid: str, user_token: str) -> str:
    resp = httpx.post(
        TOKEN_URL,
        data={
            "grant_type": "urn:ietf:params:oauth:grant-type:token-exchange",
            "client_id": "spiffe://acme.com/ns/agent-nhi/sa/agent",
            "client_assertion_type":
                "urn:ietf:params:oauth:client-assertion-type:jwt-bearer",
            "client_assertion": svid,                 # the SVID IS the credential
            "subject_token": user_token,
            "subject_token_type": "urn:ietf:params:oauth:token-type:access_token",
            "requested_token_type": "urn:ietf:params:oauth:token-type:access_token",
            "audience": "tool-server",
        },
        timeout=15,
    )
    if resp.status_code != 200:
        audit("exchange.failed", status=resp.status_code, body=resp.text[:300])
        sys.exit(f"token exchange failed: {resp.status_code} {resp.text[:300]}")
    return resp.json()["access_token"]


# --- run ----------------------------------------------------------------------
def main() -> None:
    task = " ".join(sys.argv[1:]) or "Get the profile of customer c-100"
    audit("agent.start", task=task, llm_provider=LLM_PROVIDER)

    if not USER_TOKEN:
        sys.exit("USER_TOKEN is not set — demo.sh injects it (the agent never "
                 "handles user credentials).")

    decision = decide_tool(task)
    audit("llm.decision", **decision)

    svid = fetch_jwt_svid()
    tool_token = exchange_for_tool_server(svid, USER_TOKEN)

    # Show the delegation chain the exchange produced (decode for display only).
    import jwt as pyjwt
    claims = pyjwt.decode(tool_token, options={"verify_signature": False})
    audit("token.exchanged", sub=claims.get("sub"),
          act=(claims.get("act") or {}).get("sub"), aud=claims.get("aud"),
          ttl=claims.get("exp", 0) - claims.get("iat", 0))

    resp = httpx.post(
        f"{TOOL_SERVER_URL}/tools/{decision['tool']}",
        headers={"Authorization": f"Bearer {tool_token}"},
        json={"customer_id": decision.get("customer_id", "c-100")},
        timeout=15,
    )
    audit("tool.response", tool=decision["tool"], status=resp.status_code,
          body=resp.text[:300])
    print(f"\n=== tool {decision['tool']} -> HTTP {resp.status_code} ===")
    print(resp.text)


if __name__ == "__main__":
    main()
