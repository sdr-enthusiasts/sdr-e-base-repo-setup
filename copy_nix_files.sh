#!/usr/bin/env sh
set -eu

# ──────────────────────────────────────────────────────────────
# Arguments
# ──────────────────────────────────────────────────────────────
DRY_RUN=0
NO_GIT=0
FORCE_FILES=0
FORCE_STUBS=0
FORCE_WORKFLOWS=0

for arg in "$@"; do
    case "$arg" in
    -n | --dry-run)
        DRY_RUN=1
        ;;
    --no-git)
        NO_GIT=1
        ;;
    --force=*)
        val="${arg#*=}"
        case "$val" in
        all)
            FORCE_FILES=1
            FORCE_STUBS=1
            FORCE_WORKFLOWS=1
            ;;
        *)
            IFS=',' read -r a b c <<EOF
$val
EOF
            for f in $a $b $c; do
                case "$f" in
                files) FORCE_FILES=1 ;;
                stubs) FORCE_STUBS=1 ;;
                workflows) FORCE_WORKFLOWS=1 ;;
                *)
                    printf '❌ Unknown force target: %s\n' "$f" >&2
                    exit 1
                    ;;
                esac
            done
            ;;
        esac
        ;;
    *)
        printf '❌ Unknown argument: %s\n' "$arg" >&2
        exit 1
        ;;
    esac
done

# ──────────────────────────────────────────────────────────────
# Paths
# ──────────────────────────────────────────────────────────────
SCRIPT_DIR="$(
    CDPATH=
    cd -- "$(dirname -- "$0")" && pwd
)"

TEMPLATE_DIR="$HOME/GitHub/sdr-e-base-repo-setup"
TARGET_DIR="$(pwd)"

STUBS_DIR="$SCRIPT_DIR/source-stubs"
WORKFLOWS_DIR="$SCRIPT_DIR/workflows"

FILES="
flake.nix
.envrc
.github/workflows/lint.yaml
renovate-base.json:renovate.json
"

# ──────────────────────────────────────────────────────────────
# Logging and helpers
# ──────────────────────────────────────────────────────────────
info() { printf 'ℹ️  %s\n' "$1"; }
warn() { printf '⚠️  %s\n' "$1"; }
die() {
    printf '❌ %s\n' "$1" >&2
    exit 1
}

run() {
    if [ "$DRY_RUN" -eq 1 ]; then
        printf '🧪 DRY-RUN › %s\n' "$*"
    else
        "$@"
    fi
}

git_run() {
    run git "$@"
}

detect_default_branch() {
    if git show-ref --verify --quiet refs/heads/main; then
        echo "main"
    elif git show-ref --verify --quiet refs/heads/master; then
        echo "master"
    else
        die "Neither main nor master branch found"
    fi
}

# ──────────────────────────────────────────────────────────────
# Sanity
# ──────────────────────────────────────────────────────────────
[ -d "$TEMPLATE_DIR" ] || die "Template directory not found: $TEMPLATE_DIR"

[ "$DRY_RUN" -eq 1 ] && info "Running in DRY-RUN mode"
[ "$NO_GIT" -eq 1 ] && info "Git operations disabled (--no-git)"
echo

# ──────────────────────────────────────────────────────────────
# Git preparation
# ──────────────────────────────────────────────────────────────
if [ "$NO_GIT" -ne 1 ]; then
    git rev-parse --is-inside-work-tree >/dev/null 2>&1 ||
        die "Not inside a git repository"

    if [ -n "$(git status --porcelain)" ]; then
        die "Working tree is not clean"
    fi

    DEFAULT_BRANCH="$(detect_default_branch)"

    info "Checking out $DEFAULT_BRANCH"
    git_run checkout "$DEFAULT_BRANCH"

    info "Pulling latest $DEFAULT_BRANCH"
    git_run pull --ff-only

    info "Creating/resetting infra branch"
    git_run checkout -B infra

    if [ -f .pre-commit-config.yaml ]; then
        info "Removing legacy .pre-commit-config.yaml"
        git_run rm .pre-commit-config.yaml
        git_run commit -m "chore: remove legacy pre-commit config" --no-verify
    else
        info "No legacy .pre-commit-config.yaml found"
    fi
else
    warn "Skipping all git operations"
fi

