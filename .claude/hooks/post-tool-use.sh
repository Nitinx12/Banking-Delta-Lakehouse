#!/bin/bash
set -euo pipefail

# Read event from stdin
read -r EVENT
FILE_PATH=$(echo "$EVENT" | jq -r '.result.filePath // empty')

if [[ -n "$FILE_PATH" && "$FILE_PATH" == *.py ]]; then
    # Auto-format Python files using ruff
    ruff format "$FILE_PATH"
    ruff check --fix "$FILE_PATH"
fi

exit 0
