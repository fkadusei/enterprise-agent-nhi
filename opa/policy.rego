# =============================================================================
# OPA policy — the authorization brain of the demo.
#
# Deny-by-default. A tool call is allowed only if ALL of these hold:
#   * the caller workload carries the ONE agent identity this demo trusts
#     (its SPIFFE ID, extracted from the token's act claim by the tool server)
#   * the (tool, user) pair is permitted by the table below
#
# In production this file is how you change agent behavior WITHOUT redeploying
# anything: merge a policy PR, ConfigMap updates, every agent instantly obeys.
# Tested by opa/tests/policy_test.rego (runs in CI).
# =============================================================================
package agentnhi.authz

import rego.v1

default allow := false

# The single workload identity this demo has registered in SPIRE.
trusted_agent := "spiffe://acme.com/ns/agent-nhi/sa/agent"

# Tool permissions: user -> set of tools the agent may invoke for them.
user_tools := {
  "alice": {"customer.profile.read"},
  "admin": {"customer.profile.read", "customer.payments.read"},
}

allow if {
  input.agent == trusted_agent
  input.tool in user_tools[input.user]
}

# A human-readable reason is returned to callers and written to the audit log.
reason := "allowed by policy" if allow

reason := sprintf("untrusted workload identity %q — not a registered agent", [input.agent]) if {
  not allow
  input.agent != trusted_agent
}

reason := sprintf("tool %q not permitted for user %q", [input.tool, input.user]) if {
  not allow
  input.agent == trusted_agent
}
