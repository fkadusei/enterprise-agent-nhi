"""Token verification helpers shared by the resource servers.

Every resource server:
  1. verifies the JWT signature against Keycloak's JWKS endpoint,
  2. enforces that the token was minted for IT (audience),
  3. extracts the delegation chain: sub (the human) and act (the workload).

The audience check is what makes token forwarding fail: a token minted for
the tool-server is rejected by the customer-api and vice versa.
"""
import os

import jwt
from jwt import PyJWKClient

KC_ISSUER = os.environ.get(
    "KC_ISSUER", "http://keycloak.agent-nhi.svc.cluster.local:8080/realms/agent-nhi"
)

_jwks = PyJWKClient(f"{KC_ISSUER}/protocol/openid-connect/certs")


class TokenRejected(Exception):
    """Raised for any token we refuse, with a reason safe to show callers."""


def verify_access_token(token: str, expected_audience: str) -> dict:
    """Return the decoded claims or raise TokenRejected."""
    try:
        signing_key = _jwks.get_signing_key_from_jwt(token)
        claims = jwt.decode(
            token,
            signing_key.key,
            algorithms=["RS256", "ES256"],
            audience=expected_audience,
            issuer=KC_ISSUER,
        )
    except jwt.InvalidAudienceError:
        raise TokenRejected(
            f"token audience is not {expected_audience!r} "
            "(refusing a forwarded token)"
        )
    except jwt.PyJWTError as exc:
        raise TokenRejected(f"invalid token: {exc}")
    return claims


def delegation_chain(claims: dict) -> tuple[str, str]:
    """(user, workload) — sub is the human, act.sub is the agent/client that
    performed the token exchange (RFC 8693 actor claim)."""
    user = claims.get("sub", "?")
    act = claims.get("act") or {}
    workload = act.get("sub", claims.get("azp", "?"))
    return user, workload
