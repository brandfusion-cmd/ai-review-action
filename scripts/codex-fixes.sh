#!/usr/bin/env bash
set -euo pipefail

# Generate fixes for CRITICAL/BUG findings via OpenAI-compatible chat completions
# Uses parallel API calls for speed (Phase 1: validate, Phase 2: parallel API, Phase 3: collect)
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
CHANGED_FILES_LIST="${CHANGED_FILES_LIST:-$WORKDIR/changed-files.txt}"

# ============================================================
# Phase 1: Validate findings and prepare request bodies (sequential, fast)
# ============================================================
VALID_INDICES=()
SOURCE_CACHE_DIR="$WORKDIR/source-cache"
mkdir -p "$SOURCE_CACHE_DIR"

for i in $(seq 0 $(( CRITICAL_COUNT - 1 ))); do
  [[ "${#VALID_INDICES[@]}" -ge "$MAX_FIXES" ]] && break

  FINDING=$(echo "$CRITICAL_FINDINGS" | jq ".[$i]")
  FILE=$(echo "$FINDING" | jq -r '.file')
  SEVERITY=$(echo "$FINDING" | jq -r '.severity')
  LINE=$(echo "$FINDING" | jq -r '.line // "unknown"')

  echo "Validating: [$SEVERITY] $FILE:$LINE"

  # Validate file path: must be in the changed-files list (prevent path traversal from AI output)
  if [[ -f "$CHANGED_FILES_LIST" ]] && ! grep -qxF "$FILE" "$CHANGED_FILES_LIST"; then
    echo "  File '$FILE' not in changed-files list, skipping (path traversal protection)"
    continue
  fi

  # Skip if file doesn't exist
  if [[ ! -f "$FILE" ]]; then
    echo "  File not found, skipping"
    continue
  fi

  # Cache source content via files (Bash 3.2 compatible, no declare -A)
  CACHE_KEY=$(printf '%s' "$FILE" | md5 -q 2>/dev/null || printf '%s' "$FILE" | md5sum | cut -d' ' -f1)
  CACHE_FILE="$SOURCE_CACHE_DIR/$CACHE_KEY"
  if [[ ! -f "$CACHE_FILE" ]]; then
    cp "$FILE" "$CACHE_FILE"
  fi

  DESCRIPTION=$(echo "$FINDING" | jq -r '.description')
  SUGGESTION=$(echo "$FINDING" | jq -r '.suggestion')
  SOURCE_CONTENT=$(cat "$CACHE_FILE")

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

  echo "$REQUEST_BODY" > "$WORKDIR/fix-request-${i}.json"
  VALID_INDICES+=("$i")
  echo "  Validated, queued for fix"
done

VALID_COUNT="${#VALID_INDICES[@]}"
if [[ "$VALID_COUNT" -eq 0 ]]; then
  echo "No valid findings to fix"
  echo "::endgroup::"
  exit 0
fi

echo ""
echo "Phase 2: Sending $VALID_COUNT API calls in parallel..."

# ============================================================
# Phase 2: Fire all API calls in parallel
# ============================================================
PIDS=()
for i in "${VALID_INDICES[@]}"; do
  FIX_RESPONSE="$WORKDIR/fix-response-${i}.json"
  FIX_HTTP="$WORKDIR/fix-http-${i}.txt"

  curl -s -w "%{http_code}" -o "$FIX_RESPONSE" \
    -X POST "$ENDPOINT" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${API_KEY}" \
    -d @"$WORKDIR/fix-request-${i}.json" \
    --max-time 45 > "$FIX_HTTP" 2>/dev/null &

  PIDS+=("$!")
done

# Wait for all parallel requests
FAILED=0
for pid in "${PIDS[@]}"; do
  wait "$pid" || FAILED=$((FAILED + 1))
done

if [[ "$FAILED" -gt 0 ]]; then
  echo "  $FAILED API call(s) failed or timed out"
fi

echo ""
echo "Phase 3: Collecting results..."

# ============================================================
# Phase 3: Collect results (sequential)
# ============================================================
FIXES_ARRAY="[]"

for i in "${VALID_INDICES[@]}"; do
  FINDING=$(echo "$CRITICAL_FINDINGS" | jq ".[$i]")
  FILE=$(echo "$FINDING" | jq -r '.file')
  SEVERITY=$(echo "$FINDING" | jq -r '.severity')
  DESCRIPTION=$(echo "$FINDING" | jq -r '.description')
  LINE=$(echo "$FINDING" | jq -r '.line // "unknown"')

  FIX_RESPONSE="$WORKDIR/fix-response-${i}.json"
  FIX_HTTP="$WORKDIR/fix-http-${i}.txt"

  echo "Collecting: [$SEVERITY] $FILE:$LINE"

  # Check HTTP status
  HTTP_CODE=$(cat "$FIX_HTTP" 2>/dev/null || echo "000")
  if [[ "$HTTP_CODE" != "200" ]]; then
    echo "  API returned HTTP $HTTP_CODE, skipping"
    continue
  fi

  FIX_TEXT=$(jq -r '.choices[0].message.content // empty' "$FIX_RESPONSE" 2>/dev/null)

  if [[ -z "$FIX_TEXT" ]]; then
    echo "  Empty response, skipping"
    continue
  fi

  # Parse the fix response
  FIXED_CODE=$(echo "$FIX_TEXT" | jq -r '.fixed_code // empty' 2>/dev/null)
  EXPLANATION=$(echo "$FIX_TEXT" | jq -r '.explanation // "Fix applied"' 2>/dev/null)

  if [[ -z "$FIXED_CODE" ]]; then
    echo "  Could not extract fixed code, skipping"
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
done

echo "$FIXES_ARRAY" | jq . > "$FIXES_FILE"

TOTAL_FIXES=$(jq 'length' "$FIXES_FILE")
echo "Generated $TOTAL_FIXES fixes"

# Cleanup temp files
rm -rf "$WORKDIR"/fix-request-*.json "$WORKDIR"/fix-http-*.txt "$SOURCE_CACHE_DIR"

echo "::endgroup::"
