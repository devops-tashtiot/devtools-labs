#!/usr/bin/env bash
# Applies (or plans/destroys) the minikube environment's full unit set in one
# command: minikube, rds, domain-controller. Terragrunt's dependency graph
# handles ordering and parallelism on its own — rds and domain-controller
# both read minikube's outputs (vpc_id/subnet_ids/security_group_id), so
# minikube runs first, then rds and domain-controller run in parallel since
# neither depends on the other.
#
# Deliberately excludes eks/argocd/argocd-ingress (the EKS alternative
# environment, see devtools-labs/CLAUDE.md "Key Design Decisions") via
# --queue-strict-include, so this never accidentally stands up EKS.
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
