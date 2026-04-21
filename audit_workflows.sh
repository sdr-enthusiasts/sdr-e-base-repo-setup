#!/usr/bin/env bash
# audit_workflows.sh
# Produces a per-repo report of .github/workflows/ contents for sdr-enthusiasts
# clones, flagging known-bad files for manual removal.
#
# Usage:  ./audit_workflows.sh [path-to-github-root]
# Default root: $HOME/GitHub

set -eu

ROOT="${1:-$HOME/GitHub}"

# ──────────────────────────────────────────────────────────────
# Known-bad workflows (case-insensitive, extension-agnostic match on stem)
# These should be nuked from any sdre repo.
# ──────────────────────────────────────────────────────────────
BAD_WORKFLOWS="
cancel_dupes
cancel-dupes
pre-commit-updates
pre_commit_updates
precommit-updates
dependabot
"

# ──────────────────────────────────────────────────────────────
# Known-good canonical workflows (from sdr-e-base-repo-setup/workflows/
# plus lint.yaml which is copied separately). Anything else → manual audit.
# ──────────────────────────────────────────────────────────────
CANONICAL_WORKFLOWS="
lint
test_build
update-flakes
"

# Repos to audit (all 48 cloned sdr-enthusiasts repos)
REPOS=(
  acars-bridge acars-guide acars-oxide acars_router airspy_adsb
  browser-screenshot-service common-github-workflows
  docker-acarsdec docker-acarshub docker-adsbhub docker-adsb-ultrafeeder
  docker-airnavradar docker-ais-dispatcher docker-api2sbs
  docker-aprs-tracker docker-baseimage docker-beast-splitter
  docker-dump978 docker-dumphfdl docker-flightradar24
  docker-hfdlobserver docker-install docker-opensky-network
  docker-piaware docker-planefence docker-planefinder
  docker-radar1090 docker-radarvirtuel docker-reversewebproxy
  docker-rtlsdrairband docker-sdrmap docker-sdrplay-beast1090
  docker-sdrreceiver docker-shipfeeder docker-tar1090
  docker-telegraf-adsb docker-vesselalert docker-virtualradarserver
  gitbook-adsb-guide install-libsdrplay plane-alert-db
  sdr-e-base-repo-setup sdre-bias-t-common sdre-image-api
  sdr-enthusiast-assets sdre-rust-adsb-parser sdre-rust-logging
  sdre-stubborn-io
)

# ──────────────────────────────────────────────────────────────
# Helpers
# ──────────────────────────────────────────────────────────────
stem() {
  # strip path + .yml/.yaml extension
  f="$(basename "$1")"
  f="${f%.yaml}"
  f="${f%.yml}"
  printf '%s' "$f"
}

in_list() {
  needle="$1"; shift
  # Intentional word-splitting on positional args — list items are whitespace-separated.
  # shellcheck disable=SC2048,SC2086
  printf '%s\n' $* | grep -Fxqi "$needle"
}

hr() {
  # shellcheck disable=SC2046
  printf '%0.s─' $(seq 1 70); echo
}

# ──────────────────────────────────────────────────────────────
# Summary accumulators
# ──────────────────────────────────────────────────────────────
TOTAL_REPOS=0
TOTAL_WORKFLOWS=0
TOTAL_BAD=0
TOTAL_UNKNOWN=0
TOTAL_NODEPKGS=0
BAD_SUMMARY=""
UNKNOWN_SUMMARY=""
NODEPKGS_SUMMARY=""

