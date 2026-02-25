#!/usr/bin/env bash
set -euo pipefail

# Call review model via OpenAI-compatible API (OpenAI-compatible)
# Input: /tmp/ai-review/context.txt
# Output: /tmp/ai-review/findings.json

WORKDIR="/tmp/ai-review"

echo "::group::Running AI review via OpenAI-compatible API"

CONTEXT_FILE="$WORKDIR/context.txt"
FINDINGS_FILE="$WORKDIR/findings.json"
ACTION_PATH="${ACTION_PATH:-.}"

if [[ ! -f "$CONTEXT_FILE" ]]; then
  echo "::error::No context file found"
  exit 1
fi

# Load system prompt
SYSTEM_PROMPT_FILE="$ACTION_PATH/prompts/review-system.txt"
if [[ ! -f "$SYSTEM_PROMPT_FILE" ]]; then
  echo "::error::System prompt not found at $SYSTEM_PROMPT_FILE"
  exit 1
fi

SYSTEM_PROMPT=$(cat "$SYSTEM_PROMPT_FILE")
CONTEXT=$(cat "$CONTEXT_FILE")

RESPONSE_SCHEMA='{
  "type": "json_schema",
  "json_schema": {
    "name": "review_findings",
    "strict": true,
    "schema": {
      "type": "object",
      "properties": {
        "summary": { "type": "string" },
        "risk_level": {
          "type": "string",
          "enum": ["LOW", "MEDIUM", "HIGH", "CRITICAL"]
        },
        "findings": {
          "type": "array",
          "items": {
            "type": "object",
            "properties": {
              "severity": {
                "type": "string",
                "enum": ["CRITICAL", "BUG", "WARNING", "INFO", "STYLE"]
              },
              "file": { "type": "string" },
              "line": { "type": "integer" },
              "description": { "type": "string" },
              "suggestion": { "type": "string" }
            },
            "required": ["severity", "file", "line", "description", "suggestion"],
            "additionalProperties": false
          }
        }
      },
      "required": ["summary", "risk_level", "findings"],
      "additionalProperties": false
    }
  }
}'

# Build OpenAI-compatible request body
REQUEST_BODY=$(jq -n \
  --arg model "$REVIEW_MODEL" \
  --arg system "$SYSTEM_PROMPT" \
  --arg context "$CONTEXT" \
  --argjson response_format "$RESPONSE_SCHEMA" \
  '{
    model: $model,
    messages: [
      { role: "system", content: $system },
      { role: "user", content: ("Review this pull request. Respond with RAW JSON only — no markdown fences, no explanation text, just the JSON object.\n\n" + $context) }
    ],
    response_format: $response_format,
    temperature: 0.2
  }'
)

# Call OpenAI-compatible API
ENDPOINT="${API_URL}/chat/completions"

HTTP_CODE=$(curl -s -w "%{http_code}" -o "$WORKDIR/api-response.json" \
  -X POST "$ENDPOINT" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${API_KEY}" \
  -d "$REQUEST_BODY" \
  --max-time 180)

if [[ "$HTTP_CODE" != "200" ]]; then
  echo "::error::OpenAI-compatible API returned HTTP $HTTP_CODE"
  cat "$WORKDIR/api-response.json" >&2
  # Create empty findings so pipeline continues
  echo '{"summary":"Review API call failed","risk_level":"MEDIUM","findings":[]}' > "$FINDINGS_FILE"
  echo "::endgroup::"
  exit 0
fi

# Extract content from OpenAI-compatible response
GENERATED_TEXT=$(jq -r '.choices[0].message.content // empty' "$WORKDIR/api-response.json")

if [[ -z "$GENERATED_TEXT" ]]; then
  echo "::warning::API returned no content"
  echo '{"summary":"No review content generated","risk_level":"LOW","findings":[]}' > "$FINDINGS_FILE"
  echo "::endgroup::"
  exit 0
fi

# Extract and validate JSON
# Some providers wrap JSON in markdown fences — strip them if present
CLEAN_TEXT="$GENERATED_TEXT"
if ! echo "$CLEAN_TEXT" | jq . > /dev/null 2>&1; then
  # Try extracting JSON from markdown code fences (awk for BSD/GNU compat)
  EXTRACTED=$(echo "$CLEAN_TEXT" | awk '/^```json/{found=1;next} /^```/{found=0} found' | head -1000)
  if [[ -n "$EXTRACTED" ]] && echo "$EXTRACTED" | jq . > /dev/null 2>&1; then
    CLEAN_TEXT="$EXTRACTED"
  else
    # Try extracting JSON between first { and last }
    EXTRACTED=$(echo "$CLEAN_TEXT" | awk 'BEGIN{p=0} /{/{p=1} p{print} /}/{if(p) exit}')
    if [[ -n "$EXTRACTED" ]] && echo "$EXTRACTED" | jq . > /dev/null 2>&1; then
      CLEAN_TEXT="$EXTRACTED"
    fi
  fi
fi

if echo "$CLEAN_TEXT" | jq . > /dev/null 2>&1; then
  echo "$CLEAN_TEXT" | jq . > "$FINDINGS_FILE"
else
  echo "::warning::Could not extract valid JSON from response"
  jq -n --arg text "$GENERATED_TEXT" \
    '{"summary": $text, "risk_level": "MEDIUM", "findings": []}' > "$FINDINGS_FILE"
fi

# Summary
FINDING_COUNT=$(jq '.findings | length' "$FINDINGS_FILE")
RISK_LEVEL=$(jq -r '.risk_level' "$FINDINGS_FILE")
echo "Review complete: $FINDING_COUNT findings, risk level: $RISK_LEVEL (model: $REVIEW_MODEL)"

echo "::endgroup::"
