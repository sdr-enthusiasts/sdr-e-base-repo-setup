#!/usr/bin/env bash
#
# migrate.sh — interactive driver for the sdr-enthusiasts repo migration.
#
# Walks one repo through the migration flow, pausing for manual steps:
#
#   1. Pick a repo from migration-queue.txt (only repos NOT marked ✅).
#   2. Run copy_nix_files.sh inside ~/GitHub/<repo>.
#   2b. Reload direnv for the target repo (avoids stale env leaking
#       in from this repo's shell — see git history for why).
#   2c. Auto-remove known legacy files: dependabot config and the
#       cancel_dupes / pre-commit-updates workflows (.yml or .yaml).
#   3. PAUSE — you manually remove any remaining per-tool lint
#      workflows and anything needing audit. Type "continue" when
#      ready.
#   4. Verify `pre-commit run --all-files` passes. If it fails, PAUSE
#      and re-run when you type "continue"; loop until green.
#   5. git add -A && commit && push -u origin infra.
#   6. Apply repo settings + ruleset (before the PR).
#   7. Open the PR, then exit.
#
# The deterministic legacy-file removal is automated in (2c); the
# manual step in (3) is for judgment calls (per-tool lint workflows,
# anything flagged for audit).

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
# 2b. Reload direnv for the target repo.
#     migrate.sh is launched from this repo's own direnv shell, so
#     PYTHONPATH/PATH/etc. from THIS repo's flake are still exported
#     for the rest of the script (a plain `cd` inside a non-
#     interactive script does not trigger direnv's load/unload
#     hook). If the target repo pins a different nixpkgs revision,
#     that stale env silently shadows its tool versions (e.g. a
#     newer check-jsonschema resolving pure-Python deps from an
#     older, ABI-incompatible rpds-py) and pre-commit hooks fail in
#     ways that don't reproduce when run manually from a fresh
#     shell. Force a re-export scoped to $REPO_DIR before running
#     anything else that depends on its toolchain.
# ──────────────────────────────────────────────────────────────
if command -v direnv >/dev/null 2>&1 && [ -f .envrc ]; then
    step "Reloading direnv for $REPO"
    unset PYTHONPATH
    eval "$(direnv export bash)"
fi

# ──────────────────────────────────────────────────────────────
# 2c. Auto-remove known legacy files.
#     dependabot config and the cancel_dupes / pre-commit-updates
#     workflows are always superseded by the fredsystems setup, so
#     delete them deterministically here rather than relying on the
#     manual step. Extension may be .yml or .yaml — check both.
# ──────────────────────────────────────────────────────────────
step "Removing known legacy files"
for f in \
    .github/dependabot.yml .github/dependabot.yaml \
    .github/workflows/cancel_dupes.yml .github/workflows/cancel_dupes.yaml \
    .github/workflows/pre-commit-updates.yml .github/workflows/pre-commit-updates.yaml; do
    if git ls-files --error-unmatch "$f" >/dev/null 2>&1; then
        git rm -q "$f"
        info "Removed $f"
    elif [ -e "$f" ]; then
        rm -f "$f"
        info "Deleted untracked $f"
    fi
done

# ──────────────────────────────────────────────────────────────
# 3. Manual cleanup pause (per-tool lint workflows, audit review).
#    Done by hand — see flow.txt steps 2-3.
# ──────────────────────────────────────────────────────────────
step "Manual cleanup"
cat <<'EOF'
The known legacy files (dependabot config, cancel_dupes,
pre-commit-updates workflows) were removed automatically above.

Do the rest of your manual cleanup now (in another terminal, on the
infra branch):

  Remove any per-tool lint workflows (hadolint/markdownlint/yamllint/
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
