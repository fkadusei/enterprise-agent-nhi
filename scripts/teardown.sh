#!/bin/bash
# teardown.sh — delete the demo cluster. Everything is disposable.
set -euo pipefail
kind delete cluster --name agent-nhi
echo "cluster agent-nhi deleted. Rebuild with ./scripts/setup.sh"
