# Presenting the demo — a 10-minute talk track

Pair each beat with the command and what to point at. Rehearse once with
`AUTO=1 ./scripts/demo.sh` (skips the pauses).

**Setup before anyone arrives:** run `./scripts/setup.sh` to completion, open
`docs/visualization/index.html` in a browser, terminal next to it, font big.

---

### Beat 0 — the hook (1 min)
> "Every AI agent deployment I've audited hands the agent an API key and
> hopes. This is what 'hope' costs — and here's the alternative running live."

Show the 3D view. Orbit once. Say the one-liner:
> "OAuth answers *is this actor allowed* — SPIFFE answers *what IS this
> actor*. You need both for agents."

### Beat 1 — the flow, on the visualization (2 min)
Press **▶ Play trust flow**. Narrate the six hops as the pulses move.
Land hop 2 hard: *"No secret is ever delivered to this pod. Kubernetes
vouches for it; SPIRE mints identity from that testimony."*
Land hop 6: *"Watch — the tool server does NOT pass the agent's token along.
It exchanges for its own. Forwarding is how breaches spread; this design
makes forwarding useless."*

### Beat 2 — the live happy path (2 min)
`./scripts/demo.sh` — walk the beats. After beat 2, point at the
`token.exchanged` audit line:
```json
{"event":"policy.decision","service":"tool-server","spiffe_id":"spiffe://.../agent",
 "sub":"alice","tool":"customer.profile.read","decision":"allow","reason":"allowed by policy"}
```
> "One line, four facts: WHO the human is (`sub`), WHAT workload is acting
> (`spiffe_id`), WHAT it asked for, and WHY it was allowed. Five-minute tokens."

### Beat 3 — the attack suite (3 min, the climax)
`./scripts/attack-tests.sh`. Say each attack BEFORE running it, then let the
red `BLOCKED ✓` land:
1. **Rogue workload:** *"Same namespace, same socket — still gets nothing.
   You can't steal what was never issued."*
2. **Token forwarding:** *"A perfectly valid token, one hop early. 403."*
3. **Out-of-policy tool:** *"The LLM can be sweet-talked into ASKING for
   payments. Policy decides. Alice isn't in the payments row. 403."*

### Beat 4 — the audit trail + the honest caveat (2 min)
Scroll the tool-server/customer-api logs. Then the caveat that builds trust:
> "The LLM is provider-agnostic — swap in any OpenAI-compatible provider with
> a config change. The moment you do, that provider's key becomes the one
> static secret left. The fix is an LLM gateway that accepts workload identity.
> Default here is a local model precisely so the claim 'zero secrets' is
> literally true."

### If it breaks mid-demo
- Any pod not Ready → `kubectl -n agent-nhi get pods`, then show the 3D viz
  and keep talking — the architecture carries the story even if a pod sulks.
- Token exchange 400s → almost always the SPIRE JWKS fetch; see
  [runbook.md](runbook.md#troubleshooting). Worst case: show the audit lines
  from your rehearsal run.

### Likely Q&A
- **"Why not just Kubernetes service account tokens?"** They're bearer tokens
  for talking TO the API server, not an identity framework: no cross-platform
  story, no SVID semantics, no OIDC-discoverable signing. SPIFFE is the
  portable abstraction; K8s attestation is just the evidence.
- **"Why not just mTLS?"** That IS the X.509-SVID flavor of this same
  identity — this demo uses JWT-SVIDs because OAuth token exchange rides on
  them. Both come from the same SPIRE.
- **"Performance cost?"** SVID fetch is a local socket call; exchange is one
  HTTPS POST per hop, cached for the token's 5-minute life.
- **"Does this work with MCP?"** Yes — see
  [mcp-migration.md](mcp-migration.md); the tool server IS the boundary MCP
  formalizes.
