#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
if [[ -f "$ROOT/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "$ROOT/.env"
  set +a
fi

: "${B2_ENDPOINT:?set B2_ENDPOINT}"
: "${B2_REGION:?set B2_REGION}"
: "${B2_BUCKET:?set B2_BUCKET}"
: "${B2_PREFIX:=clusters/production/current/}"
: "${B2_ARCHIVE_PREFIX:=clusters/production/releases/}"
: "${AWS_ACCESS_KEY_ID:?set the B2 publisher key ID}"
: "${AWS_SECRET_ACCESS_KEY:?set the B2 publisher application key}"

B2_PREFIX="${B2_PREFIX%/}/"
B2_ARCHIVE_PREFIX="${B2_ARCHIVE_PREFIX%/}/"

command -v gh >/dev/null
gh auth status >/dev/null

if [[ -z ${GITHUB_REPOSITORY:-} ]]; then
  GITHUB_REPOSITORY=$(gh repo view --json nameWithOwner --jq .nameWithOwner)
fi

gh api --method PUT "repos/$GITHUB_REPOSITORY/environments/production" >/dev/null

gh variable set B2_ENDPOINT --repo "$GITHUB_REPOSITORY" --env production --body "$B2_ENDPOINT"
gh variable set B2_REGION --repo "$GITHUB_REPOSITORY" --env production --body "$B2_REGION"
gh variable set B2_BUCKET --repo "$GITHUB_REPOSITORY" --env production --body "$B2_BUCKET"
gh variable set B2_PREFIX --repo "$GITHUB_REPOSITORY" --env production --body "$B2_PREFIX"
gh variable set B2_ARCHIVE_PREFIX --repo "$GITHUB_REPOSITORY" --env production --body "$B2_ARCHIVE_PREFIX"

printf '%s' "$AWS_ACCESS_KEY_ID" |
  gh secret set B2_WRITE_KEY_ID --repo "$GITHUB_REPOSITORY" --env production --body -
printf '%s' "$AWS_SECRET_ACCESS_KEY" |
  gh secret set B2_WRITE_APPLICATION_KEY --repo "$GITHUB_REPOSITORY" --env production --body -

echo "Configured GitHub environment production for $GITHUB_REPOSITORY"
