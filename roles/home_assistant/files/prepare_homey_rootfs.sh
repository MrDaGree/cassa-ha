#!/usr/bin/env bash
set -Eeuo pipefail

sleep 5

SLUG="homey_copro"
# Possible locations: Git checkouts (commit folders) and local dev path
CANDIDATES=( /var/lib/homeassistant/addons/git/*/"$SLUG" /var/lib/homeassistant/addons/local/"$SLUG" )

# Vendor base image to export (override with env if needed)
CONTAINER_NAME="${CONTAINER_NAME:-homey-pro}"
TAR_NAME="homey-pro-rootfs.tar"
MIN_BYTES=$((50*1024*1024))  # sanity threshold (50MB)

log(){ echo "[prepare_rootfs] $*"; }

# Pick the newest existing candidate with a Dockerfile (i.e., valid build context)
pick_context() {
  local paths=()
  for p in "${CANDIDATES[@]}"; do
    [[ -d "$p" && -f "$p/Dockerfile" ]] && paths+=("$p")
  done
  [[ ${#paths[@]} -eq 0 ]] && return 1
  # sort by mtime, newest first
  stat -c '%Y %n' "${paths[@]}" 2>/dev/null | sort -nr | awk '{ $1=""; sub(/^ /,""); print; }' | head -n1
}

CTX="$(pick_context || true)"
if [[ -z "${CTX:-}" ]]; then
  log "No add-on worktree found yet (looked at /var/lib/homeassistant/addons/git/*/$SLUG and /var/lib/homeassistant/addons/local/$SLUG)."
  exit 0
fi

DEST="$CTX/$TAR_NAME"
TMP="/tmp/$TAR_NAME.$$"

# Skip if a sane tar is already present
if [[ -f "$DEST" ]]; then
  sz=$(stat -c '%s' "$DEST" 2>/dev/null || echo 0)
  if (( sz >= MIN_BYTES )); then
    log "Tar already present at $DEST ($sz bytes), skipping."
    exit 0
  else
    log "Existing tar too small ($sz bytes), will regenerate."
  fi
fi

# Ensure vendor image exists locally
if ! docker container inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
  log "Vendor container '$CONTAINER_NAME' not found locally."
  exit 1
fi

docker export "$CONTAINER_NAME" -o "$TMP"

sz=$(stat -c '%s' "$TMP" 2>/dev/null || echo 0)
if (( sz < MIN_BYTES )); then
  log "Exported tar looks too small ($sz bytes); aborting."
  rm -f "$TMP"
  exit 1
fi

# Atomic move into the *current* worktree
mv -f "$TMP" "$DEST"
chmod 0644 "$DEST"
log "Rootfs ready at: $DEST ($sz bytes)"