# ──────────────────────────────────────────────────────────────
# Per-repo report
# ──────────────────────────────────────────────────────────────
for r in "${REPOS[@]}"; do
  d="$ROOT/$r/.github/workflows"
  TOTAL_REPOS=$((TOTAL_REPOS + 1))

  hr
  printf '📦 %s\n' "$r"
  hr

  if [ ! -d "$d" ]; then
    printf '   (no .github/workflows directory)\n\n'
    continue
  fi

  # Collect workflow files
  files=$(find "$d" -maxdepth 1 -type f \( -name '*.yml' -o -name '*.yaml' \) -printf '%f\n' | sort)

  if [ -z "$files" ]; then
    printf '   (workflows dir is empty)\n\n'
    continue
  fi

  bad=""
  unknown=""
  canonical=""

  while IFS= read -r f; do
    [ -z "$f" ] && continue
    TOTAL_WORKFLOWS=$((TOTAL_WORKFLOWS + 1))
    s="$(stem "$f")"

    if in_list "$s" "$BAD_WORKFLOWS"; then
      bad="$bad $f"
      TOTAL_BAD=$((TOTAL_BAD + 1))
    elif in_list "$s" "$CANONICAL_WORKFLOWS"; then
      canonical="$canonical $f"
    else
      unknown="$unknown $f"
      TOTAL_UNKNOWN=$((TOTAL_UNKNOWN + 1))
    fi
  done <<EOF
$files
EOF

  if [ -n "$canonical" ]; then
    printf '   ✅ canonical:\n'
    for f in $canonical; do printf '      • %s\n' "$f"; done
  fi

  if [ -n "$bad" ]; then
    printf '   ❌ KNOWN-BAD (delete these):\n'
    for f in $bad; do
      printf '      • %s\n' "$f"
      BAD_SUMMARY="$BAD_SUMMARY
$r/$f"
    done
  fi

  if [ -n "$unknown" ]; then
    printf '   ❓ manual audit required:\n'
    for f in $unknown; do
      printf '      • %s\n' "$f"
      UNKNOWN_SUMMARY="$UNKNOWN_SUMMARY
$r/$f"
    done
  fi

  # ── flake.nix nodePackages scan ──────────────────────────────
  flake="$ROOT/$r/flake.nix"
  if [ -f "$flake" ]; then
    matches=$(grep -nE 'nodePackages(_[0-9]+)?[._]|\bnodePackages\b' "$flake" || true)
    if [ -n "$matches" ]; then
      printf '   🟡 nodePackages references in flake.nix:\n'
      while IFS= read -r line; do
        [ -z "$line" ] && continue
        printf '      • %s\n' "$line"
        TOTAL_NODEPKGS=$((TOTAL_NODEPKGS + 1))
        NODEPKGS_SUMMARY="$NODEPKGS_SUMMARY
$r/flake.nix:$line"
      done <<EOF2
$matches
EOF2
    fi
  fi

  echo
done

# ──────────────────────────────────────────────────────────────
# Overall summary
# ──────────────────────────────────────────────────────────────
hr
echo "SUMMARY"
hr
printf 'Repos scanned:        %d\n' "$TOTAL_REPOS"
printf 'Workflow files total: %d\n' "$TOTAL_WORKFLOWS"
printf 'Known-bad (delete):   %d\n' "$TOTAL_BAD"
printf 'Unknown (audit):      %d\n' "$TOTAL_UNKNOWN"
printf 'nodePackages refs:    %d\n' "$TOTAL_NODEPKGS"
echo

if [ -n "$BAD_SUMMARY" ]; then
  hr
  echo "KNOWN-BAD FILES (delete these)"
  hr
  printf '%s\n' "$BAD_SUMMARY" | sed '/^$/d'
  echo
fi

if [ -n "$UNKNOWN_SUMMARY" ]; then
  hr
  echo "FILES NEEDING MANUAL AUDIT"
  hr
  printf '%s\n' "$UNKNOWN_SUMMARY" | sed '/^$/d'
  echo
fi

if [ -n "$NODEPKGS_SUMMARY" ]; then
  hr
  echo "flake.nix FILES REFERENCING nodePackages"
  hr
  printf '%s\n' "$NODEPKGS_SUMMARY" | sed '/^$/d'
  echo
fi
