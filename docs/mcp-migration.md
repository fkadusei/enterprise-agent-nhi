# Migrating the tool server to real MCP

The demo's tool server is deliberately a plain HTTP API: same boundary, same
checks, zero protocol noise. The Model Context Protocol formalizes exactly
this boundary — so migration is a **transport swap, not a redesign**.

## What survives unchanged

- **All of it.** Token verification, the OPA query, the delegation chain, the
  hop-2 exchange, audit logging. Those live in `shared/` and the endpoint
  body — MCP touches none of it.

## What changes

1. **Transport:** FastAPI routes → the MCP Python SDK (`mcp.server`),
   exposing `customer.profile.read` / `customer.payments.read` as MCP *tools*
   over Streamable HTTP.
2. **Auth wiring:** MCP's 2025-era authorization spec is OAuth 2.1 with
   **resource indicators (RFC 8707)** — which this architecture already does:
   our `aud=tool-server` token IS a resource-indicator token. Point the MCP
   server's token validator at the same `shared/tokens.py` verification and
   keep enforcing per-tool policy before dispatch.
3. **Agent side:** the agent calls the MCP server with the same exchanged
   token in the `Authorization` header; the LLM already speaks tool-calling,
   so the decision loop maps directly onto MCP's tool listing.
4. **The 3D visualization:** edit only the `SCENE_DATA` block (the comment at
   the top of `index.html` marks it) — relabel "Tool Server" → "MCP Server".

## The one rule that must survive the swap

**Never forward the inbound token to downstream services.** MCP makes it easy
to build long tool chains; the exchange-per-hop rule from
[architecture.md](architecture.md) is what keeps those chains from becoming
lateral-movement highways. When you add the MCP server, keep hop 6 exactly as
it is.

## Suggested order

1. Stand the MCP server up NEXT TO the HTTP tool server (same OPA policy).
2. Point the agent at MCP, run `demo.sh` + `attack-tests.sh` — all three
   attacks must still fail identically.
3. Delete the HTTP routes. Commit as one reviewable swap.
