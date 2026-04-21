#!/usr/bin/env bash
# apply_repo_settings.sh
#
# Applies standardized settings to a single sdr-enthusiasts repo:
#   1. Enables auto-merge
#   2. Disables `web_commit_signoff_required` (breaks bot PRs)
#   3. Creates a "Default" branch ruleset on main/default branch with:
#        - bypass: OrganizationAdmin + RepositoryRole 5 (admin)
#        - rules:  deletion, non_fast_forward, required_status_checks
#        - required checks: Lint, Test Build Summary
#
# Ruleset step is skipped if ANY ruleset already exists on the repo.
#
# Usage:  ./apply_repo_settings.sh <repo-name>
# Example: ./apply_repo_settings.sh docker-radar1090
#
# Flags:
#   -n, --dry-run    Print actions without making API calls
#       --org=NAME   Override org (default: sdr-enthusiasts)

set -eu

ORG="sdr-enthusiasts"
DRY_RUN=0
REPO=""

# Required status check contexts
REQUIRED_CHECKS='[
  {"context": "Lint"},
  {"context": "Test Build Summary"}
]'

# ──────────────────────────────────────────────────────────────
# Arg parsing
# ──────────────────────────────────────────────────────────────
for arg in "$@"; do
  case "$arg" in
    -n|--dry-run) DRY_RUN=1 ;;
    --org=*)      ORG="${arg#*=}" ;;
    -h|--help)
      sed -n '1,20p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    -*)
      printf '❌ Unknown flag: %s\n' "$arg" >&2
      exit 1
      ;;
    *)
      if [ -z "$REPO" ]; then
        REPO="$arg"
      else
        printf '❌ Multiple repo names given. Specify one.\n' >&2
        exit 1
      fi
      ;;
  esac
done

[ -n "$REPO" ] || { printf '❌ Usage: %s <repo-name>\n' "$0" >&2; exit 1; }

# ──────────────────────────────────────────────────────────────
# Helpers
# ──────────────────────────────────────────────────────────────
info() { printf 'ℹ️  %s\n' "$1"; }
ok()   { printf '✅ %s\n' "$1"; }
warn() { printf '⚠️  %s\n' "$1"; }
die()  { printf '❌ %s\n' "$1" >&2; exit 1; }

run_gh() {
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '🧪 DRY-RUN › gh %s\n' "$*"
  else
    gh "$@"
  fi
}

# ──────────────────────────────────────────────────────────────
# Sanity checks
# ──────────────────────────────────────────────────────────────
command -v gh >/dev/null 2>&1 || die "gh CLI not found"
command -v jq >/dev/null 2>&1 || die "jq not found"

info "Target: $ORG/$REPO"
[ "$DRY_RUN" -eq 1 ] && info "Running in DRY-RUN mode"
echo

# Confirm repo exists and we can see it
gh api "repos/$ORG/$REPO" >/dev/null 2>&1 || die "Cannot access repo: $ORG/$REPO"

# ──────────────────────────────────────────────────────────────
# 1. Enable auto-merge + disable signoff requirement
# ──────────────────────────────────────────────────────────────
info "Reading current repo settings..."
current=$(gh api "repos/$ORG/$REPO")
auto_merge=$(printf '%s' "$current" | jq -r '.allow_auto_merge')
signoff=$(printf '%s' "$current" | jq -r '.web_commit_signoff_required')

info "  allow_auto_merge            = $auto_merge"
info "  web_commit_signoff_required = $signoff"

need_patch=0
patch_body='{}'
if [ "$auto_merge" != "true" ]; then
  patch_body=$(printf '%s' "$patch_body" | jq '.allow_auto_merge = true')
  need_patch=1
fi
if [ "$signoff" != "false" ]; then
  patch_body=$(printf '%s' "$patch_body" | jq '.web_commit_signoff_required = false')
  need_patch=1
fi

if [ "$need_patch" -eq 1 ]; then
  info "Patching repo settings: $patch_body"
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '🧪 DRY-RUN › gh api -X PATCH repos/%s/%s --input -\n' "$ORG" "$REPO"
  else
    printf '%s' "$patch_body" | gh api -X PATCH "repos/$ORG/$REPO" --input - >/dev/null
  fi
  ok "Repo settings updated"
else
  ok "Repo settings already correct — no changes needed"
fi
echo

# ──────────────────────────────────────────────────────────────
# 2. Ruleset
# ──────────────────────────────────────────────────────────────
info "Checking for existing rulesets..."
existing=$(gh api "repos/$ORG/$REPO/rulesets" 2>/dev/null || echo '[]')
count=$(printf '%s' "$existing" | jq 'length')

if [ "$count" -gt 0 ]; then
  names=$(printf '%s' "$existing" | jq -r '.[].name' | paste -sd, -)
  warn "Ruleset(s) already present on $ORG/$REPO: $names"
  warn "Ruleset step SKIPPED — not applied."
  exit 0
fi

info "No existing rulesets. Creating 'Default'..."

ruleset_body=$(jq -n --argjson checks "$REQUIRED_CHECKS" '{
  name: "Default",
  target: "branch",
  enforcement: "active",
  conditions: {
    ref_name: {
      include: ["~DEFAULT_BRANCH"],
      exclude: []
    }
  },
  bypass_actors: [
    { actor_id: null, actor_type: "OrganizationAdmin", bypass_mode: "always" },
    { actor_id: 5,    actor_type: "RepositoryRole",    bypass_mode: "always" }
  ],
  rules: [
    { type: "deletion" },
    { type: "non_fast_forward" },
    { type: "required_status_checks",
      parameters: {
        strict_required_status_checks_policy: false,
        do_not_enforce_on_create: false,
        required_status_checks: $checks
      }
    }
  ]
}')

if [ "$DRY_RUN" -eq 1 ]; then
  printf '🧪 DRY-RUN › gh api -X POST repos/%s/%s/rulesets --input -\n' "$ORG" "$REPO"
  printf '🧪 Payload:\n%s\n' "$ruleset_body"
else
  printf '%s' "$ruleset_body" \
    | gh api -X POST "repos/$ORG/$REPO/rulesets" --input - >/dev/null
fi
ok "Ruleset 'Default' created"
echo
ok "Done: $ORG/$REPO"
