#!/bin/bash
set -euo pipefail

# Help handler
if [[ "$1" == "-h" || "$1" == "--help" || $# -ne 3 ]]; then
    echo "Usage: $0 <folder> <new_repo_name> <github_owner>"
    echo "Example: $0 folder my-repo my-github-username"
    exit 0
fi

FOLDER=$1
REPO_NAME=$2
OWNER=$3

echo "--- Step 1: Creating remote repository $OWNER/$REPO_NAME ---"
gh repo create "$OWNER/$REPO_NAME" --public || echo "Repo already exists, continuing..."

echo "--- Step 2: Pushing $FOLDER history to $REPO_NAME ---"
# This identifies the commits that touched FOLDER and sends them to the new repo
git subtree push --prefix="$FOLDER" "https://github.com/$OWNER/$REPO_NAME.git" main

echo "--- Step 3: Re-adding as a tracked subtree ---"
# We remove and re-add to ensure Git's internal tracking is initialized for pulling
# This doesn't delete your files, it just 'registers' the remote connection
git subtree add --prefix="$FOLDER" "https://github.com/$OWNER/$REPO_NAME.git" main --squash || echo "Subtree already linked."

echo "--- Done! ---"
echo "You can now use your new aliases:"
echo "  git subpush $FOLDER $REPO_NAME"
echo "  git subpull $FOLDER $REPO_NAME"