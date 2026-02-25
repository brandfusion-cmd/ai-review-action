#!/usr/bin/env bash
set -euo pipefail

# Generate fixes for CRITICAL/BUG findings via OpenAI-compatible chat completions
# Input: /tmp/ai-review/findings.json
# Output: /tmp/ai-review/fixes.json

WORKDIR="/tmp/ai-review"
FINDINGS_FILE="$WORKDIR/findings.json"
FIXES_FILE="$WORKDIR/fixes.json"
MAX_FIXES="${MAX_FIXES:-5}"
# Hard cap to prevent abuse
(( MAX_FIXES > 10 )) && MAX_FIXES=10

echo "::group::Generating fixes"

# Initialize empty fixes array
echo '[]' > "$FIXES_FILE"

if [[ ! -f "$FINDINGS_FILE" ]]; then
  echo "No findings file — skipping fixes"
  echo "::endgroup::"
  exit 0
fi

# Filter CRITICAL and BUG findings
CRITICAL_FINDINGS=$(jq '[.findings[] | select(.severity == "CRITICAL" or .severity == "BUG")]' "$FINDINGS_FILE")
CRITICAL_COUNT=$(echo "$CRITICAL_FINDINGS" | jq 'length')

if [[ "$CRITICAL_COUNT" -eq 0 ]]; then
  echo "No CRITICAL/BUG findings — skipping fixes"
  echo "::endgroup::"
  exit 0
fi

echo "Found $CRITICAL_COUNT CRITICAL/BUG findings, generating fixes (max $MAX_FIXES, model: $FIX_MODEL)"

ENDPOINT="${API_URL}/chat/completions"
FIX_COUNT=0
FIXES_ARRAY="[]"

for i in $(seq 0 $(( CRITICAL_COUNT - 1 ))); do
  [[ "$FIX_COUNT" -ge "$MAX_FIXES" ]] && break

  FINDING=$(echo "$CRITICAL_FINDINGS" | jq ".[$i]")
  SEVERITY=$(echo "$FINDING" | jq -r '.severity')
  FILE=$(echo "$FINDING" | jq -r '.file')
  DESCRIPTION=$(echo "$FINDING" | jq -r '.description')
  SUGGESTION=$(echo "$FINDING" | jq -r '.suggestion')
  LINE=$(echo "$FINDING" | jq -r '.line // "unknown"')

  echo "Fix $((FIX_COUNT + 1))/$MAX_FIXES: [$SEVERITY] $FILE:$LINE"

  # Validate file path: must be in the changed-files list (prevent path traversal from AI output)
  CHANGED_FILES_LIST="${CHANGED_FILES_LIST:-$WORKDIR/changed-files.txt}"
  if [[ -f "$CHANGED_FILES_LIST" ]] && ! grep -qxF "$FILE" "$CHANGED_FILES_LIST"; then
    echo "  File '$FILE' not in changed-files list, skipping (path traversal protection)"
    FIX_COUNT=$((FIX_COUNT + 1))
    continue
  fi

  # Skip if file doesn't exist
  if [[ ! -f "$FILE" ]]; then
    echo "  File not found, skipping"
    FIX_COUNT=$((FIX_COUNT + 1))
    continue
  fi

  SOURCE_CONTENT=$(cat "$FILE")

  PROMPT="You are a code fixer. Fix the following issue in the file.

FILE: $FILE (line $LINE)
PROBLEM: $DESCRIPTION
SUGGESTED FIX: $SUGGESTION

Here is the full file content:
\`\`\`
$SOURCE_CONTENT
\`\`\`

Respond with ONLY a JSON object containing:
- \"fixed_code\": the complete fixed file content (full file, not just the changed part)
- \"explanation\": brief explanation of what you changed (1-2 sentences)
- \"diff_description\": what lines changed and how

Do NOT include markdown fences. Respond with raw JSON only."

  REQUEST_BODY=$(jq -n \
    --arg model "$FIX_MODEL" \
    --arg prompt "$PROMPT" \
    '{
      model: $model,
      messages: [
        { role: "system", content: "You are a precise code fixer. Output valid JSON only, no markdown." },
        { role: "user", content: $prompt }
      ],
      response_format: { type: "json_object" },
      temperature: 0.1
    }'
  )

  FIX_RESPONSE="$WORKDIR/fix-response-${i}.json"

  HTTP_CODE=$(curl -s -w "%{http_code}" -o "$FIX_RESPONSE" \
    -X POST "$ENDPOINT" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${API_KEY}" \
    -d "$REQUEST_BODY" \
    --max-time 120)

  if [[ "$HTTP_CODE" != "200" ]]; then
    echo "  API returned HTTP $HTTP_CODE, skipping"
    FIX_COUNT=$((FIX_COUNT + 1))
    continue
  fi

  FIX_TEXT=$(jq -r '.choices[0].message.content // empty' "$FIX_RESPONSE")

  if [[ -z "$FIX_TEXT" ]]; then
    echo "  Empty response, skipping"
    FIX_COUNT=$((FIX_COUNT + 1))
    continue
  fi

  # Parse the fix response
  FIXED_CODE=$(echo "$FIX_TEXT" | jq -r '.fixed_code // empty' 2>/dev/null)
  EXPLANATION=$(echo "$FIX_TEXT" | jq -r '.explanation // "Fix applied"' 2>/dev/null)

  if [[ -z "$FIXED_CODE" ]]; then
    echo "  Could not extract fixed code, skipping"
    FIX_COUNT=$((FIX_COUNT + 1))
    continue
  fi

  # Generate a unified diff between original and fixed
  ORIG_TMP="$WORKDIR/orig-${i}.tmp"
  FIXED_TMP="$WORKDIR/fixed-${i}.tmp"
  cp "$FILE" "$ORIG_TMP"
  echo "$FIXED_CODE" > "$FIXED_TMP"

  FIX_DIFF=$(diff -u "$ORIG_TMP" "$FIXED_TMP" | tail -n +3 || true)

  if [[ -n "$FIX_DIFF" ]]; then
    FIXES_ARRAY=$(echo "$FIXES_ARRAY" | jq \
      --arg file "$FILE" \
      --arg severity "$SEVERITY" \
      --arg description "$DESCRIPTION" \
      --arg diff "$FIX_DIFF" \
      --arg explanation "$EXPLANATION" \
      '. + [{file: $file, severity: $severity, description: $description, diff: $diff, explanation: $explanation}]')
    echo "  Fix generated successfully"
  else
    echo "  No diff produced (model returned identical code)"
  fi

  rm -f "$ORIG_TMP" "$FIXED_TMP"
  FIX_COUNT=$((FIX_COUNT + 1))
done

echo "$FIXES_ARRAY" | jq . > "$FIXES_FILE"

TOTAL_FIXES=$(jq 'length' "$FIXES_FILE")
echo "Generated $TOTAL_FIXES fixes"

echo "::endgroup::"
