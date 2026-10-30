#!/bin/bash
set -euo pipefail

echo "--- Session Start ---"
echo "Current Branch: $(git rev-parse --abbrev-ref HEAD)"
echo "Git Status:"
git status -s
echo "--------------------"

exit 0
