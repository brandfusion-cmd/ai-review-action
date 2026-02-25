#!/usr/bin/env bash
set -euo pipefail

# Notify an external agent about CRITICAL/BUG findings via webhook
# Reads findings.json and sends a structured message via API
# Skips gracefully if AGENT_API_URL is not configured (no breaking change)

WORKDIR="/tmp/ai-review"
FINDINGS_FILE="$WORKDIR/findings.json"

# Skip if no agent URL configured
if [[ -z "${AGENT_API_URL:-}" ]]; then
  echo "No agent API URL configured — skipping notification"
  exit 0
fi

if [[ -z "${AGENT_API_KEY:-}" ]]; then
  echo "::warning::AGENT_API_URL is set but AGENT_API_KEY is empty — skipping notification"
  exit 0
fi

if [[ ! -f "$FINDINGS_FILE" ]]; then
  echo "No findings file — skipping notification"
  exit 0
fi

# Filter CRITICAL and BUG findings
CRITICAL_FINDINGS=$(jq '[.findings[] | select(.severity == "CRITICAL" or .severity == "BUG")]' "$FINDINGS_FILE")
CRITICAL_COUNT=$(echo "$CRITICAL_FINDINGS" | jq 'length')

if [[ "$CRITICAL_COUNT" -eq 0 ]]; then
  echo "No CRITICAL/BUG findings — skipping agent notification"
  exit 0
fi

echo "::group::Notifying agent about $CRITICAL_COUNT CRITICAL/BUG findings"

# Build structured findings text
FINDINGS_TEXT="AI Review found $CRITICAL_COUNT CRITICAL/BUG issue(s) in PR #${PR_NUMBER:-unknown} (branch: ${PR_BRANCH:-unknown}).

Findings to fix:"

for i in $(seq 0 $(( CRITICAL_COUNT - 1 ))); do
  FINDING=$(echo "$CRITICAL_FINDINGS" | jq ".[$i]")
  SEVERITY=$(echo "$FINDING" | jq -r '.severity')
  FILE=$(echo "$FINDING" | jq -r '.file')
  LINE=$(echo "$FINDING" | jq -r '.line // "unknown"')
  DESCRIPTION=$(echo "$FINDING" | jq -r '.description')
  SUGGESTION=$(echo "$FINDING" | jq -r '.suggestion')

  FINDINGS_TEXT="$FINDINGS_TEXT

$((i + 1)). [$SEVERITY] $FILE:$LINE
   Problem: $DESCRIPTION
   Suggestion: $SUGGESTION"
done

FINDINGS_TEXT="$FINDINGS_TEXT

Instructions:
1. Checkout branch '${PR_BRANCH:-unknown}' and pull latest
2. Fix each CRITICAL/BUG finding listed above
3. Run tests before committing
4. Push fixes to the same branch (this triggers automatic re-review)"

# Send to agent API
MESSAGE_JSON=$(printf '%s' "$FINDINGS_TEXT" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))' 2>/dev/null)

HTTP_CODE=$(curl -s -w "%{http_code}" -o /dev/null \
  -X POST "$AGENT_API_URL" \
  -H "Content-Type: application/json" \
  -H "X-API-KEY: $AGENT_API_KEY" \
  -d "{\"message\": ${MESSAGE_JSON}, \"lifetime_hours\": 24}" \
  --max-time 15) || true

if [[ "$HTTP_CODE" == "200" ]]; then
  echo "Agent notified successfully"
else
  echo "::warning::Agent notification returned HTTP $HTTP_CODE (non-fatal)"
fi

echo "::endgroup::"
