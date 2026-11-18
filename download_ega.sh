#!/usr/bin/env bash
# Batch download selected EGA Live Outbox datasets over SFTP.
# Usage:
#   bash download_ega.sh EGA_USERNAME /path/to/ssh_private_key /path/to/download_dir
# Or set EGA_USER, SSH_KEY, DOWNLOAD_DIR as environment variables.
# Example (EGA usernames are usually e-mail addresses):
#   bash download_ega.sh someone@example.org ~/.ssh/key/my.key /data/EGA
#
# Optional environment variables:
#   EGA_HOST, EGA_PORT        server (default outbox.ega-archive.org:22)
#   EGA_REMOTE_PREFIX         remote directory holding the EGAD folders; if
#                             unset it is auto-detected ("" or "outbox")
#   EGA_STRICT_HOSTKEY        StrictHostKeyChecking value (default accept-new,
#                             falls back to yes on OpenSSH < 7.6)
#   MAX_RETRIES, RETRY_DELAY  retry policy per dataset (default 5 x 30 s)
#   EGA_PROGRESS              auto (default) | meter | monitor | off
#                             meter: sftp's own per-file progress bar (terminal only)
#                             monitor: size + speed lines in the log (works with nohup)
#                             auto: meter on a terminal, monitor otherwise
#   PROGRESS_INTERVAL         seconds between monitor lines (default 60)

set -uo pipefail

EGA_USER="${1:-${EGA_USER:-}}"
SSH_KEY="${2:-${SSH_KEY:-$HOME/.ssh/id_ed25519}}"
DOWNLOAD_DIR="${3:-${DOWNLOAD_DIR:-$PWD/EGA_download}}"
EGA_HOST="${EGA_HOST:-outbox.ega-archive.org}"
EGA_PORT="${EGA_PORT:-22}"
MAX_RETRIES="${MAX_RETRIES:-5}"
RETRY_DELAY="${RETRY_DELAY:-30}"

DATASETS=(
  EGAD50000000334
  EGAD50000000335
  EGAD50000000336
  EGAD50000001179
)

die() { printf 'Error: %s\n' "$*" >&2; exit 2; }

if [[ -z "$EGA_USER" || "$EGA_USER" == "-h" || "$EGA_USER" == "--help" ]]; then
  echo "Usage: bash $0 EGA_USERNAME [SSH_PRIVATE_KEY] [DOWNLOAD_DIR]" >&2
  echo "Example: bash $0 someone@example.org ~/.ssh/key/my.key /data/EGA" >&2
  exit 2
fi

# EGA usernames are e-mail addresses, so "@" and "+" must be allowed.
[[ "$EGA_USER" != *[!a-zA-Z0-9._@+-]* ]] || die "EGA username contains unsupported characters: $EGA_USER"

# Expand a leading "~" in case the key path was passed in quotes.
case "$SSH_KEY" in
  "~") SSH_KEY="$HOME" ;;
  "~/"*) SSH_KEY="$HOME/${SSH_KEY#\~/}" ;;
esac
case "$DOWNLOAD_DIR" in
  "~/"*) DOWNLOAD_DIR="$HOME/${DOWNLOAD_DIR#\~/}" ;;
esac

for cmd in sftp ssh ssh-keygen ssh-add ssh-agent tee date mkdir du; do
  command -v "$cmd" >/dev/null 2>&1 || die "required command missing: $cmd"
done

[[ -f "$SSH_KEY" && -r "$SSH_KEY" ]] || die "SSH private key not found or unreadable: $SSH_KEY"
if [[ -n "$(find "$SSH_KEY" -maxdepth 0 -perm /077 2>/dev/null)" ]]; then
  die "SSH refuses private keys readable by others. Run: chmod 600 \"$SSH_KEY\""
fi

PROGRESS_INTERVAL="${PROGRESS_INTERVAL:-60}"
EGA_PROGRESS="${EGA_PROGRESS:-auto}"
if ! [[ "$EGA_PORT" =~ ^[0-9]+$ && "$MAX_RETRIES" =~ ^[1-9][0-9]*$ && "$RETRY_DELAY" =~ ^[0-9]+$ && "$PROGRESS_INTERVAL" =~ ^[1-9][0-9]*$ ]]; then
  die "invalid EGA_PORT, MAX_RETRIES, RETRY_DELAY or PROGRESS_INTERVAL."
fi
case "$EGA_PROGRESS" in
  auto) if [[ -t 1 ]]; then EGA_PROGRESS=meter; else EGA_PROGRESS=monitor; fi ;;
  meter) [[ -t 1 ]] || { echo "Note: no terminal, using EGA_PROGRESS=monitor instead of meter." >&2; EGA_PROGRESS=monitor; } ;;
  monitor | off) ;;
  *) die "EGA_PROGRESS must be auto, meter, monitor or off" ;;
esac

