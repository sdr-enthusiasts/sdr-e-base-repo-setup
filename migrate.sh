#!/usr/bin/env bash
#
# migrate.sh — interactive driver for the sdr-enthusiasts repo migration.
#
# Walks one repo through the migration flow, pausing for manual steps:
#
#   1. Pick a repo from migration-queue.txt (only repos NOT marked ✅).
#   2. Run copy_nix_files.sh inside ~/GitHub/<repo>.
#   3. PAUSE — you manually do the `git rm` of legacy workflows /
#      dependabot and any audit cleanup. Type "continue" when ready.
#   4. Verify `pre-commit run --all-files` passes. If it fails, PAUSE
#      and re-run when you type "continue"; loop until green.
#   5. git add -A && commit && push -u origin infra.
#   6. Apply repo settings + ruleset (before the PR).
#   7. Open the PR, then exit.
#
# The git rm cleanup is intentionally NOT automated — that is the
# manual step in (3).

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
GITHUB_DIR="$HOME/GitHub"
QUEUE_FILE="$SCRIPT_DIR/migration-queue.txt"
COPY_SCRIPT="$SCRIPT_DIR/copy_nix_files.sh"
SETTINGS_SCRIPT="$SCRIPT_DIR/apply_repo_settings.sh"

COMMIT_MSG="chore(infra): migrate to fredsystems pre-commit + renovate"

# Script-scoped repo selection.
REPO=""

# ──────────────────────────────────────────────────────────────
# Logging helpers
# ──────────────────────────────────────────────────────────────
info() { printf 'ℹ️  %s\n' "$1"; }
warn() { printf '⚠️  %s\n' "$1"; }
die() {
    printf '❌ %s\n' "$1" >&2
    exit 1
}
step() { printf '\n━━━ %s ━━━\n' "$1"; }

# Wait until the user types "continue" (case-insensitive). Anything
# else re-prompts; "quit"/"q" aborts the script.
wait_for_continue() {
    local prompt="${1:-Type 'continue' to proceed}"
    local reply
    while true; do
        printf '\n⏸️  %s (continue / quit): ' "$prompt"
        read -r reply || die "No input — aborting"
        case "$(printf '%s' "$reply" | tr '[:upper:]' '[:lower:]')" in
        continue | c) return 0 ;;
        quit | q) die "Aborted by user" ;;
        *) warn "Unrecognized input: $reply" ;;
        esac
    done
}

# ──────────────────────────────────────────────────────────────
# Sanity
# ──────────────────────────────────────────────────────────────
[ -f "$QUEUE_FILE" ] || die "Queue file not found: $QUEUE_FILE"
[ -x "$COPY_SCRIPT" ] || die "Copy script not found/executable: $COPY_SCRIPT"
[ -x "$SETTINGS_SCRIPT" ] || die "Settings script not found/executable: $SETTINGS_SCRIPT"

# ──────────────────────────────────────────────────────────────
# 1. Pick a repo from the queue
# ──────────────────────────────────────────────────────────────
step "Select a repo to migrate"

# Build the list of pending repos:
#   - drop comments and blank lines
#   - drop any line marked done (✅)
#   - take the first whitespace-delimited token (strips notes like
#     "(note: ...)")
mapfile -t PENDING < <(
    grep -vE '^\s*(#|$)' "$QUEUE_FILE" |
        grep -vF '✅' |
        awk '{print $1}'
)

[ "${#PENDING[@]}" -gt 0 ] || die "No pending repos in the queue 🎉"

PS3=$'\nPick a repo (number): '
select choice in "${PENDING[@]}"; do
    if [ -n "${choice:-}" ]; then
        REPO="$choice"
        break
    fi
    warn "Invalid selection"
done

[ -n "$REPO" ] || die "No repo selected"

REPO_DIR="$GITHUB_DIR/$REPO"
[ -d "$REPO_DIR" ] || die "Repo directory not found: $REPO_DIR"

info "Selected repo: $REPO"
info "Working dir:   $REPO_DIR"
cd "$REPO_DIR"

# ──────────────────────────────────────────────────────────────
# 2. Run the copy/migrate script
# ──────────────────────────────────────────────────────────────
step "Migrating files (copy_nix_files.sh)"
"$COPY_SCRIPT"

# ──────────────────────────────────────────────────────────────
# 3. Manual cleanup pause (git rm of legacy workflows / dependabot,
#    audit review). Done by hand — see flow.txt steps 2-3.
# ──────────────────────────────────────────────────────────────
step "Manual cleanup"
cat <<'EOF'
Do your manual cleanup now (in another terminal, on the infra branch):

  git rm .github/workflows/cancel_dupes.yml 2>/dev/null || true
  git rm .github/workflows/pre-commit-updates.yaml 2>/dev/null || true
  git rm .github/dependabot.yml .github/dependabot.yaml 2>/dev/null || true

Also remove any per-tool lint workflows (hadolint/markdownlint/yamllint/
shellcheck/on_pr/linting) and anything flagged for manual audit.
EOF
wait_for_continue "Done with manual cleanup?"

# ──────────────────────────────────────────────────────────────
# 4. Verify pre-commit passes (loop until green)
# ──────────────────────────────────────────────────────────────
step "Verifying pre-commit"
while true; do
    if pre-commit run --all-files; then
        info "pre-commit passed ✅"
        break
    fi
    warn "pre-commit failed — fix the issues (note: first runs often auto-fix)."
    wait_for_continue "Ready to re-run pre-commit?"
done

# ──────────────────────────────────────────────────────────────
# 4b. Guard: dependabot must be gone before we commit
#     Legacy dependabot config is superseded by renovate. Block the
#     commit step until no dependabot file remains in the working
#     tree OR the git index (catches a staged-but-not-deleted file).
# ──────────────────────────────────────────────────────────────
step "Verifying dependabot is removed"
while true; do
    found=""
    for f in .github/dependabot.yml .github/dependabot.yaml; do
        if [ -e "$f" ] || git ls-files --error-unmatch "$f" >/dev/null 2>&1; then
            found="$found $f"
        fi
    done
    if [ -z "$found" ]; then
        info "No dependabot config present ✅"
        break
    fi
    warn "Dependabot config still present:$found"
    warn "Remove it (it is superseded by renovate), e.g.:"
    warn "  git rm$found"
    wait_for_continue "Ready to re-check for dependabot?"
done

# ──────────────────────────────────────────────────────────────
# 5. Commit + push the infra branch
# ──────────────────────────────────────────────────────────────
step "Commit + push infra branch"
git add -A
git commit -m "$COMMIT_MSG"
git push -u origin infra

# ──────────────────────────────────────────────────────────────
# 6. Apply repo settings + ruleset (before the PR)
# ──────────────────────────────────────────────────────────────
step "Applying repo settings + ruleset"
"$SETTINGS_SCRIPT" "$REPO"

# ──────────────────────────────────────────────────────────────
# 7. Open the PR, then exit
# ──────────────────────────────────────────────────────────────
step "Opening PR"
gh pr create --fill --base main --head infra

info "Done. PR opened for $REPO. Watch checks with: gh pr checks --watch"
