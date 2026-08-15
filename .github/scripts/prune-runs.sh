#!/usr/bin/env bash
# Delete completed workflow runs older than ${DAYS_AGO} days.
#
# This is hygiene, not cost control, and the distinction is worth stating
# plainly: the repository is public, so Actions minutes and artifact storage are
# free, and the tarballs already expire on their own via retention-days.  What
# accumulates is the run list -- a single pull request puts eleven checks in it
# -- and a run list nobody can scan is a run history nobody reads.
#
# Adapted from benkirk/sam-queries' _prune-workflow-runs.yaml, which replaced
# the archived yanovation/delete-old-actions action with four gh api calls.  Two
# departures: the logic lives in a script so checks.yml's shellcheck gate sees
# it, and it authenticates with the built-in GITHUB_TOKEN plus
# 'permissions: actions: write' rather than a personal access token, so there is
# no secret to provision, rotate or leak.
#
# Environment:
#   DAYS_AGO   completed runs created before this many days ago are eligible
#   DRY_RUN    'true' to list what would be deleted and stop
#   GH_TOKEN   a token with actions: write on this repository
set -euo pipefail

DAYS_AGO="${DAYS_AGO:?DAYS_AGO is required}"
DRY_RUN="${DRY_RUN:-true}"

# Values arrive through the environment, never interpolated into this script's
# source, so they cannot inject.  Reject a non-integer anyway, so that the
# failure names its own cause instead of surfacing as a date(1) parse error.
case "${DAYS_AGO}" in
    '' | *[!0-9]*)
        echo "::error::DAYS_AGO must be a positive integer, got '${DAYS_AGO}'"
        exit 1
        ;;
esac

CUTOFF="$(date -u -d "${DAYS_AGO} days ago" +%Y-%m-%dT%H:%M:%SZ)"
echo "cutoff: ${CUTOFF} -- completed runs created before this are eligible"

# Collect every eligible id BEFORE deleting any of them.  Deleting during
# pagination shifts the remaining runs backwards across page boundaries, which
# silently skips roughly one run per page -- a bug that looks like the tool
# working, just not very hard.
#
# Filtering in jq rather than through the API's 'created' query parameter is
# also deliberate: a jq filter that fails to match yields nothing, whereas a
# query parameter the API ignores yields everything.  The failure modes are
# "delete too little" and "delete everything", and only one of those is
# recoverable.
#
# 'completed' only.  An in-flight run cannot be deleted, and a run still going
# after ${DAYS_AGO} days is stuck, not garbage.
mapfile -t IDS < <(
    gh api "repos/${GITHUB_REPOSITORY}/actions/runs?per_page=100" \
        --paginate \
        --jq ".workflow_runs[]
              | select(.status == \"completed\")
              | select(.created_at < \"${CUTOFF}\")
              | .id"
)

echo "eligible runs: ${#IDS[@]}"

summary() { cat >> "${GITHUB_STEP_SUMMARY:-/dev/null}"; }

if [ "${#IDS[@]}" -eq 0 ]; then
    echo "nothing to do."
    summary <<EOF
## Prune workflow runs

No completed runs older than ${DAYS_AGO} days.
EOF
    exit 0
fi

if [ "${DRY_RUN}" = "true" ]; then
    echo "DRY RUN -- would delete ${#IDS[@]} run(s):"
    printf '  %s\n' "${IDS[@]}"
    summary <<EOF
## Prune workflow runs (dry run)

Would delete **${#IDS[@]}** completed run(s) created before \`${CUTOFF}\`.
EOF
    exit 0
fi

# One failure -- a run deleted concurrently, a transient 5xx -- should not
# abandon the rest of the batch.
DELETED=0
FAILED=0
for id in "${IDS[@]}"; do
    if gh api -X DELETE "repos/${GITHUB_REPOSITORY}/actions/runs/${id}" --silent 2>/dev/null; then
        DELETED=$((DELETED + 1))
    else
        echo "::warning::failed to delete run ${id}"
        FAILED=$((FAILED + 1))
    fi
done

echo "deleted ${DELETED}, failed ${FAILED}."
summary <<EOF
## Prune workflow runs

- Cutoff: completed runs created before \`${CUTOFF}\` (${DAYS_AGO} days)
- Deleted: **${DELETED}**
- Failed: **${FAILED}**
EOF
