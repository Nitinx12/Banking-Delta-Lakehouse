#!/bin/bash
set -euo pipefail

echo "--- Stopping Session: Checking touched files ---"
git status -s
echo "---------------------------------------------------"

exit 0
