"""Customer API — the DOWNSTREAM resource server.

Exists to prove one thing: tokens are never forwarded. It only accepts tokens
minted for aud=customer-api. The tool server reaches it by doing its OWN
RFC 8693 token exchange (hop 6 in docs/architecture.md).
"""
import os

import httpx
from fastapi import Depends, FastAPI, Header, HTTPException

from shared.audit import audit
from shared.tokens import KC_ISSUER, TokenRejected, delegation_chain, verify_access_token

CUSTOMERS = {
    "c-100": {"name": "Alice Example", "tier": "gold", "region": "us-east"},
    "c-200": {"name": "Bob Sample", "tier": "silver", "region": "eu-west"},
}

app = FastAPI(title="customer-api (downstream)")


def authorized(authorization: str = Header(...)) -> dict:
    token = authorization.removeprefix("Bearer ")
    try:
        return verify_access_token(token, expected_audience="customer-api")
    except TokenRejected as exc:
        audit("token.rejected", service="customer-api", reason=str(exc))
        raise HTTPException(status_code=403, detail=str(exc))


@app.get("/healthz")
def healthz():
    return {"ok": True}


@app.get("/customers/{customer_id}")
def get_customer(customer_id: str, claims: dict = Depends(authorized)):
    user, workload = delegation_chain(claims)
    audit(
        "customer.read",
        service="customer-api",
        spiffe_id=workload,
        sub=user,
        aud=claims.get("aud"),
        customer_id=customer_id,
        decision="allow",  # reaching here means a valid, correctly-scoped token
    )
    customer = CUSTOMERS.get(customer_id)
    if customer is None:
        raise HTTPException(status_code=404, detail="unknown customer")
    return {"customer_id": customer_id, **customer}
