#!/bin/bash
# Prepare this checkout as the GPU queue for this host. Idempotent; run as root:
#   sudo ./setup.sh                    create/fix gpuN/ folders from nvidia-smi
#   sudo ./setup.sh --install-pointers also point agents/humans at AGENTS.md
#                                      (/etc/claude-code/CLAUDE.md, /etc/motd, /usr/local/bin/gpuq)
set -euo pipefail
umask 022

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
INSTALL_POINTERS=0
for arg in "$@"; do
  case "$arg" in
    --install-pointers) INSTALL_POINTERS=1 ;;
    -h|--help) sed -n '2,6p' "$0"; exit 0 ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

[[ $EUID -eq 0 ]] || { echo "run as root: sudo $0 $*" >&2; exit 1; }
for c in nvidia-smi setfacl stat mktemp; do
  command -v "$c" >/dev/null || { echo "missing command: $c" >&2; exit 1; }
done

# Top level: world rwx + sticky bit (only a file's owner can delete or rename it).
[[ "$(stat -c %U "$ROOT")" == root ]] || \
  echo "warning: $ROOT is owned by $(stat -c %U "$ROOT"), not root. The owner of a sticky folder can delete anything in it." >&2
chmod 1777 "$ROOT"

# Tracked files and .git must not be writable by others.
chmod -R go-w "$ROOT/.git" "$ROOT/bin" "$ROOT/docs" "$ROOT/hosts" "$ROOT/etc" "$ROOT/tests" 2>/dev/null || true
for f in AGENTS.md README.md LICENSE setup.sh .gitignore; do
  if [[ -e "$ROOT/$f" ]]; then chmod go-w "$ROOT/$f"; fi
done

GPUS="$(nvidia-smi --query-gpu=index,uuid,name,pci.bus_id,memory.total --format=csv,noheader,nounits)"
[[ -n "$GPUS" ]] || { echo "nvidia-smi listed no GPUs" >&2; exit 1; }

seen=()
while IFS=, read -r idx uuid name bus mem; do
  idx="${idx// /}"; uuid="${uuid// /}"; bus="${bus// /}"; mem="${mem// /}"
  name="$(echo "$name" | sed 's/^ *//;s/ *$//')"
  [[ "$idx" =~ ^[0-9]+$ ]] || continue
  d="$ROOT/gpu$idx"
  seen+=("gpu$idx")
  # The top folder is world-writable, so anyone could have pre-created gpuN (or a symlink
  # named gpuN) to trick root into chmod-ing something else. Only accept a real root-owned dir.
  if [[ -L "$d" ]]; then
    echo "error: $d is a symlink; remove it and rerun" >&2; exit 1
  elif [[ ! -e "$d" ]]; then
    mkdir "$d"
  elif [[ ! -d "$d" || "$(stat -c %u "$d")" != 0 ]]; then
    echo "error: $d exists but is not a root-owned directory (owner: $(stat -c %U "$d")). Inspect it, remove it, rerun." >&2
    exit 1
  fi
  chown root:root "$d"
  chmod 1777 "$d"
  # Default ACL: new lock files get rw for everyone regardless of the creator's umask,
  # so other users can append pings.
  setfacl -m d:u::rwx,d:g::rwx,d:o::rwx "$d"

  tmp="$(mktemp "$d/.gpu-info.XXXXXX")"
  printf 'index: %s\nuuid: %s\nname: %s\npci_bus_id: %s\nmemory_total_mib: %s\nhost: %s\n' \
    "$idx" "$uuid" "$name" "$bus" "$mem" "$(hostname -s)" > "$tmp"
  chmod 644 "$tmp"
  setfacl -b "$tmp"
  mv -fT "$tmp" "$d/.gpu-info"

  # Mutex used by gpuq for join/claim. Replace it only if someone else planted it.
  m="$d/.mutex"
  if [[ -L "$m" || ( -e "$m" && ( ! -f "$m" || "$(stat -c %u "$m")" != 0 ) ) ]]; then
    rm -rf -- "$m"
  fi
  if [[ ! -e "$m" ]]; then
    tmp="$(mktemp "$d/.mutex.XXXXXX")"
    chmod 644 "$tmp"; setfacl -b "$tmp"
    mv -nT "$tmp" "$m" || rm -f "$tmp"
  fi
  echo "gpu$idx  $uuid  $name  ok"
done <<< "$GPUS"

for d in "$ROOT"/gpu*; do
  [[ -d "$d" ]] || continue
  b="$(basename "$d")"
  [[ " ${seen[*]} " == *" $b "* ]] || echo "warning: $d has no matching GPU on this host (left untouched)" >&2
done

host="$(hostname -s)"
[[ -f "$ROOT/hosts/$host.json" ]] || \
  echo "note: no $ROOT/hosts/$host.json yet; copy hosts/example.json and fill in the assigned users" >&2

if [[ $INSTALL_POINTERS -eq 1 ]]; then
  mkdir -p /etc/claude-code
  f=/etc/claude-code/CLAUDE.md
  if ! grep -q 'gpushare:begin' "$f" 2>/dev/null; then
    if [[ -s "$f" ]]; then echo >> "$f"; fi
    sed "s#/srv/gpushare#$ROOT#g" "$ROOT/etc/claude-code-CLAUDE.md" >> "$f"
    chmod 644 "$f"
    echo "added pointer to $f"
  fi
  if ! grep -q 'gpushare' /etc/motd 2>/dev/null; then
    sed "s#/srv/gpushare#$ROOT#g" "$ROOT/etc/motd.snippet" >> /etc/motd
    echo "added line to /etc/motd"
  fi
  ln -sfn "$ROOT/bin/gpuq" /usr/local/bin/gpuq
  echo "linked /usr/local/bin/gpuq"
fi
echo "done: $ROOT"
