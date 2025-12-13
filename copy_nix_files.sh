#!/usr/bin/env sh
set -eu

TEMPLATE_DIR="$HOME/GitHub/sdr-e-base-repo-setup"
TARGET_DIR="$(pwd)"

FILES="
flake.nix
.envrc
.github/workflows/lint.yaml
renovate.json
"

warn() {
    printf '⚠️  %s\n' "$1"
}

info() {
    printf 'ℹ️  %s\n' "$1"
}

err() {
    printf '❌ %s\n' "$1" >&2
    exit 1
}

# ──────────────────────────────────────────────────────────────
# Sanity checks
# ──────────────────────────────────────────────────────────────
[ -d "$TEMPLATE_DIR" ] || err "Template directory not found: $TEMPLATE_DIR"

info "Using template: $TEMPLATE_DIR"
info "Target directory:  $TARGET_DIR"
echo

# ──────────────────────────────────────────────────────────────
# Copy files
# ──────────────────────────────────────────────────────────────
for file in $FILES; do
    src="$TEMPLATE_DIR/$file"
    dst="$TARGET_DIR/$file"

    if [ ! -e "$src" ]; then
        warn "Template file missing, skipping: $file"
        continue
    fi

    if [ -e "$dst" ]; then
        warn "File already exists, NOT overwriting: $file"
        continue
    fi

    mkdir -p "$(dirname "$dst")"
    cp "$src" "$dst"
    info "Copied: $file"
done

echo
info "Bootstrap complete."
