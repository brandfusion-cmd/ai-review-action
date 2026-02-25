#!/usr/bin/env bash
set -euo pipefail

# Collect PR diff and source files for AI review
# Output: /tmp/ai-review/context.txt, /tmp/ai-review/config.yml

WORKDIR="/tmp/ai-review"
mkdir -p "$WORKDIR"

echo "::group::Collecting PR context"

# --- Load project config ---
CONFIG_PATH="${CONFIG_PATH:-.ai-review.yml}"
if [[ -f "$CONFIG_PATH" ]]; then
  cp "$CONFIG_PATH" "$WORKDIR/config.yml"
  echo "Loaded project config from $CONFIG_PATH"
else
  echo "No config found at $CONFIG_PATH — using defaults"
  cat > "$WORKDIR/config.yml" <<'DEFAULTCFG'
stack: unknown
conventions: ""
review_focus:
  - security
  - error-handling
DEFAULTCFG
fi

# --- Determine base ref ---
BASE_REF="${GITHUB_BASE_REF:-main}"
# Ensure we have the base branch
git fetch origin "$BASE_REF" --depth=50 2>/dev/null || true

# --- Generate diff ---
DIFF_FILE="$WORKDIR/diff.patch"
git diff "origin/$BASE_REF"...HEAD > "$DIFF_FILE" 2>/dev/null || git diff "origin/$BASE_REF" HEAD > "$DIFF_FILE"

DIFF_LINES=$(wc -l < "$DIFF_FILE")
echo "Diff: $DIFF_LINES lines"

# --- Collect changed source files ---
CHANGED_FILES=$(git diff --name-only "origin/$BASE_REF"...HEAD 2>/dev/null || git diff --name-only "origin/$BASE_REF" HEAD)
CONTEXT_FILE="$WORKDIR/context.txt"

{
  echo "=== PROJECT CONFIG ==="
  cat "$WORKDIR/config.yml"
  echo ""
  echo "=== DIFF ($DIFF_LINES lines) ==="
  cat "$DIFF_FILE"
  echo ""
} > "$CONTEXT_FILE"

# If context is small enough, include full source files
CONTEXT_SIZE=$(wc -c < "$CONTEXT_FILE")
MAX_CONTEXT=500000  # 500KB safety limit

if [[ "$CONTEXT_SIZE" -lt "$MAX_CONTEXT" ]]; then
  echo "" >> "$CONTEXT_FILE"
  echo "=== CHANGED SOURCE FILES (full content) ===" >> "$CONTEXT_FILE"

  while IFS= read -r file; do
    [[ -z "$file" ]] && continue
    [[ ! -f "$file" ]] && continue
    # Skip binary files
    if file --mime "$file" | grep -q 'binary'; then
      echo "Skipping binary: $file"
      continue
    fi
    FILE_SIZE=$(wc -c < "$file")
    CURRENT_SIZE=$(wc -c < "$CONTEXT_FILE")
    if (( CURRENT_SIZE + FILE_SIZE > MAX_CONTEXT )); then
      echo "Context limit reached, stopping file collection"
      break
    fi
    {
      echo ""
      echo "--- FILE: $file ---"
      cat "$file"
    } >> "$CONTEXT_FILE"
  done <<< "$CHANGED_FILES"
fi

FINAL_SIZE=$(wc -c < "$CONTEXT_FILE")
FILE_COUNT=$(echo "$CHANGED_FILES" | grep -c '.' || true)
echo "Context: ${FINAL_SIZE} bytes, ${FILE_COUNT} changed files"

# Save changed files list for later steps
echo "$CHANGED_FILES" > "$WORKDIR/changed-files.txt"

echo "::endgroup::"
