#!/usr/bin/env bash
# Refresh Salesforce sandbox AWS SSO creds.
# Usage: source scripts/refresh-aws-creds.sh <profile-name>
#   (must be sourced, not executed, so AWS_PROFILE persists in your shell)
set -euo pipefail

PROFILE="${1:-${AWS_PROFILE:-}}"

if [[ -z "$PROFILE" ]]; then
  echo "Usage: source scripts/refresh-aws-creds.sh <profile-name>"
  echo "Available profiles:"
  aws configure list-profiles 2>/dev/null || cat ~/.aws/config 2>/dev/null | grep '^\[' || true
  return 1 2>/dev/null || exit 1
fi

aws sso login --profile "$PROFILE"
export AWS_PROFILE="$PROFILE"
echo "AWS_PROFILE=$AWS_PROFILE"
aws sts get-caller-identity
