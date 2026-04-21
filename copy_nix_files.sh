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
FLAKE_COPIED=0
RENOVATE_COPIED=0
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

    case "$dst_rel" in
    flake.nix)     FLAKE_COPIED=1 ;;
    renovate.json) RENOVATE_COPIED=1 ;;
    esac
done

# ──────────────────────────────────────────────────────────────
# Language detection (by canonical manifest presence)
# ──────────────────────────────────────────────────────────────
HAS_RUST=0
HAS_NODE=0
HAS_PYTHON=0
HAS_DOCKER=0

[ -f "$TARGET_DIR/Cargo.toml" ]         && HAS_RUST=1
[ -f "$TARGET_DIR/package.json" ]       && HAS_NODE=1
{ [ -f "$TARGET_DIR/pyproject.toml" ] \
    || [ -f "$TARGET_DIR/requirements.txt" ] \
    || [ -f "$TARGET_DIR/setup.py" ] \
    || [ -f "$TARGET_DIR/setup.cfg" ]; } && HAS_PYTHON=1
{ [ -f "$TARGET_DIR/Dockerfile" ] \
    || [ -f "$TARGET_DIR/Dockerfile.org" ] \
    || ls "$TARGET_DIR"/Dockerfile.* >/dev/null 2>&1; } && HAS_DOCKER=1

detected=""
[ "$HAS_RUST"   = 1 ] && detected="$detected rust"
[ "$HAS_NODE"   = 1 ] && detected="$detected node"
[ "$HAS_PYTHON" = 1 ] && detected="$detected python"
[ "$HAS_DOCKER" = 1 ] && detected="$detected docker"
if [ -n "$detected" ]; then
    info "Detected languages:${detected}"
else
    info "No extra languages detected (base config only)"
fi

# ──────────────────────────────────────────────────────────────
# Patch flake.nix toggles (only if we just copied it)
# ──────────────────────────────────────────────────────────────
patch_flake_toggle() {
    key="$1"     # e.g. check_rust
    value="$2"   # true|false
    file="$3"
    if [ "$DRY_RUN" -eq 1 ]; then
        printf '🧪 DRY-RUN › sed -i s/%s = .*/%s = %s;/ %s\n' "$key" "$key" "$value" "$file"
    else
        # Match optional leading whitespace, preserve it
        sed -i -E "s/^([[:space:]]*)${key}[[:space:]]*=[[:space:]]*(true|false);/\\1${key} = ${value};/" "$file"
    fi
}

if [ "$FLAKE_COPIED" -eq 1 ] && [ -f "$TARGET_DIR/flake.nix" ]; then
    info "Patching flake.nix language toggles"
    [ "$HAS_RUST"   = 1 ] && { patch_flake_toggle check_rust   true  "$TARGET_DIR/flake.nix"; info "  check_rust   = true"; }
    [ "$HAS_DOCKER" = 1 ] && { patch_flake_toggle check_docker true  "$TARGET_DIR/flake.nix"; info "  check_docker = true"; }
    [ "$HAS_PYTHON" = 1 ] && { patch_flake_toggle check_python true  "$TARGET_DIR/flake.nix"; info "  check_python = true"; }
    if [ "$HAS_NODE" = 1 ]; then
        warn "Node project detected — pre-commit-checks has no canonical node toggle."
        warn "Review flake.nix manually (consider nodejs + prettier/eslint in devShell buildInputs)."
    fi
elif [ "$FLAKE_COPIED" -eq 0 ] && [ -f "$TARGET_DIR/flake.nix" ]; then
    warn "flake.nix was pre-existing — skipping toggle patches (re-run with --force=files to overwrite)"
fi

# ──────────────────────────────────────────────────────────────
# Patch renovate.json enabledManagers (only if we just copied it)
# ──────────────────────────────────────────────────────────────
patch_renovate_managers() {
    file="$1"
    shift
    extra_managers="$*"
    [ -z "$extra_managers" ] && return 0

    if ! command -v jq >/dev/null 2>&1; then
        warn "jq not found — cannot patch renovate.json. Add these managers manually: $extra_managers"
        return 0
    fi

    # Build a JSON array from space-separated names (intentional word-splitting).
    # shellcheck disable=SC2086
    to_add=$(printf '%s\n' $extra_managers | jq -R . | jq -s .)

    if [ "$DRY_RUN" -eq 1 ]; then
        printf '🧪 DRY-RUN › jq merge enabledManagers += %s in %s\n' "$to_add" "$file"
        return 0
    fi

    tmp=$(mktemp)
    jq --argjson add "$to_add" '
        .enabledManagers = ((.enabledManagers // []) + $add | unique)
    ' "$file" > "$tmp" && mv "$tmp" "$file"
}

if [ "$RENOVATE_COPIED" -eq 1 ] && [ -f "$TARGET_DIR/renovate.json" ]; then
    extra=""
    [ "$HAS_RUST"   = 1 ] && extra="$extra cargo"
    [ "$HAS_NODE"   = 1 ] && extra="$extra npm"
    [ "$HAS_PYTHON" = 1 ] && extra="$extra pep621 pip_requirements"
    if [ -n "$extra" ]; then
        info "Extending renovate.json enabledManagers:$extra"
        # Intentional word-splitting: $extra is a space-separated list of managers.
        # shellcheck disable=SC2086
        patch_renovate_managers "$TARGET_DIR/renovate.json" $extra
    else
        info "renovate.json: no language-specific managers to add"
    fi
elif [ "$RENOVATE_COPIED" -eq 0 ] && [ -f "$TARGET_DIR/renovate.json" ]; then
    warn "renovate.json was pre-existing — skipping manager patches (re-run with --force=files to overwrite)"
fi

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