# Paths are embedded in sftp batch commands inside double quotes.
case "$DOWNLOAD_DIR${EGA_REMOTE_PREFIX:-}" in
  *'"'* | *$'\n'* | *'\'*) die 'download directory / remote prefix must not contain ", \ or newlines' ;;
esac

# StrictHostKeyChecking=accept-new (OpenSSH >= 7.6) still rejects a *changed*
# host key, but accepts the key on first connection.
if [[ -z "${EGA_STRICT_HOSTKEY:-}" ]]; then
  if ssh -G -o StrictHostKeyChecking=accept-new "$EGA_HOST" >/dev/null 2>&1; then
    EGA_STRICT_HOSTKEY=accept-new
  else
    EGA_STRICT_HOSTKEY=yes
    echo "Note: old OpenSSH; if this host is not in ~/.ssh/known_hosts yet, log in once manually first." >&2
  fi
fi

# BatchMode=yes disables passphrase prompts. For a passphrase-protected key,
# load it into ssh-agent once so that every retry can reuse it.
STARTED_AGENT=0
MON_PID=""
cleanup() {
  [[ -n "$MON_PID" ]] && kill "$MON_PID" 2>/dev/null
  ((STARTED_AGENT)) && ssh-agent -k >/dev/null 2>&1
  return 0
}
trap cleanup EXIT

if ! ssh-keygen -y -P '' -f "$SSH_KEY" >/dev/null 2>&1; then
  fp="$(ssh-keygen -lf "$SSH_KEY" 2>/dev/null | awk '{print $2}')"
  if [[ -n "$fp" ]] && ssh-add -l 2>/dev/null | awk '{print $2}' | grep -qxF -- "$fp"; then
    echo "Using passphrase-protected key already loaded in ssh-agent."
  else
    ( : </dev/tty ) 2>/dev/null || die "key is passphrase-protected and no terminal is available. Run: eval \"\$(ssh-agent -s)\"; ssh-add \"$SSH_KEY\" before starting this script."
    # ssh-add -l: 0 = agent has keys, 1 = agent empty, 2 = no agent reachable.
    agent_rc=0
    ssh-add -l >/dev/null 2>&1 || agent_rc=$?
    if ((agent_rc == 2)); then
      eval "$(ssh-agent -s)" >/dev/null || die "could not start ssh-agent"
      STARTED_AGENT=1
    fi
    echo "The key is passphrase-protected; enter it once (cached in ssh-agent for this run)."
    ssh-add "$SSH_KEY" </dev/tty || die "ssh-add failed (wrong passphrase?)"
  fi
fi

SFTP_OPTS=(
  -i "$SSH_KEY"
  -P "$EGA_PORT"
  -o User="$EGA_USER"
  -o BatchMode=yes
  -o IdentitiesOnly=yes
  -o StrictHostKeyChecking="$EGA_STRICT_HOSTKEY"
  -o ConnectTimeout=30
  -o ServerAliveInterval=30
  -o ServerAliveCountMax=6
)

mkdir -p "$DOWNLOAD_DIR" || exit 2
DOWNLOAD_DIR="$(cd "$DOWNLOAD_DIR" && pwd -P)" || exit 2
LOG_FILE="$DOWNLOAD_DIR/download_$(date +%Y%m%d_%H%M%S).log"
# Keep a handle on the real terminal: sftp only draws its progress bar when
# its stdout is a terminal, not the tee pipe used for logging.
exec 3>&1
exec > >(tee -a "$LOG_FILE") 2>&1

printf 'EGA download started: %s\nUser: %s\nHost: %s:%s\nLocal directory: %s\nLog: %s\n\n' \
  "$(date)" "$EGA_USER" "$EGA_HOST" "$EGA_PORT" "$DOWNLOAD_DIR" "$LOG_FILE"

# Login test + remote layout detection, before the long download loop.
list_remote() {  # list_remote <dir>  -> one name per line
  sftp "${SFTP_OPTS[@]}" -b - "$EGA_HOST" <<EOF | tr -d '\r' | { grep -v '^sftp>' || true; } | sed 's#.*/##'
ls -1 "$1"
EOF
}

echo "Checking login and remote layout..."
if ! top="$(list_remote .)"; then
  printf 'Error: SFTP login or listing failed. Check username, key, network and host key.\n' >&2
  printf 'Manual test: sftp -i "%s" -P %s "%s@%s"\n' "$SSH_KEY" "$EGA_PORT" "$EGA_USER" "$EGA_HOST" >&2
  exit 1
fi
printf 'Remote top level:\n%s\n\n' "$(printf '%s\n' "$top" | sed 's/^/  /' | head -n 50)"

if [[ -z "${EGA_REMOTE_PREFIX+x}" ]]; then
  EGA_REMOTE_PREFIX=""
  found_top=0
  for d in "${DATASETS[@]}"; do
    grep -qxF -- "$d" <<<"$top" && found_top=1
  done
  if ((found_top == 0)) && grep -qxF outbox <<<"$top"; then
    EGA_REMOTE_PREFIX="outbox"
  elif ((found_top == 0)); then
    echo "Warning: none of the datasets is visible at the top level; trying anyway (set EGA_REMOTE_PREFIX to override)."
  fi
