#!/bin/bash
set -euo pipefail

# Read event from stdin
read -r EVENT
# Extract tool name and arguments if available
TOOL_NAME=$(echo "$EVENT" | jq -r '.tool // empty')
ARGS=$(echo "$EVENT" | jq -r '.arguments // empty')

# Block edits to protected files
PROTECTED_FILES=(".env" "audit_tables" "secrets")
for FILE in "${PROTECTED_FILES[@]}"; do
    if [[ "$ARGS" == *"$FILE"* ]]; then
        echo "Error: Attempted to edit protected file: $FILE"
        exit 1
    fi
done

exit 0
