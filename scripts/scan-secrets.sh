#!/usr/bin/env bash
set -euo pipefail

# Scan PR diff for leaked secrets using gitleaks
# Runs as first step in the review pipeline — blocks if hard secrets found
# Soft warnings (architecture exposure) are passed to the AI review for context

WORKDIR="/tmp/ai-review"
SECRETS_REPORT="$WORKDIR/secrets-report.json"
mkdir -p "$WORKDIR"

echo "::group::Scanning for secrets"

# Check if gitleaks is available
if ! command -v gitleaks &>/dev/null; then
  echo "::warning::gitleaks not installed — falling back to pattern scan"
  GITLEAKS_AVAILABLE=false
else
  GITLEAKS_AVAILABLE=true
  echo "gitleaks $(gitleaks version) found"
fi

# Get the PR diff range
BASE_SHA="${BASE_SHA:-$(git merge-base HEAD origin/main 2>/dev/null || git rev-parse HEAD~1)}"
HEAD_SHA="${HEAD_SHA:-HEAD}"

FOUND_SECRETS=0
FOUND_WARNINGS=0

if [[ "$GITLEAKS_AVAILABLE" == "true" ]]; then
  # Run gitleaks on the commit range
  GITLEAKS_EXIT=0
  gitleaks detect --source . \
    --log-opts="${BASE_SHA}..${HEAD_SHA}" \
    --report-path="$SECRETS_REPORT" \
    --report-format=json \
    --no-banner \
    2>/dev/null || GITLEAKS_EXIT=$?

  if [[ "$GITLEAKS_EXIT" -eq 1 ]] && [[ -f "$SECRETS_REPORT" ]]; then
    FOUND_SECRETS=$(jq 'length' "$SECRETS_REPORT" 2>/dev/null || echo 0)
    echo "gitleaks found $FOUND_SECRETS potential secret(s):"
    jq -r '.[] | "  [\(.RuleID)] \(.File):\(.StartLine) — \(.Description)"' "$SECRETS_REPORT"
  else
    echo "gitleaks: clean"
  fi
fi

# Additional pattern scan for architecture exposure (gitleaks doesn't catch these)
DIFF_CONTENT=$(git diff "${BASE_SHA}..${HEAD_SHA}" -- . ':!*.lock' ':!*.sum' 2>/dev/null || true)

if [[ -n "$DIFF_CONTENT" ]]; then
  # Scan added lines only (lines starting with +, excluding +++ headers)
  ADDED_LINES=$(echo "$DIFF_CONTENT" | grep '^+[^+]' || true)

  # Architecture exposure patterns (localhost URLs with ports)
  LOCALHOST_HITS=$(echo "$ADDED_LINES" | grep -iE 'localhost:[0-9]{4,5}|127\.0\.0\.1:[0-9]{4,5}' || true)
  if [[ -n "$LOCALHOST_HITS" ]]; then
    FOUND_WARNINGS=$((FOUND_WARNINGS + 1))
    echo ""
    echo "::warning::Architecture exposure — localhost URLs with ports found in diff:"
    echo "$LOCALHOST_HITS" | head -10
  fi

  # Internal endpoint patterns
  ENDPOINT_HITS=$(echo "$ADDED_LINES" | grep -iE '/api_message|/api_key|/internal/' | grep -v '#\|//\s*example' || true)
  if [[ -n "$ENDPOINT_HITS" ]]; then
    FOUND_WARNINGS=$((FOUND_WARNINGS + 1))
    echo ""
    echo "::warning::Possible internal endpoint exposure:"
    echo "$ENDPOINT_HITS" | head -5
  fi
fi

echo ""
echo "Scan result: $FOUND_SECRETS secret(s), $FOUND_WARNINGS warning(s)"

# Save summary for AI review context
jq -n \
  --argjson secrets "$FOUND_SECRETS" \
  --argjson warnings "$FOUND_WARNINGS" \
  '{secrets_found: $secrets, warnings_found: $warnings}' > "$WORKDIR/secrets-summary.json"

# Hard fail on actual secrets
if [[ "$FOUND_SECRETS" -gt 0 ]]; then
  echo ""
  echo "::error::Secrets detected in PR diff! Review and remove before merging."
  echo "::endgroup::"
  exit 1
fi

echo "::endgroup::"