fi
EGA_REMOTE_PREFIX="${EGA_REMOTE_PREFIX%/}"
printf 'Remote prefix: %s\n' "${EGA_REMOTE_PREFIX:-<home directory>}"
case "$EGA_PROGRESS" in
  meter) echo "Progress: sftp progress bar on the terminal (not written to the log)" ;;
  monitor) echo "Progress: size/speed line every ${PROGRESS_INTERVAL}s" ;;
  off) echo "Progress: off" ;;
esac

human() {  # bytes -> e.g. 1.5GiB
  numfmt --to=iec-i --suffix=B --format='%.1f' "$1" 2>/dev/null || printf '%sB' "$1"
}
dir_bytes() {
  local b
  b="$(du -sb -- "$1" 2>/dev/null | cut -f1)"
  printf '%s' "${b:-0}"
}
# Background reporter: downloaded size and average speed since the last line.
monitor() {  # monitor <dataset> <dir>
  local prev now prev_t now_t dt sp=""
  trap '[[ -n "$sp" ]] && kill "$sp" 2>/dev/null; exit 0' TERM
  prev="$(dir_bytes "$2")"; prev_t=$SECONDS
  while :; do
    sleep "$PROGRESS_INTERVAL" & sp=$!
    wait "$sp"; sp=""
    now="$(dir_bytes "$2")"; now_t=$SECONDS
    dt=$((now_t - prev_t)); ((dt > 0)) || dt=1
    printf '[%s] %s: %s downloaded, %s/s\n' "$(date '+%F %T')" "$1" \
      "$(human "$now")" "$(human $(((now - prev) / dt)))"
    prev=$now; prev_t=$now_t
  done
}

failures=()
for dataset in "${DATASETS[@]}"; do
  remote="${EGA_REMOTE_PREFIX:+$EGA_REMOTE_PREFIX/}$dataset"
  printf '\n========== %s ==========\n' "$dataset"
  success=0

  for ((attempt=1; attempt<=MAX_RETRIES; attempt++)); do
    printf '[%s] Attempt %d/%d: %s\n' "$(date)" "$attempt" "$MAX_RETRIES" "$remote"

    # -a: resume local partial files; -R: recursively download directories.
    # Batch mode aborts on the first SFTP error, so the exit code is reliable.
    batch="lcd \"$DOWNLOAD_DIR\""$'\n'"get -aR \"$remote\""$'\n'"bye"
    rc=0
    case "$EGA_PROGRESS" in
      meter)
        # -b turns the progress bar off; the "progress" command turns it back on.
        # stdout goes straight to the terminal; errors (stderr) still reach the log.
        sftp "${SFTP_OPTS[@]}" -b - "$EGA_HOST" <<<"progress"$'\n'"$batch" >&3 || rc=$?
        ;;
      monitor)
        monitor "$dataset" "$DOWNLOAD_DIR/$dataset" &
        MON_PID=$!
        sftp "${SFTP_OPTS[@]}" -b - "$EGA_HOST" <<<"$batch" || rc=$?
        kill "$MON_PID" 2>/dev/null; wait "$MON_PID" 2>/dev/null; MON_PID=""
        ;;
      off)
        sftp "${SFTP_OPTS[@]}" -b - "$EGA_HOST" <<<"$batch" || rc=$?
        ;;
    esac
    if ((rc == 0)); then
      printf '[%s] SFTP completed: %s (%s)\n' "$(date)" "$dataset" \
        "$(du -sh -- "$DOWNLOAD_DIR/$dataset" 2>/dev/null | cut -f1)"
      success=1
      break
    fi

    printf '[%s] SFTP failed: %s\n' "$(date)" "$dataset"
    if ((attempt < MAX_RETRIES)); then
      printf 'Retrying after %s seconds...\n' "$RETRY_DELAY"
      sleep "$RETRY_DELAY"
    fi
  done

  if ((success == 0)); then
    failures+=("$dataset")
  fi
done

printf '\n========== Summary ==========\n'
printf 'Finished: %s\n' "$(date)"
if ((${#failures[@]} > 0)); then
  printf 'Failed datasets (%d of %d):\n' "${#failures[@]}" "${#DATASETS[@]}"
  printf '  %s\n' "${failures[@]}"
  printf 'See log: %s\n' "$LOG_FILE"
  exit 1
fi
printf 'All %d datasets downloaded successfully.\n' "${#DATASETS[@]}"
printf 'Note: SFTP completion does not verify dataset checksums.\n'
printf 'Next step: bash decrypt_ega_c4gh.sh /path/to/key "%s"\n' "$DOWNLOAD_DIR"
printf 'See log: %s\n' "$LOG_FILE"
