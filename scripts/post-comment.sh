#!/usr/bin/env bash
set -euo pipefail

# Post AI review results as PR comment
# Input: /tmp/ai-review/findings.json, /tmp/ai-review/fixes.json

WORKDIR="/tmp/ai-review"
FINDINGS_FILE="$WORKDIR/findings.json"
FIXES_FILE="$WORKDIR/fixes.json"
COMMENT_FILE="$WORKDIR/comment.md"

echo "::group::Posting PR comment"

if [[ ! -f "$FINDINGS_FILE" ]]; then
  echo "No findings file — skipping comment"
  echo "::endgroup::"
  exit 0
fi

SUMMARY=$(jq -r '.summary' "$FINDINGS_FILE")
RISK_LEVEL=$(jq -r '.risk_level' "$FINDINGS_FILE")
FINDING_COUNT=$(jq '.findings | length' "$FINDINGS_FILE")

# Risk level emoji
case "$RISK_LEVEL" in
  LOW)      RISK_ICON="🟢" ;;
  MEDIUM)   RISK_ICON="🟡" ;;
  HIGH)     RISK_ICON="🟠" ;;
  CRITICAL) RISK_ICON="🔴" ;;
  *)        RISK_ICON="⚪" ;;
esac

# --- Build comment ---
{
  echo "## AI Code Review ${RISK_ICON}"
  echo ""
  echo "**Risk Level:** ${RISK_LEVEL} | **Findings:** ${FINDING_COUNT}"
  echo ""
  echo "### Summary"
  echo "$SUMMARY"
  echo ""

  if [[ "$FINDING_COUNT" -gt 0 ]]; then
    echo "### Findings"
    echo ""
    echo "| Severity | File | Description | Suggestion |"
    echo "|----------|------|-------------|------------|"

    jq -r '.findings[] | "| \(.severity) | `\(.file)`:\(.line // "-") | \(.description | gsub("\n"; " ") | gsub("\\|"; "/")) | \(.suggestion | gsub("\n"; " ") | gsub("\\|"; "/")) |"' "$FINDINGS_FILE"

    echo ""

    # Severity breakdown
    CRITICAL_COUNT=$(jq '[.findings[] | select(.severity == "CRITICAL")] | length' "$FINDINGS_FILE")
    BUG_COUNT=$(jq '[.findings[] | select(.severity == "BUG")] | length' "$FINDINGS_FILE")
    WARNING_COUNT=$(jq '[.findings[] | select(.severity == "WARNING")] | length' "$FINDINGS_FILE")
    INFO_COUNT=$(jq '[.findings[] | select(.severity == "INFO")] | length' "$FINDINGS_FILE")
    STYLE_COUNT=$(jq '[.findings[] | select(.severity == "STYLE")] | length' "$FINDINGS_FILE")

    echo "**Breakdown:** "
    [[ "$CRITICAL_COUNT" -gt 0 ]] && echo -n "🔴 $CRITICAL_COUNT critical "
    [[ "$BUG_COUNT" -gt 0 ]] && echo -n "🟠 $BUG_COUNT bugs "
    [[ "$WARNING_COUNT" -gt 0 ]] && echo -n "🟡 $WARNING_COUNT warnings "
    [[ "$INFO_COUNT" -gt 0 ]] && echo -n "🔵 $INFO_COUNT info "
    [[ "$STYLE_COUNT" -gt 0 ]] && echo -n "⚪ $STYLE_COUNT style "
    echo ""
  else
    echo "No issues found. Code looks good! ✅"
  fi

  # --- Codex fixes ---
  if [[ -f "$FIXES_FILE" ]]; then
    FIX_COUNT=$(jq 'length' "$FIXES_FILE")
    if [[ "$FIX_COUNT" -gt 0 ]]; then
      echo ""
      echo "### Suggested Fixes"
      echo ""

      for i in $(seq 0 $(( FIX_COUNT - 1 ))); do
        FIX_FILE=$(jq -r ".[$i].file" "$FIXES_FILE")
        FIX_SEV=$(jq -r ".[$i].severity" "$FIXES_FILE")
        FIX_DESC=$(jq -r ".[$i].description" "$FIXES_FILE")
        FIX_DIFF=$(jq -r ".[$i].diff" "$FIXES_FILE")
        FIX_EXPLANATION=$(jq -r ".[$i].explanation" "$FIXES_FILE")

        echo "<details>"
        echo "<summary><strong>[$FIX_SEV]</strong> $FIX_FILE — $FIX_DESC</summary>"
        echo ""
        echo '```diff'
        echo "$FIX_DIFF"
        echo '```'
        echo ""
        if [[ -n "$FIX_EXPLANATION" && "$FIX_EXPLANATION" != "null" ]]; then
          echo "**Explanation:** $FIX_EXPLANATION"
          echo ""
        fi
        echo "</details>"
        echo ""
      done
    fi
  fi

  echo "---"
  echo "<sub>🤖 Automated AI Review</sub>"
  echo ""

  # Hidden JSON payload for machine parsing
  FINDINGS_B64=$(jq -c '.' "$FINDINGS_FILE" | base64 -w0 2>/dev/null || jq -c '.' "$FINDINGS_FILE" | base64)
  FIXES_B64="e30="
  if [[ -f "$FIXES_FILE" ]]; then
    FIXES_B64=$(jq -c '.' "$FIXES_FILE" | base64 -w0 2>/dev/null || jq -c '.' "$FIXES_FILE" | base64)
  fi
  echo "<!-- AI_REVIEW_FINDINGS: ${FINDINGS_B64} -->"
  echo "<!-- AI_REVIEW_FIXES: ${FIXES_B64} -->"

} > "$COMMENT_FILE"

# --- Delete previous AI review comments ---
REPO="${GITHUB_REPOSITORY}"
EXISTING_COMMENTS=$(gh api "repos/${REPO}/issues/${PR_NUMBER}/comments" --jq '.[] | select(.body | contains("AI_REVIEW_FINDINGS:")) | .id' 2>/dev/null || true)

for COMMENT_ID in $EXISTING_COMMENTS; do
  echo "Deleting previous AI review comment: $COMMENT_ID"
  gh api "repos/${REPO}/issues/${PR_NUMBER}/comments/${COMMENT_ID}" -X DELETE 2>/dev/null || true
done

# --- Post new comment ---
gh pr comment "$PR_NUMBER" --body-file "$COMMENT_FILE"

echo "Comment posted on PR #${PR_NUMBER}"
echo "::endgroup::"
