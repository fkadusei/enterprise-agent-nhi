"""Tool Server — the enforcement boundary between the agent and real data.

For every call it:
  1. verifies the bearer token (signature via Keycloak JWKS, expiry, audience)
  2. extracts the delegation chain: sub = the human, act.sub = the agent's
     SPIFFE identity
  3. asks OPA whether (agent, user, tool) is allowed — deny by default
  4. only then performs its OWN RFC 8693 token exchange to call downstream —
     the agent's token is NEVER forwarded
"""
import os

import httpx
from fastapi import Depends, FastAPI, Header, HTTPException

from shared.audit import audit
from shared.tokens import KC_ISSUER, TokenRejected, delegation_chain, verify_access_token

OPA_URL = os.environ.get("OPA_URL", "http://opa.agent-nhi.svc.cluster.local:8181")
CUSTOMER_API_URL = os.environ.get(
    "CUSTOMER_API_URL", "http://customer-api.agent-nhi.svc.cluster.local:9000"
)
TOKEN_URL = f"{KC_ISSUER}/protocol/openid-connect/token"
# Server-side demo credential (see docs/threat-model.md — this is NOT the
# agent's credential; the agent has none).
TOOL_SERVER_SECRET = os.environ.get("TOOL_SERVER_CLIENT_SECRET", "tool-server-secret-demo")

TOOL_TO_SCOPE = {
    "customer.profile.read": "profile",
    "customer.payments.read": "payments",
}

app = FastAPI(title="tool-server (policy enforcement point)")


def verified_claims(authorization: str = Header(...)) -> dict:
    token = authorization.removeprefix("Bearer ")
    try:
        return verify_access_token(token, expected_audience="tool-server")
    except TokenRejected as exc:
        audit("token.rejected", service="tool-server", reason=str(exc))
        raise HTTPException(status_code=403, detail=str(exc))


def opa_allows(agent: str, user: str, tool: str) -> tuple[bool, str]:
    resp = httpx.post(
        f"{OPA_URL}/v1/data/agentnhi/authz",
        json={"input": {"agent": agent, "user": user, "tool": tool}},
        timeout=5,
    )
    resp.raise_for_status()
    result = resp.json().get("result") or {}
    return bool(result.get("allow")), result.get("reason", "no reason given")


def exchange_for_downstream(subject_token: str) -> str:
    """Hop 2: swap the (agent-presented) token for one scoped to customer-api."""
    resp = httpx.post(
        TOKEN_URL,
        data={
            "grant_type": "urn:ietf:params:oauth:grant-type:token-exchange",
            "client_id": "tool-server",
            "client_secret": TOOL_SERVER_SECRET,
            "subject_token": subject_token,
            "subject_token_type": "urn:ietf:params:oauth:token-type:access_token",
            "requested_token_type": "urn:ietf:params:oauth:token-type:access_token",
            "audience": "customer-api",
        },
        timeout=10,
    )
    if resp.status_code != 200:
        audit("exchange.failed", service="tool-server", status=resp.status_code,
              body=resp.text[:300])
        raise HTTPException(status_code=502, detail="downstream token exchange failed")
    return resp.json()["access_token"]


@app.get("/healthz")
def healthz():
    return {"ok": True}


@app.post("/tools/{tool_name}")
def call_tool(
    tool_name: str,
    body: dict,
    claims: dict = Depends(verified_claims),
    authorization: str = Header(...),
):
    user, agent = delegation_chain(claims)
    allowed, reason = opa_allows(agent=agent, user=user, tool=tool_name)
    audit(
        "policy.decision",
        service="tool-server",
        spiffe_id=agent,
        sub=user,
        tool=tool_name,
        decision="allow" if allowed else "deny",
        reason=reason,
    )
    if not allowed:
        raise HTTPException(status_code=403, detail=f"OPA denied: {reason}")

    downstream_token = exchange_for_downstream(authorization.removeprefix("Bearer "))
    customer_id = body.get("customer_id", "c-100")
    resp = httpx.get(
        f"{CUSTOMER_API_URL}/customers/{customer_id}",
        headers={"Authorization": f"Bearer {downstream_token}"},
        timeout=10,
    )
    resp.raise_for_status()
    return {"tool": tool_name, "result": resp.json()}
