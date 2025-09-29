#!/usr/bin/env bash
set -euo pipefail
export PATH="/usr/sbin:/sbin:$PATH"

log(){ echo "[$(date +%H:%M:%S)] $*"; }
die(){ echo "ERROR: $*" >&2; exit 1; }

# Usage: ./build-new-from-old.sh "<input .homeyprobackup|.img.gz|.img>"
[[ $# -ge 1 ]] || die "Usage: $0 <input>"
IN="/work/$1"
PLAYBOOK="/work/playbook.yaml"   # mandatory
[[ -e "$IN" ]]       || die "Input not found: $IN"
[[ -f "$PLAYBOOK" ]] || die "Missing required playbook at $PLAYBOOK"

# ---- deps ----
need=(parted losetup kpartx dmsetup partprobe mount umount blkid e2fsck resize2fs \
      mkfs.vfat mkfs.ext4 tar gzip python3 rsync)
miss=(); for b in "${need[@]}"; do command -v "$b" >/dev/null 2>&1 || miss+=("$b"); done
((${#miss[@]})) && die "Missing tools: ${miss[*]}"

# ---- temp workspace ----
TMPDIR="${TMPDIR:-/tmp}"
OLD_IMG="$(mktemp -p "$TMPDIR" homey-old.img.XXXXXX)"
NEW_IMG="$(mktemp -p "$TMPDIR" homey-new.img.XXXXXX)"
BOOT_TGZ="$(mktemp -p "$TMPDIR" boot.tgz.XXXXXX)"
ROOT_TGZ="$(mktemp -p "$TMPDIR" root.tgz.XXXXXX)"

# Keep globals for cleanup
OLD_LOOP=""; NEW_LOOP=""

cleanup(){
  set +e
  # chroot bind mounts (best-effort order)
  umount /mnt/new_root/boot 2>/dev/null || true
  umount /mnt/new_root/run 2>/dev/null || true
  umount /mnt/new_root/dev/pts 2>/dev/null || true
  umount /mnt/new_root/dev 2>/dev/null || true
  umount /mnt/new_root/sys 2>/dev/null || true
  umount /mnt/new_root/proc 2>/dev/null || true

  # regular mounts
  umount /mnt/new_root 2>/dev/null || true
  umount /mnt/new_boot 2>/dev/null || true
  umount /mnt/old_root 2>/dev/null || true
  umount /mnt/old_boot 2>/dev/null || true

  # remove dm maps
  if [[ -n "$OLD_LOOP" ]]; then kpartx -d "$OLD_LOOP" 2>/dev/null || true; fi
  if [[ -n "$NEW_LOOP" ]]; then kpartx -d "$NEW_LOOP" 2>/dev/null || true; fi

  # detach loops
  [[ -n "$OLD_LOOP" ]] && losetup -d "$OLD_LOOP" 2>/dev/null || true
  [[ -n "$NEW_LOOP" ]] && losetup -d "$NEW_LOOP" 2>/dev/null || true

  # remove temp tarballs; keep images on error for inspection
  rm -f "$BOOT_TGZ" "$ROOT_TGZ" 2>/dev/null || true
}
trap cleanup EXIT

[[ -e /dev/loop-control ]] || mknod /dev/loop-control c 10 237 || true

# ---- helpers ----
attach(){ losetup --show -f "$1"; }   # partitions via kpartx (not -P)
refresh_dm(){
  local loop="$1"
  kpartx -d "$loop" >/dev/null 2>&1 || true
  partprobe "$loop" >/dev/null 2>&1 || true
  kpartx -a -s "$loop" >/dev/null 2>&1 || true
  command -v udevadm >/dev/null 2>&1 && udevadm settle || sleep 0.5
}
wait_for(){
  local dev="$1" tries=200
  while ((tries--)); do [[ -e "$dev" ]] && return 0; sleep 0.05; done
  return 1
}

# ---- normalize input → OLD_IMG (raw) ----
case "$IN" in
  *.homeyprobackup)
    log "Extracting raw IMG from .homeyprobackup → $OLD_IMG"
    python3 - "$IN" "$OLD_IMG" <<'PY'
import sys, gzip, shutil
src, dst = sys.argv[1], sys.argv[2]
with open(src,'rb') as f:
  hdr=f.read(1024)
  if not hdr.startswith(b'HYBAK0'):
    raise SystemExit("Invalid backup: missing HYBAK0 header")
with open(src,'rb') as f:
  f.seek(1024)
  with gzip.GzipFile(fileobj=f) as gz, open(dst,'wb') as o:
    shutil.copyfileobj(gz,o)
print("IMG written:", dst)
PY
    ;;
  *.img.gz)
    log "Decompressing .img.gz → $OLD_IMG"
    gunzip -c -- "$IN" > "$OLD_IMG"
    ;;
  *.img)
    log "Copying IMG → $OLD_IMG"
    cp -f -- "$IN" "$OLD_IMG"
    ;;
  *)
    die "Unsupported input type: $IN"
    ;;
esac

# ---- size & create NEW image ----
OLD_SIZE="$(stat -c '%s' "$OLD_IMG")"
if [[ -n "${TARGET_SIZE_GB:-}" ]]; then
  NEW_SIZE=$(( TARGET_SIZE_GB * 1024 * 1024 * 1024 ))
  (( NEW_SIZE > 700*1024*1024 )) || die "TARGET_SIZE_GB too small"
else
  NEW_SIZE="$OLD_SIZE"
fi
truncate -s "$NEW_SIZE" "$NEW_IMG"

# ---- attach OLD and detect partitions via device-mapper ----
OLD_LOOP="$(attach "$OLD_IMG")"; OLD_BASE="$(basename "$OLD_LOOP")"
refresh_dm "$OLD_LOOP"

OLD_P5="/dev/mapper/${OLD_BASE}p5"  # typical /boot
OLD_P6="/dev/mapper/${OLD_BASE}p6"  # typical /
wait_for "$OLD_P5" || OLD_P5=""
wait_for "$OLD_P6" || OLD_P6=""

# if not standard, auto-pick: smallest FAT = boot, largest ext* = root
if [[ -z "$OLD_P5" || -z "$OLD_P6" ]]; then
  mapfile -t MPS < <(lsblk -nrpo NAME,TYPE "/dev/mapper" | awk -v b="$OLD_BASE" '$2=="part" && $1 ~ (b "p[0-9]+$"){print $1}')
  declare -A T S
  for p in "${MPS[@]}"; do
    T["$p"]="$(blkid -s TYPE -o value "$p" 2>/dev/null || true)"
    S["$p"]="$(blockdev --getsize64 "$p" 2>/dev/null || echo 0)"
  done
  if [[ -z "$OLD_P5" ]]; then
    SMALLEST=""
    for p in "${MPS[@]}"; do
      [[ "${T[$p]}" =~ ^(vfat|fat|fat16|fat32)$ ]] || continue
      if [[ -z "$SMALLEST" || ${S[$p]} -lt ${S[$SMALLEST]} ]]; then SMALLEST="$p"; fi
    done
    OLD_P5="$SMALLEST"
  fi
  if [[ -z "$OLD_P6" ]]; then
    LARGEST=""
    for p in "${MPS[@]}"; do
      [[ "${T[$p]}" =~ ^ext[234]$ ]] || continue
      if [[ -z "$LARGEST" || ${S[$p]} -gt ${S[$LARGEST]} ]]; then LARGEST="$p"; fi
    done
    OLD_P6="$LARGEST"
  fi
fi

[[ -n "$OLD_P5" && -n "$OLD_P6" ]] || die "Could not identify OLD /boot or /"

log "OLD /boot: $OLD_P5"
log "OLD /   : $OLD_P6"

mkdir -p /mnt/old_boot /mnt/old_root
mount -o ro -t vfat "$OLD_P5" /mnt/old_boot
mount -o ro        "$OLD_P6" /mnt/old_root

# ---- snapshot OLD to tarballs (xattrs preserved) ----
log "Snapshotting old /boot and / to tarballs"
tar --xattrs --xattrs-include='*' -C /mnt/old_boot -czf "$BOOT_TGZ" .
tar --xattrs --xattrs-include='*' -C /mnt/old_root -czf "$ROOT_TGZ" \
  --exclude='./autoboot/*' \
  --exclude='./boot/*' \
  --exclude='./proc/*' --exclude='./sys/*' --exclude='./dev/*' \
  --exclude='./run/*'  --exclude='./tmp/*' --exclude='./mnt/*' \
  --exclude='./media/*' --exclude='./lost+found' \
  .

umount /mnt/old_root /mnt/old_boot || true

# ---- build NEW image (msdos: p1 FAT32 /boot, p2 ext4 /) ----
NEW_LOOP="$(attach "$NEW_IMG")"; NEW_BASE="$(basename "$NEW_LOOP")"
# Zero the first few MiB of the IMAGE FILE to clear any stale sigs
dd if=/dev/zero of="$NEW_IMG" bs=1M count=4 conv=notrunc status=none || true

parted -s "$NEW_LOOP" mklabel msdos
parted -s "$NEW_LOOP" mkpart primary fat32 1MiB 290MiB
parted -s "$NEW_LOOP" mkpart primary ext4  290MiB 100%
parted -s "$NEW_LOOP" set 1 lba on || true
parted -s "$NEW_LOOP" set 1 boot on || true

refresh_dm "$NEW_LOOP"

NEW_P1="/dev/mapper/${NEW_BASE}p1"
NEW_P2="/dev/mapper/${NEW_BASE}p2"
wait_for "$NEW_P1" || die "Missing mapper $NEW_P1"
wait_for "$NEW_P2" || die "Missing mapper $NEW_P2"

log "Formatting new filesystems"
mkfs.vfat -F32 -n BOOT  "$NEW_P1"
mkfs.ext4 -L rootfs -O ^metadata_csum_seed,^orphan_file "$NEW_P2"

mkdir -p /mnt/new_boot /mnt/new_root
mount -t vfat "$NEW_P1" /mnt/new_boot
mount        "$NEW_P2" /mnt/new_root

# ---- restore tarballs to NEW ----
log "Restoring /boot → new p1"
tar -xzf "$BOOT_TGZ" -C /mnt/new_boot
rm -f /mnt/new_boot/tryboot.txt 2>/dev/null || true

log "Restoring / → new p2"
tar -xzf "$ROOT_TGZ" -C /mnt/new_root

# ---- fix boot config on NEW ----
ROOT_PARTUUID="$(blkid -s PARTUUID -o value "$NEW_P2")"
if [[ -f /mnt/new_boot/cmdline.txt ]]; then
  if grep -qE '(^| )root=[^ ]+' /mnt/new_boot/cmdline.txt; then
    sed -i -E "s#(^| )root=[^ ]+#\\1root=PARTUUID=${ROOT_PARTUUID}#g" /mnt/new_boot/cmdline.txt
  else
    sed -i -E "1s|^|root=PARTUUID=${ROOT_PARTUUID} |" /mnt/new_boot/cmdline.txt
  fi
  grep -qw rootwait /mnt/new_boot/cmdline.txt || sed -i 's#$# rootwait#' /mnt/new_boot/cmdline.txt
else
  echo "root=PARTUUID=${ROOT_PARTUUID} rootfstype=ext4 rootwait fsck.repair=preen" > /mnt/new_boot/cmdline.txt
fi

grep -q 'modules-load=dwc2,g_serial' /mnt/new_boot/cmdline.txt || \
  sed -i 's/rootwait/& modules-load=dwc2,g_serial/' /mnt/new_boot/cmdline.txt
grep -q 'console=ttyGS0,115200' /mnt/new_boot/cmdline.txt || \
  sed -i 's#$# console=ttyGS0,115200#' /mnt/new_boot/cmdline.txt

# ensure 64-bit & keep your dwc2 peripheral overlay if you use USB gadget
grep -q '^arm_64bit=' /mnt/new_boot/config.txt 2>/dev/null || echo 'arm_64bit=1' >> /mnt/new_boot/config.txt
if grep -qE '^dtoverlay=dwc2' /mnt/new_boot/config.txt 2>/dev/null; then
  sed -i -E 's/^dtoverlay=dwc2.*/dtoverlay=dwc2,dr_mode=peripheral/' /mnt/new_boot/config.txt
fi

# fstab: ensure /boot and drop /user
if [[ -f /mnt/new_root/etc/fstab ]]; then
  sed -i -E '/[[:space:]]\/user[[:space:]]/d' /mnt/new_root/etc/fstab
  grep -qE '^[^#].*[[:space:]]/boot[[:space:]]vfat' /mnt/new_root/etc/fstab || \
    echo 'LABEL=BOOT /boot vfat defaults,utf8,fsync 0 2' >> /mnt/new_root/etc/fstab
fi
sync

# ---- run Ansible in chroot on NEW root (mandatory) ----
log "Running Ansible in chroot: $PLAYBOOK"
mount --bind /mnt/new_boot /mnt/new_root/boot
mount -t proc  proc  /mnt/new_root/proc
mount -t sysfs sysfs /mnt/new_root/sys
mount --rbind /dev   /mnt/new_root/dev;  mount --make-rslave /mnt/new_root/dev
mount --rbind /run   /mnt/new_root/run;  mount --make-rslave /mnt/new_root/run
# DNS for apt/etc
if ! mountpoint -q /mnt/new_root/etc/resolv.conf; then
  [[ -L /mnt/new_root/etc/resolv.conf ]] && umount /mnt/new_root/etc/resolv.conf 2>/dev/null || true
  mkdir -p /mnt/new_root/etc
  mount --bind /etc/resolv.conf /mnt/new_root/etc/resolv.conf
fi

INV="/tmp/inventory.ini"
cat > "$INV" <<EOF
[image]
img ansible_connection=community.general.chroot ansible_host=/mnt/new_root ansible_python_interpreter=/usr/bin/python3
EOF

ansible-playbook -i "$INV" "$PLAYBOOK"

# ---- tidy chroot & unmount depth-first ----
log "Tearing down chroot/binds from /mnt/new_root (depth-first)"

# First try to stop any lingering processes rooted in the chroot (best-effort)
# (not fatal if tools are absent)
command -v fuser >/dev/null 2>&1 && fuser -km /mnt/new_root 2>/dev/null || true

# Enumerate all mountpoints under /mnt/new_root (deepest first)
if command -v findmnt >/dev/null 2>&1; then
  mapfile -t MPS < <(findmnt -Rno TARGET /mnt/new_root | sort -r)
else
  # Fallback: parse /proc/self/mountinfo
  mapfile -t MPS < <(awk '$5 ~ "^/mnt/new_root(/|$)" {print $5}' /proc/self/mountinfo | sort -r)
fi

# Ensure /mnt/new_root/etc/resolv.conf is included if mounted
mountpoint -q /mnt/new_root/etc/resolv.conf && MPS+=("/mnt/new_root/etc/resolv.conf")

for m in "${MPS[@]}"; do
  umount "$m" 2>/dev/null || true
done

# Anything stubborn? try lazy umount, deepest first
for m in "${MPS[@]}"; do
  mountpoint -q "$m" && umount -l "$m" 2>/dev/null || true
done

# Finally unmount the two top-level mounts if they’re still mounted
mountpoint -q /mnt/new_root    && umount /mnt/new_root    2>/dev/null || true
mountpoint -q /mnt/new_boot    && umount /mnt/new_boot    2>/dev/null || true

sync

# Safety check
if grep -q '^/mnt/new_root' /proc/self/mounts; then
  log "Warning: something under /mnt/new_root is still mounted:"
  grep '^/mnt/new_root' /proc/self/mounts || true
  log "Proceeding with lazy detach as last resort."
  # Lazy detach the root mount if it still shows
  mountpoint -q /mnt/new_root && umount -l /mnt/new_root 2>/dev/null || true
fi

# ---- fsck & final resize (now unmounted) ----
log "Final e2fsck/resize2fs on NEW root"
e2fsck -pf "$NEW_P2" || true
resize2fs "$NEW_P2" || true
sync

# ---- pack NEW image back to .homeyprobackup (keep HYBAK0 header) ----
out_dir="$(dirname "$IN")"; in_base="$(basename "$IN")"
pack_base="${in_base/Pro/Assistant}"
case "$pack_base" in
  *.homeyprobackup) pack="${pack_base%.homeyprobackup}.homeyprobackup" ;;
  *.img.gz)         pack="${pack_base%.img.gz}.homeyprobackup" ;;
  *.img)            pack="${pack_base%.img}.homeyprobackup" ;;
  *)                pack="${pack_base}.homeyprobackup" ;;
esac
PACK_OUT="${out_dir}/${pack}"

log "Packing NEW IMG → $PACK_OUT"
python3 - "$IN" "$NEW_IMG" "$PACK_OUT" <<'PY'
import sys,gzip,shutil,os
src_in,img,dst=sys.argv[1],sys.argv[2],sys.argv[3]
hdr=None
try:
  with open(src_in,'rb') as f:
    h=f.read(1024)
    if len(h)==1024 and h.startswith(b'HYBAK0'):
      hdr=h
except Exception:
  hdr=None
if hdr is None:
  hdr=b'HYBAK0'+b'\x00'*(1024-6)
os.makedirs(os.path.dirname(dst) or ".",exist_ok=True)
with open(dst,'wb') as o:
  o.write(hdr)
  with open(img,'rb') as f, gzip.GzipFile(fileobj=o,mode='wb',compresslevel=9,mtime=0) as gz:
    shutil.copyfileobj(f,gz)
PY

# success → remove raw images
rm -f "$OLD_IMG" "$NEW_IMG"
log "Done: $PACK_OUT"
