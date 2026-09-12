# Tests for opa/policy.rego — run: opa test opa/ -v  (also runs in CI)
package agentnhi.authz

import rego.v1

AGENT := "spiffe://acme.com/ns/agent-nhi/sa/agent"

test_allow_profile_for_alice if {
  allow with input as {"agent": AGENT, "user": "alice", "tool": "customer.profile.read"}
}

test_deny_payments_for_alice if {
  not allow with input as {"agent": AGENT, "user": "alice", "tool": "customer.payments.read"}
}

test_allow_payments_for_admin if {
  allow with input as {"agent": AGENT, "user": "admin", "tool": "customer.payments.read"}
}

test_deny_rogue_workload if {
  not allow with input as {
    "agent": "spiffe://acme.com/ns/agent-nhi/sa/rogue",
    "user": "alice",
    "tool": "customer.profile.read",
  }
}

test_deny_missing_identity if {
  not allow with input as {"agent": "", "user": "alice", "tool": "customer.profile.read"}
}
