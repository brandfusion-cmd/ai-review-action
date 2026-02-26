#!/usr/bin/env bash
set -euo pipefail

# Notify an external agent about CRITICAL/BUG findings via webhook
# Reads findings.json and sends a structured message via API
# Uses persistent per-repo chat IDs (~/.a0-chat-ids/) so all notifications
# for a repo go to one chat instead of creating a new one each time.
# Skips gracefully if AGENT_API_URL is not configured (no breaking change)

WORKDIR="/tmp/ai-review"
FINDINGS_FILE="$WORKDIR/findings.json"
CHAT_ID_DIR="${HOME}/.a0-chat-ids"

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

# Persistent chat ID per repo
REPO_SLUG="${GITHUB_REPOSITORY:-unknown}"
REPO_SLUG="${REPO_SLUG//\//-}"
mkdir -p "$CHAT_ID_DIR"
CHAT_ID_FILE="$CHAT_ID_DIR/$REPO_SLUG"
CONTEXT_ID=""
if [[ -f "$CHAT_ID_FILE" ]]; then
  CONTEXT_ID=$(cat "$CHAT_ID_FILE" 2>/dev/null || true)
fi

# Send to agent API
MESSAGE_JSON=$(printf '%s' "$FINDINGS_TEXT" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))' 2>/dev/null)

_send_with_context() {
  local ctx="$1"
  local body="{\"message\": ${MESSAGE_JSON}, \"lifetime_hours\": 168"
  if [[ -n "$ctx" ]]; then
    body="${body}, \"context_id\": \"${ctx}\""
  fi
  body="${body}}"

  curl -s -w "\n%{http_code}" -X POST "$AGENT_API_URL" \
    -H "Content-Type: application/json" \
    -H "X-API-KEY: $AGENT_API_KEY" \
    -d "$body" \
    --max-time 180 2>/dev/null || echo -e "\n000"
}

RESPONSE=$(_send_with_context "$CONTEXT_ID")
HTTP_CODE=$(echo "$RESPONSE" | tail -1)
RESP_BODY=$(echo "$RESPONSE" | sed '$d')

# 404 = context expired/gone, retry without context_id
if [[ "$HTTP_CODE" == "404" && -n "$CONTEXT_ID" ]]; then
  echo "Previous chat expired, creating new one"
  rm -f "$CHAT_ID_FILE"
  RESPONSE=$(_send_with_context "")
  HTTP_CODE=$(echo "$RESPONSE" | tail -1)
  RESP_BODY=$(echo "$RESPONSE" | sed '$d')
fi

if [[ "$HTTP_CODE" == "200" ]]; then
  # Save context_id for next time
  NEW_ID=$(echo "$RESP_BODY" | python3 -c 'import sys,json; print(json.loads(sys.stdin.read()).get("context_id",""))' 2>/dev/null || true)
  if [[ -n "$NEW_ID" ]]; then
    echo "$NEW_ID" > "$CHAT_ID_FILE"
  fi
  echo "Agent notified successfully (chat: ${NEW_ID:-unknown})"
else
  echo "::warning::Agent notification returned HTTP $HTTP_CODE (non-fatal)"
fi

echo "::endgroup::"