# ──────────────────────────────────────────────────────────────
# Copy base files (supports src:dst renames)
# ──────────────────────────────────────────────────────────────
for entry in $FILES; do
    case "$entry" in
    *:*)
        src_rel="${entry%%:*}"
        dst_rel="${entry#*:}"
        ;;
    *)
        src_rel="$entry"
        dst_rel="$entry"
        ;;
    esac

    src="$TEMPLATE_DIR/$src_rel"
    dst="$TARGET_DIR/$dst_rel"

    [ -e "$src" ] || {
        warn "Template missing: $src_rel"
        continue
    }

    if [ -e "$dst" ] && [ "$FORCE_FILES" -ne 1 ]; then
        warn "File exists, skipping: $dst_rel"
        continue
    fi

    run mkdir -p "$(dirname "$dst")"
    run cp "$src" "$dst"
    info "File copied: $src_rel → $dst_rel"
done

# ──────────────────────────────────────────────────────────────
# Copy source stubs
# ──────────────────────────────────────────────────────────────
if [ -d "$STUBS_DIR" ]; then
    info "Processing source stubs"

    STUBS_TARGET_DIR="$TARGET_DIR/source-stubs"

    (cd "$STUBS_DIR" && find . -type d -print) |
        while IFS= read -r dir; do
            run mkdir -p "$STUBS_TARGET_DIR/$dir"
        done

    (cd "$STUBS_DIR" && find . -type f -print) |
        while IFS= read -r file; do
            src="$STUBS_DIR/$file"
            dst="$STUBS_TARGET_DIR/$file"

            if [ -e "$dst" ] && [ "$FORCE_STUBS" -ne 1 ]; then
                warn "Stub exists, skipping: $file"
                continue
            fi

            run cp "$src" "$dst"
            info "Stub copied: $file"
        done
else
    warn "source-stubs directory not found"
fi

# ──────────────────────────────────────────────────────────────
# Append ignore rules (deduplicated)
# ──────────────────────────────────────────────────────────────
append_unique_lines() {
    src="$1"
    dst="$2"

    [ -f "$src" ] || return 0
    run touch "$dst"

    while IFS= read -r line || [ -n "$line" ]; do
        [ -z "$line" ] && continue

        if grep -Fxq "$line" "$dst"; then
            warn "Ignore rule already present: $line"
            continue
        fi

        run sh -c 'printf "%s\n" "$1" >>"$2"' _ "$line" "$dst"
        info "Ignore rule added to $(basename "$dst"): $line"
    done <"$src"
}

append_unique_lines "$TEMPLATE_DIR/git-ignores" "$TARGET_DIR/.gitignore"
append_unique_lines "$TEMPLATE_DIR/docker-ignores" "$TARGET_DIR/.dockerignore"

# ──────────────────────────────────────────────────────────────
# Copy workflows
# ──────────────────────────────────────────────────────────────
if [ -d "$WORKFLOWS_DIR" ]; then
    info "Processing workflows"

    run mkdir -p "$TARGET_DIR/.github/workflows"

    (cd "$WORKFLOWS_DIR" && find . -type f -print) |
        while IFS= read -r file; do
            src="$WORKFLOWS_DIR/$file"
            dst="$TARGET_DIR/.github/workflows/$file"

            if [ -e "$dst" ] && [ "$FORCE_WORKFLOWS" -ne 1 ]; then
                warn "Workflow exists, skipping: $file"
                continue
            fi

            run mkdir -p "$(dirname "$dst")"
            run cp "$src" "$dst"
            info "Workflow copied: $file"
        done
else
    warn "workflows directory not found"
fi

# ──────────────────────────────────────────────────────────────
# Stage new files so Nix flakes can be evaluated
# ──────────────────────────────────────────────────────────────
if [ "$NO_GIT" -ne 1 ]; then
    info "Staging files for flake evaluation"
    git_run add -A
fi

# ──────────────────────────────────────────────────────────────
# Direnv
# ──────────────────────────────────────────────────────────────
if command -v direnv >/dev/null 2>&1 && [ -f .envrc ]; then
    info "Running direnv allow"
    run direnv allow || warn "direnv allow failed"
fi

# ──────────────────────────────────────────────────────────────
# Audit list
# ──────────────────────────────────────────────────────────────
info "Files containing 'disable=' (manual audit required):"

if command -v rg >/dev/null 2>&1; then
    AUDIT_FILES="$(rg -l 'disable=' . || true)"
else
    AUDIT_FILES="$(grep -RIl 'disable=' . || true)"
fi

if [ -n "$AUDIT_FILES" ]; then
    printf '%s\n' "$AUDIT_FILES"
else
    info "No files found requiring audit"
fi

echo
info "Bootstrap complete."
