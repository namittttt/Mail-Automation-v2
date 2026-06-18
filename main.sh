#!/bin/bash

set -e

echo "========================================"
echo " Mail Server Automation Manager"
echo "========================================"

echo
echo "[1/5] Making Scripts Executable..."

chmod +x *.sh

echo
echo "[2/5] Running Validation..."

if [ -f ./08-validate.sh ]; then
    ./08-validate.sh
fi

echo
echo "[3/5] Git Status..."

git status

echo
echo "[4/5] Commit Changes..."

read -p "Commit Message: " MESSAGE

git add .

git commit -m "$MESSAGE"

echo
echo "[5/5] Push to GitHub..."

CURRENT_BRANCH=$(git branch --show-current)

git push origin "$CURRENT_BRANCH"

echo
echo "========================================"
echo " GitHub Push Complete"
echo "========================================"

