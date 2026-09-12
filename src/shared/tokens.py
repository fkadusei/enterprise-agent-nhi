"""Token verification helpers shared by the resource servers.

Every resource server:
  1. verifies the JWT signature against Keycloak's JWKS endpoint,
  2. enforces that the token was minted for IT (audience),
  3. enforces that the token was issued to the expected workload (azp) —
     i.e. the workload that performed the token exchange,
  4. extracts the delegation chain: sub (the human) + azp (the workload).

The audience check is what makes token forwarding fail: a token minted with
aud=tool-server is rejected by the customer-api. The azp check is defense in
depth: even if an audience were present, the token is only accepted from the
workload it was issued to.
"""
import os

import jwt
from jwt import PyJWKClient

KC_ISSUER = os.environ.get(
    "KC_ISSUER", "http://keycloak:8080/realms/agent-nhi"
)
# NOTE: the issuer must be byte-identical everywhere in the cluster. Keycloak
# derives the `iss` claim from the request's Host header, so all clients use the
# same service name ("keycloak"). Mixing "keycloak" and the long
# "keycloak.agent-nhi.svc.cluster.local" form produces different iss values and
# breaks token validation.

_jwks = PyJWKClient(f"{KC_ISSUER}/protocol/openid-connect/certs")


class TokenRejected(Exception):
    """Raised for any token we refuse, with a reason safe to show callers."""


def verify_access_token(
    token: str, expected_audience: str, expected_azp: str | None = None
) -> dict:
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

    if expected_azp is not None and claims.get("azp") != expected_azp:
        raise TokenRejected(
            f"token was issued to {claims.get('azp')!r}, not {expected_azp!r} "
            "(refusing a forwarded token)"
        )
    return claims


def delegation_chain(claims: dict) -> tuple[str, str]:
    """(user, workload).

    user = preferred_username when present (human-readable, what policy keys
           on), else the subject (a UUID for Keycloak users)
    azp  = the workload the token was issued to — i.e. the client that
           performed the token exchange (Keycloak's standard token exchange
           issues the new token to the requester). RFC 8693 calls this the
           actor; Keycloak V2 surfaces it as azp.
    """
    user = claims.get("preferred_username") or claims.get("sub", "?")
    act = claims.get("act") or {}
    workload = act.get("sub", claims.get("azp", "?"))
    return user, workload
