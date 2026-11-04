#!/bin/sh
# Git calls this for credentials when an app uses a personal access token.
# The token is read from a root-only file, so it never lands in the remote URL or the process list.
case "$1" in
  Username*) echo "${FAWWK_GIT_USER:-x-access-token}" ;;
  *) cat "$FAWWK_GIT_TOKEN_FILE" ;;
esac
