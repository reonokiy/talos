#!/usr/bin/env bash
set -euo pipefail

: "${B2_ENDPOINT:?load it from 1Password with the fnox publisher profile}"
: "${B2_REGION:?load it from 1Password with the fnox publisher profile}"
: "${B2_BUCKET:?load it from 1Password with the fnox publisher profile}"
: "${B2_PREFIX:=clusters/production/current/}"
: "${B2_ARCHIVE_PREFIX:=clusters/production/releases/}"
: "${AWS_ACCESS_KEY_ID:?load the B2 publisher key ID with fnox}"
: "${AWS_SECRET_ACCESS_KEY:?load the B2 publisher application key with fnox}"

B2_PREFIX="${B2_PREFIX%/}/"
B2_ARCHIVE_PREFIX="${B2_ARCHIVE_PREFIX%/}/"
PUBLISH_KEY_ID=$AWS_ACCESS_KEY_ID
PUBLISH_APPLICATION_KEY=$AWS_SECRET_ACCESS_KEY
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY

command -v gh >/dev/null
gh auth status >/dev/null

if [[ -z ${GITHUB_REPOSITORY:-} ]]; then
  GITHUB_REPOSITORY=$(gh repo view --json nameWithOwner --jq .nameWithOwner)
fi

ENVIRONMENT_ENDPOINT="repos/$GITHUB_REPOSITORY/environments/production"

if gh api "$ENVIRONMENT_ENDPOINT" >/dev/null 2>&1; then
  CUSTOM_BRANCHES=$(gh api "$ENVIRONMENT_ENDPOINT" \
    --jq '.deployment_branch_policy.custom_branch_policies // false')
  if [[ $CUSTOM_BRANCHES != true ]]; then
    OTHER_PROTECTION_RULES=$(gh api "$ENVIRONMENT_ENDPOINT" \
      --jq '[.protection_rules[]? | select(.type != "branch_policy")] | length')
    if ((OTHER_PROTECTION_RULES > 0)); then
      echo "Refusing to replace existing production protection rules." >&2
      echo "Select custom deployment branches in GitHub, then rerun this task." >&2
      exit 1
    fi
  fi
else
  CUSTOM_BRANCHES=false
fi

if [[ $CUSTOM_BRANCHES != true ]]; then
  printf '%s\n' \
    '{"deployment_branch_policy":{"protected_branches":false,"custom_branch_policies":true}}' |
    gh api --method PUT "$ENVIRONMENT_ENDPOINT" --input - >/dev/null
fi

# Converge to exactly one deployment ref. This removes stale wildcard, tag, or
# branch policies that could otherwise expose production secrets to another ref.
while IFS= read -r POLICY_ID; do
  [[ -n $POLICY_ID ]] || continue
  gh api --method DELETE \
    "$ENVIRONMENT_ENDPOINT/deployment-branch-policies/$POLICY_ID" >/dev/null
done < <(gh api --paginate "$ENVIRONMENT_ENDPOINT/deployment-branch-policies" \
  --jq '.branch_policies[] | select(.name != "main" or ((.type // "branch") != "branch")) | .id')

MAIN_POLICY_IDS=$(gh api --paginate \
  "$ENVIRONMENT_ENDPOINT/deployment-branch-policies" \
  --jq '.branch_policies[] | select(.name == "main" and ((.type // "branch") == "branch")) | .id')
if [[ -z $MAIN_POLICY_IDS ]]; then
  gh api --method POST \
    "$ENVIRONMENT_ENDPOINT/deployment-branch-policies" \
    -f name=main \
    -f type=branch >/dev/null
fi

UNSAFE_POLICY_IDS=$(gh api --paginate \
  "$ENVIRONMENT_ENDPOINT/deployment-branch-policies" \
  --jq '.branch_policies[] | select(.name != "main" or ((.type // "branch") != "branch")) | .id')
MAIN_POLICY_IDS=$(gh api --paginate \
  "$ENVIRONMENT_ENDPOINT/deployment-branch-policies" \
  --jq '.branch_policies[] | select(.name == "main" and ((.type // "branch") == "branch")) | .id')
if [[ -n $UNSAFE_POLICY_IDS || -z $MAIN_POLICY_IDS ]]; then
  echo "production Environment did not converge to the main-only policy." >&2
  exit 1
fi

gh variable set B2_ENDPOINT --repo "$GITHUB_REPOSITORY" --env production --body "$B2_ENDPOINT"
gh variable set B2_REGION --repo "$GITHUB_REPOSITORY" --env production --body "$B2_REGION"
gh variable set B2_BUCKET --repo "$GITHUB_REPOSITORY" --env production --body "$B2_BUCKET"
gh variable set B2_PREFIX --repo "$GITHUB_REPOSITORY" --env production --body "$B2_PREFIX"
gh variable set B2_ARCHIVE_PREFIX --repo "$GITHUB_REPOSITORY" --env production --body "$B2_ARCHIVE_PREFIX"

printf '%s' "$PUBLISH_KEY_ID" |
  gh secret set B2_WRITE_KEY_ID --repo "$GITHUB_REPOSITORY" --env production
printf '%s' "$PUBLISH_APPLICATION_KEY" |
  gh secret set B2_WRITE_APPLICATION_KEY --repo "$GITHUB_REPOSITORY" --env production

echo "Configured main-only B2 Variables/Secrets in production for $GITHUB_REPOSITORY"
