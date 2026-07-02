#!/usr/bin/env bash
# Applies (or plans/destroys) all three live units in one command: minikube,
# rds, domain-controller. None of them has a terragrunt `dependency` block on
# either of the others (see devtools-labs/CLAUDE.md), so `run-all` applies
# all three in parallel.
#
# Usage:
#   ./apply-minikube-stack.sh            # apply (interactive approval)
#   ./apply-minikube-stack.sh plan
#   ./apply-minikube-stack.sh apply -auto-approve
#   ./apply-minikube-stack.sh destroy
set -euo pipefail
cd "$(dirname "$0")"

ACTION="${1:-apply}"
shift || true

terragrunt run-all "$ACTION" \
  --queue-include-dir minikube \
  --queue-include-dir rds \
  --queue-include-dir domain-controller \
  --queue-strict-include \
  "$@"
