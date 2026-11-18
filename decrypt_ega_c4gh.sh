#!/usr/bin/env bash
# EGA Live Outbox Crypt4GH batch decryption for Linux.
# Usage: bash decrypt_ega_c4gh.sh [data_directory] [md5_list]
# The private key is chosen from ~/.ssh/key/ (put your key there first).
# The data_directory defaults to the current directory; search is recursive.
# Requires bash >= 4.0 (works on CentOS/RHEL 7's bash 4.2).
set -Eeuo pipefail
trap 'printf "ERROR: unexpected failure at line %s: %s\n" "$LINENO" "$BASH_COMMAND" >&2' ERR

KEY_DIR="${EGA_KEY_DIR:-$HOME/.ssh/key}"
KEY="${EGA_KEY:-}"
# Backward compatible: a key file given as the first argument is still accepted.
if [[ $# -ge 1 && -f "$1" ]]; then
  KEY="$1"
  shift
fi
DATA_DIR="${1:-.}"
MD5_LIST="${2:-}"
VENV_DIR="${EGA_C4GH_VENV:-$HOME/.local/share/ega-crypt4gh-venv}"
C4GH_SPEC="${EGA_C4GH_SPEC:-crypt4gh>=1.6,<2}"
# 077 => decrypted files are readable only by you (0600). Use EGA_UMASK=027 to
# let your group read them in a shared project directory.
umask "${EGA_UMASK:-077}"

say() { printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  cat <<'USAGE'
Usage: bash decrypt_ega_c4gh.sh [data_directory] [md5_list]
  Private key     Put your Crypt4GH / ssh-ed25519 private key into ~/.ssh/key/
                  (mkdir -p ~/.ssh/key; cp id_ed25519 ~/.ssh/key/; chmod 600 ...).
                  The keys found there are listed and you choose one; a single
                  key is used automatically. *.pub files are ignored.
  data_directory  Defaults to the current directory; searched recursively.
                  If its .c4gh files are spread over several sub-folders, the
                  folders are listed (files, size, how many still to decrypt)
                  and you choose: 3 | 1-5 | 1,3,7 | 1-3,8,10-12 | all.
  md5_list        Optional md5sum-style list ("<md5>  <name>") of the DECRYPTED
                  files. Entries are matched by path relative to data_directory
                  first, then by file name (unless that name is listed with
                  different checksums). Matching files are verified before being
                  kept, and already existing outputs are verified too; a mismatch
                  counts as a failure. Files without a usable entry are reported
                  as unverified.
  Original .c4gh files are retained; existing decrypted files are not overwritten.
  Uses a dedicated Python virtual environment; does not change system Python.

Environment variables:
  EGA_KEY          Key to use without asking (a file name in the key directory,
                   or a path); needed for non-interactive runs with several keys.
  EGA_KEY_DIR      Key directory (default ~/.ssh/key).
  EGA_SELECT       Folder selection without asking, e.g. "1-3,7" or "all".
                   Without a terminal and without EGA_SELECT, all are decrypted.
  C4GH_PASSPHRASE  Key passphrase (for non-interactive / nohup runs). If unset
                   and the key is encrypted, you are prompted once.
  EGA_UMASK        umask for decrypted files (default 077 => mode 0600).
  EGA_C4GH_VENV    venv location (default ~/.local/share/ega-crypt4gh-venv).
  EGA_C4GH_SPEC    pip requirement for crypt4gh (default "crypt4gh>=1.6,<2").
USAGE
  exit 0
fi
(($# <= 2)) || die "Too many arguments; see: bash $0 --help"

((BASH_VERSINFO[0] >= 4)) || die "bash >= 4.0 is required (found $BASH_VERSION)"

have_tty() { ( : </dev/tty ) 2>/dev/null; }

# A private key file starts with "-----BEGIN ... PRIVATE KEY-----"
# (OpenSSH, Crypt4GH and PEM formats all do).
is_private_key() {
  local first
  first="$(head -n 1 -- "$1" 2>/dev/null)" || return 1
  [[ "$first" == *"PRIVATE KEY"* ]]
}

key_help() {
  cat >&2 <<EOF

No private key found in: $KEY_DIR
Put your EGA private key (Crypt4GH or ssh-ed25519) there, for example:
  mkdir -p "$KEY_DIR" && chmod 700 "$KEY_DIR"
  cp /path/to/id_ed25519 "$KEY_DIR/"
  chmod 600 "$KEY_DIR/id_ed25519"
Public keys (*.pub) and hidden files are ignored.

EOF
}

# Fill KEYS with the private keys in KEY_DIR, sorted by name.
scan_keys() {
  local f n_other=0
  KEYS=()
  while IFS= read -r -d '' f; do
    if is_private_key "$f"; then
      KEYS+=("$f")
    else
      n_other=$((n_other + 1))
    fi
  done < <(find -L "$KEY_DIR" -mindepth 1 -maxdepth 1 -type f ! -name '.*' ! -name '*.pub' -print0 2>/dev/null | sort -z)
  if ((n_other > 0)); then
    say "Ignored $n_other file(s) in $KEY_DIR that are not private keys"
  fi
  return 0
}

# Set KEY: from EGA_KEY / the first argument, otherwise by choosing from KEY_DIR.
choose_key() {
  local ans i
  if [[ -n "$KEY" ]]; then
    if [[ "$KEY" != */* && ! -e "$KEY" && -f "$KEY_DIR/$KEY" ]]; then
      KEY="$KEY_DIR/$KEY"
    fi
    return 0
  fi
  if [[ ! -d "$KEY_DIR" ]]; then
    mkdir -p -m 700 -- "$KEY_DIR" || die "Cannot create key directory: $KEY_DIR"
    say "Created key directory: $KEY_DIR"
  fi
  if [[ -n "$(find -L "$KEY_DIR" -maxdepth 0 -perm /077 2>/dev/null)" ]]; then
    say "WARNING: key directory is accessible by other users; consider: chmod 700 \"$KEY_DIR\""
  fi
  while :; do
    scan_keys
    if ((${#KEYS[@]} == 1)); then
      KEY="${KEYS[0]}"
      say "Using the only private key in $KEY_DIR: ${KEY##*/}"
      return 0
    fi
    if ((${#KEYS[@]} == 0)); then
      key_help
      have_tty || die "No private key in $KEY_DIR (copy your key there and run again)"
      read -r -p "Press Enter after copying the key to search again, or q to quit: " ans </dev/tty \
        || die "Could not read your answer"
      if [[ "$ans" == [qQ]* ]]; then
        die "No private key selected"
      fi
      continue
    fi
    have_tty || die "Several private keys in $KEY_DIR; choose one with EGA_KEY=<file name>"
    printf '\nPrivate keys in %s:\n' "$KEY_DIR" >&2
    for i in "${!KEYS[@]}"; do
      printf '  %d) %s\n' "$((i + 1))" "${KEYS[i]##*/}" >&2
    done
    printf '(To add a key, copy it into %s and enter r.)\n' "$KEY_DIR" >&2
    while :; do
      read -r -p "Select a key [1-${#KEYS[@]}], r to rescan, q to quit: " ans </dev/tty \
        || die "Could not read your selection"
      case "$ans" in
        q|Q) die "No private key selected" ;;
        r|R) continue 2 ;;
      esac
      if [[ "$ans" =~ ^[0-9]+$ ]] && ((10#$ans >= 1 && 10#$ans <= ${#KEYS[@]})); then
        KEY="${KEYS[10#$ans - 1]}"
        say "Selected private key: ${KEY##*/}"
        return 0
      fi
      printf 'Invalid choice: %s\n' "$ans" >&2
    done
  done
}

choose_key
[[ -f "$KEY" && -r "$KEY" ]] || die "Private key missing or unreadable: $KEY"
[[ -d "$DATA_DIR" ]] || die "Data directory does not exist: $DATA_DIR"
[[ -z "$MD5_LIST" || -r "$MD5_LIST" ]] || die "MD5 list missing or unreadable: $MD5_LIST"
# Absolute paths, so names starting with "-" are never parsed as options.
KEY="$(cd -- "$(dirname -- "$KEY")" && pwd -P)/$(basename -- "$KEY")"
DATA_DIR="$(cd -- "$DATA_DIR" && pwd -P)"

# -L checks the key file itself; a symlink's own mode is always 0777.
if [[ -n "$(find -L "$KEY" -maxdepth 0 -perm /077 2>/dev/null)" ]]; then
  say "WARNING: private key is accessible by other users; consider: chmod 600 \"$KEY\""
fi

# Install minimal Linux distribution packages, only when needed.
install_packages() {
  local sudo_cmd=""   # a plain string avoids empty-array + set -u errors on bash < 4.4
  if [[ "$(id -u)" -ne 0 ]]; then
    command -v sudo >/dev/null 2>&1 || die "sudo not found. Ask an administrator to install python3 and python3-venv."
    sudo_cmd="sudo"
  fi
  if command -v apt-get >/dev/null 2>&1; then
    say "Installing dependencies with apt-get (sudo may request your password)..."
    $sudo_cmd apt-get update
    $sudo_cmd apt-get install -y python3 python3-venv python3-pip
  elif command -v dnf >/dev/null 2>&1; then
    say "Installing dependencies with dnf (sudo may request your password)..."
    $sudo_cmd dnf install -y python3 python3-pip
  elif command -v yum >/dev/null 2>&1; then
    say "Installing dependencies with yum (sudo may request your password)..."
    $sudo_cmd yum install -y python3 python3-pip
  else
    die "Unsupported package manager. Install python3, python3-venv and pip manually."
  fi
}

command -v python3 >/dev/null 2>&1 || install_packages
command -v python3 >/dev/null 2>&1 || die "python3 installation failed"

# Create an isolated installation rather than using pip on system Python.
C4GH="$VENV_DIR/bin/crypt4gh"
VENV_PY="$VENV_DIR/bin/python"
c4gh_works() { [[ -x "$C4GH" ]] && "$C4GH" -h >/dev/null 2>&1; }
if ! c4gh_works; then
  if [[ -e "$C4GH" || -e "$VENV_PY" ]]; then
    say "Existing Crypt4GH environment does not work (e.g. system Python changed); rebuilding it"
  fi
  # Refuse to --clear a directory that is not a virtual environment.
  if [[ -d "$VENV_DIR" && -n "$(ls -A -- "$VENV_DIR")" && ! -f "$VENV_DIR/pyvenv.cfg" ]]; then
    die "$VENV_DIR exists and is not a Python venv; set EGA_C4GH_VENV to another path"
  fi
  say "Setting up isolated Crypt4GH environment: $VENV_DIR"
  if ! python3 -m venv --clear "$VENV_DIR"; then
    say "Python venv failed; trying to install system venv dependencies..."
    install_packages
    python3 -m venv --clear "$VENV_DIR" || die "venv creation failed; Python version / OS may not be supported"
  fi
  "$VENV_PY" -m pip install --upgrade pip || die "pip upgrade failed (check connectivity)"
  "$VENV_PY" -m pip install "$C4GH_SPEC" || die "crypt4gh installation failed (check connectivity)"
fi
c4gh_works || die "crypt4gh executable is not functioning: $C4GH (try removing $VENV_DIR)"
say "Crypt4GH ready: $C4GH"

# Validate the key with crypt4gh itself. The passphrase is passed only through
# the environment (never on a command line, where `ps` could show it).
# Exit codes: 0 = OK, 3 = passphrase needed, 4 = unusable key / wrong passphrase.
validate_key() {
  "$VENV_PY" -I - "$KEY" <<'PY'
import os, sys
from crypt4gh.keys import get_private_key

asked = []

def callback():
    # crypt4gh wraps exceptions raised here, so record the request in a flag.
    asked.append(True)
    pw = os.environ.get("C4GH_PASSPHRASE")
    if not pw:
        raise ValueError("passphrase required")
    return pw

try:
    sk = get_private_key(sys.argv[1], callback)
except (Exception, SystemExit) as e:  # crypt4gh may call sys.exit() on errors
    if asked and not os.environ.get("C4GH_PASSPHRASE"):
        sys.exit(3)
    print("%s: %s" % (type(e).__name__, e), file=sys.stderr)
    sys.exit(4)
if not isinstance(sk, (bytes, bytearray)) or len(sk) != 32:
    print("Unexpected key material (not an Ed25519 / Crypt4GH key)", file=sys.stderr)
    sys.exit(4)
PY
}

say "Validating private key..."
rc=0
validate_key || rc=$?
if ((rc == 3)); then
  ( : </dev/tty ) 2>/dev/null || die "Key is passphrase-protected; set C4GH_PASSPHRASE for non-interactive runs"
  read -rs -p "Private key passphrase: " C4GH_PASSPHRASE </dev/tty || die "Could not read passphrase"
  printf '\n' >&2
  export C4GH_PASSPHRASE
  rc=0
  validate_key || rc=$?
fi
((rc == 0)) || die "Cannot use the private key. Check passphrase and that it is an Ed25519 (ssh-ed25519 or Crypt4GH) key."
say "Private key successfully parsed"

# Optional checksum list of the decrypted files.
#   MD5_BY_PATH  name exactly as listed (leading "./" removed)
#   MD5_BY_NAME  file name only
#   MD5_DUP_NAME file names listed with different checksums (matched by path only)
declare -A MD5_BY_PATH=() MD5_BY_NAME=() MD5_DUP_NAME=()
if [[ -n "$MD5_LIST" ]]; then
  command -v md5sum >/dev/null 2>&1 || die "md5sum not found (needed for the md5 list)"
  bs='\'
  re_line='^(\\?)([0-9a-fA-F]{32})[[:space:]]+\*?(.+)$'
  re_hash_only='^[[:space:]]*[0-9a-fA-F]{32}[[:space:]]*$'
  n_loaded=0
  n_ignored=0
  n_hash_only=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    if [[ -z "${line//[[:space:]]/}" || "$line" == '#'* ]]; then
      continue
    fi
    if [[ "$line" =~ $re_hash_only ]]; then
      n_hash_only=$((n_hash_only + 1))
      continue
    fi
    if ! [[ "$line" =~ $re_line ]]; then
      n_ignored=$((n_ignored + 1))
      continue
    fi
    hash="${BASH_REMATCH[2],,}"
    name="${BASH_REMATCH[3]}"
    if [[ -n "${BASH_REMATCH[1]}" ]]; then
      # md5sum writes "\<md5>  name" with \\ and \n escapes for unusual names.
      name="${name//"$bs$bs"/$'\x01'}"
      name="${name//"${bs}n"/$'\n'}"
      name="${name//$'\x01'/$bs}"
    fi
    if [[ "$name" == "$DATA_DIR/"* ]]; then
      name="${name#"$DATA_DIR/"}"
    fi
    name="${name#./}"
    base="${name##*/}"
    if [[ -z "$base" ]]; then
      n_ignored=$((n_ignored + 1))
      continue
    fi
    MD5_BY_PATH["$name"]="$hash"
    if [[ -n "${MD5_BY_NAME[$base]:-}" && "${MD5_BY_NAME[$base]}" != "$hash" ]]; then
      MD5_DUP_NAME["$base"]=1
    fi
    MD5_BY_NAME["$base"]="$hash"
    n_loaded=$((n_loaded + 1))
  done < "$MD5_LIST"
  ((n_loaded > 0)) || die "No usable \"<md5>  <name>\" lines in md5 list: $MD5_LIST"
  say "Loaded $n_loaded checksum(s) from: $MD5_LIST"
  if ((n_hash_only > 0)); then
    say "WARNING: $n_hash_only line(s) contain only a checksum without a file name and were ignored; combine per-file .md5 files as \"<md5>  <name>\""
  fi
  if ((n_ignored > 0)); then
    say "WARNING: $n_ignored line(s) in the md5 list were not understood and were ignored"
  fi
  if ((${#MD5_DUP_NAME[@]} > 0)); then
    say "WARNING: ${#MD5_DUP_NAME[@]} file name(s) are listed with different checksums; those files are matched by relative path only"
  fi
fi

# Find the expected checksum for an output file. Sets EXPECTED (empty if none)
# and NOTE (why no checksum is available). Runs in the current shell.
lookup_md5() {
  local out="$1" rel base
  EXPECTED=""
  NOTE=""
  [[ -n "$MD5_LIST" ]] || return 0
  rel="${out#"$DATA_DIR/"}"
  base="${out##*/}"
  if [[ -n "${MD5_BY_PATH[$rel]:-}" ]]; then
    EXPECTED="${MD5_BY_PATH[$rel]}"
  elif [[ -n "${MD5_DUP_NAME[$base]:-}" ]]; then
    NOTE="'$base' is listed with different checksums and '$rel' is not in the list"
  elif [[ -n "${MD5_BY_NAME[$base]:-}" ]]; then
    EXPECTED="${MD5_BY_NAME[$base]}"
  elif [[ -n "${MD5_BY_PATH[$rel.c4gh]:-}" || -n "${MD5_BY_NAME[$base.c4gh]:-}" ]]; then
    NOTE="the list only has '$base.c4gh', the encrypted file, whose checksum cannot verify decrypted data"
  else
    NOTE="not in the md5 list"
  fi
  return 0
}

# Collect filenames safely (spaces, newlines, Unicode) and group them by their
# top-level folder below DATA_DIR ("." = files directly in DATA_DIR).
# Works on bash 4.2, unlike `mapfile -d ''`, which needs bash 4.4.
ALL_FILES=()
ALL_GROUPS=()
declare -A GROUP_COUNT=() GROUP_PENDING=() GROUP_BYTES=()
while IFS= read -r -d '' rec; do
  size="${rec%% *}"
  rel="${rec#* }"
  if [[ "$rel" == */* ]]; then g="${rel%%/*}"; else g="."; fi
  ALL_FILES+=("$DATA_DIR/$rel")
  ALL_GROUPS+=("$g")
  GROUP_COUNT["$g"]=$(( ${GROUP_COUNT[$g]:-0} + 1 ))
  GROUP_BYTES["$g"]=$(( ${GROUP_BYTES[$g]:-0} + size ))
  if [[ ! -e "$DATA_DIR/${rel%.c4gh}" && ! -L "$DATA_DIR/${rel%.c4gh}" ]]; then
    GROUP_PENDING["$g"]=$(( ${GROUP_PENDING[$g]:-0} + 1 ))
  fi
done < <(find "$DATA_DIR" -type f -name '*.c4gh' -printf '%s %P\0')
((${#ALL_FILES[@]} > 0)) || die "No .c4gh files were found under: $DATA_DIR"
DIR_GROUPS=()
while IFS= read -r -d '' g; do
  DIR_GROUPS+=("$g")
done < <(printf '%s\0' "${!GROUP_COUNT[@]}" | LC_ALL=C sort -z)

human_size() {
  awk -v b="$1" 'BEGIN { split("B KB MB GB TB PB", u, " "); i = 1
    while (b >= 1024 && i < 6) { b /= 1024; i++ }
    if (i == 1) printf "%d %s", b, u[i]; else printf "%.1f %s", b, u[i] }'
}

group_label() {
  if [[ "$1" == "." ]]; then printf '(files directly in this folder)'; else printf '%s/' "$1"; fi
}

# Parse a selection such as "3", "1-5", "1,3,7", "1-3 8 10-12" or "all" for
# $2 entries. Sets SEL (0-based indexes, ascending, no duplicates) or SEL_ERR.
parse_selection() {
  local n="$2" tok a b i
  local -a toks=() seen=()
  SEL=()
  SEL_ERR=""
  read -ra toks <<< "${1//,/ }"
  if ((${#toks[@]} == 0)); then
    SEL_ERR="empty selection"
    return 1
  fi
  for tok in "${toks[@]}"; do
    tok="${tok,,}"
    if [[ "$tok" == "a" || "$tok" == "all" || "$tok" == "*" ]]; then
      a=1; b=$n
    elif [[ "$tok" =~ ^([0-9]{1,9})-([0-9]{1,9})$ ]]; then
      a=$((10#${BASH_REMATCH[1]})); b=$((10#${BASH_REMATCH[2]}))
    elif [[ "$tok" =~ ^[0-9]{1,9}$ ]]; then
      a=$((10#$tok)); b=$a
    else
      SEL_ERR="not understood: '$tok'"
      return 1
    fi
    if ((a < 1 || b > n || a > b)); then
      SEL_ERR="out of range: '$tok' (valid: 1-$n)"
      return 1
    fi
    for ((i = a; i <= b; i++)); do
      seen[i]=1
    done
  done
  for ((i = 1; i <= n; i++)); do
    if [[ -n "${seen[i]:-}" ]]; then
      SEL+=($((i - 1)))
    fi
  done
  return 0
}

# Choose which folders to decrypt. Sets CHOSEN (group -> 1).
declare -A CHOSEN=()
choose_dirs() {
  local n=${#DIR_GROUPS[@]} i g ans files=0 pending=0 shown=0
  if ((n == 1)); then
    CHOSEN["${DIR_GROUPS[0]}"]=1
    return 0
  fi
  if [[ -n "${EGA_SELECT:-}" ]]; then
    parse_selection "$EGA_SELECT" "$n" || die "EGA_SELECT: $SEL_ERR"
  elif ! have_tty; then
    say "No terminal for choosing folders; decrypting all $n folder(s) (set EGA_SELECT to choose)"
    parse_selection all "$n"
  else
    printf '\nFolders with .c4gh files in %s:\n' "$DATA_DIR" >&2
    for i in "${!DIR_GROUPS[@]}"; do
      g="${DIR_GROUPS[i]}"
      if ((${GROUP_PENDING[$g]:-0} == 0)); then ans="all decrypted"; else ans="${GROUP_PENDING[$g]} to decrypt"; fi
      printf '  %3d) %-40s %5d file(s) %10s   %s\n' "$((i + 1))" "$(group_label "$g")" \
        "${GROUP_COUNT[$g]}" "$(human_size "${GROUP_BYTES[$g]}")" "$ans" >&2
    done
    while :; do
      printf '\nExamples: 3 | 1-5 | 1,3,7 | 1-3,8,10-12 | all\n' >&2
      read -r -p "Select folder(s) to decrypt, q to quit: " ans </dev/tty || die "Could not read your selection"
      if [[ "$ans" == [qQ] ]]; then
        die "No folder selected"
      fi
      if ! parse_selection "$ans" "$n"; then
        printf 'Invalid selection: %s\n' "$SEL_ERR" >&2
        continue
      fi
      files=0; pending=0; shown=0
      printf 'Selected %d folder(s):\n' "${#SEL[@]}" >&2
      for i in "${SEL[@]}"; do
        g="${DIR_GROUPS[i]}"
        files=$((files + ${GROUP_COUNT[$g]}))
        pending=$((pending + ${GROUP_PENDING[$g]:-0}))
        if ((shown < 10)); then
          printf '  %s\n' "$(group_label "$g")" >&2
          shown=$((shown + 1))
        fi
      done
      if ((${#SEL[@]} > shown)); then
        printf '  ... and %d more\n' "$(( ${#SEL[@]} - shown ))" >&2
      fi
      read -r -p "$files file(s), $pending to decrypt. Proceed? [Y/n] " ans </dev/tty || die "Could not read your answer"
      if [[ -z "$ans" || "$ans" == [yY]* ]]; then
        break
      fi
    done
  fi
  for i in "${SEL[@]}"; do
    CHOSEN["${DIR_GROUPS[i]}"]=1
  done
  return 0
}

choose_dirs
FILES=()
for i in "${!ALL_FILES[@]}"; do
  if [[ -n "${CHOSEN[${ALL_GROUPS[i]}]:-}" ]]; then
    FILES+=("${ALL_FILES[i]}")
  fi
done
say "Selected ${#CHOSEN[@]} of ${#DIR_GROUPS[@]} folder(s): ${#FILES[@]} encrypted file(s)"

# Remove temporary files on exit, Ctrl-C, SIGTERM, or SSH disconnect.
tmp=""
C4GH_ERR="$(mktemp)" || die "Cannot create a temporary file"
cleanup() {
  if [[ -n "$tmp" ]]; then rm -f -- "$tmp"; fi
  rm -f -- "$C4GH_ERR"
  return 0
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP

# Run crypt4gh decrypt, hiding its per-call "passphrase in an environment
# variable" warning (we set that variable deliberately after prompting once).
# stderr is filtered synchronously so messages stay next to their log line.
c4gh_decrypt() {
  local rc=0
  "$C4GH" decrypt --sk "$KEY" "$@" 2>"$C4GH_ERR" || rc=$?
  grep -v -- 'passphrase in an environment variable' "$C4GH_ERR" >&2 || true
  return "$rc"
}

# mktemp always creates 0600 files; apply the configured umask explicitly.
OUT_MODE="$(printf '%o' "$((0666 & ~$(umask)))")"

# Preflight on the first file that still needs decrypting. A failure here is
# only a warning: that one file may be damaged while the rest are fine.
for f in "${FILES[@]}"; do
  [[ -e "${f%.c4gh}" || -L "${f%.c4gh}" ]] && continue
  say "Testing key against: $f"
  # crypt4gh's span is end-start-1, so 0-2 decrypts exactly one byte.
  if c4gh_decrypt --range 0-2 < "$f" > /dev/null; then
    say "Key/file compatibility preflight succeeded"
  else
    say "WARNING: preflight failed for this file (wrong key or damaged file); continuing with all files"
  fi
  break
done

DECRYPT_FAIL="wrong key, damaged file, disk full / write error, or crypt4gh error"
success=0
skipped=0
failed=0
verified=0
unverified=0
for file in "${FILES[@]}"; do
  output="${file%.c4gh}"
  lookup_md5 "$output"

  if [[ -e "$output" || -L "$output" ]]; then
    if [[ -n "$EXPECTED" ]]; then
      say "Verifying existing output: $output"
      if ! actual="$(md5sum 2>/dev/null < "$output")"; then
        say "FAILED (output exists but cannot be read for md5 check): $output"
        failed=$((failed + 1))
      elif [[ "${actual%% *}" == "$EXPECTED" ]]; then
        say "SKIP (output exists, md5 verified): $output"
        skipped=$((skipped + 1))
        verified=$((verified + 1))
      else
        say "FAILED (existing output md5 mismatch: expected $EXPECTED, got ${actual%% *}; delete it to decrypt again): $output"
        failed=$((failed + 1))
      fi
    elif [[ -n "$MD5_LIST" ]]; then
      say "SKIP (output exists, NOT verified: $NOTE): $output"
      skipped=$((skipped + 1))
      unverified=$((unverified + 1))
    else
      say "SKIP (output exists): $output"
      skipped=$((skipped + 1))
    fi
    continue
  fi

  if ! tmp="$(mktemp -- "${output}.partial.XXXXXXXX")"; then
    tmp=""
    say "FAILED (cannot create temporary output; check permissions / disk space): $file"
    failed=$((failed + 1))
    continue
  fi

  say "Decrypting: $file"
  ok=1
  if [[ -n "$EXPECTED" ]]; then
    if actual="$(c4gh_decrypt < "$file" | tee -- "$tmp" | md5sum)"; then
      actual="${actual%% *}"
      if [[ "$actual" == "$EXPECTED" ]]; then
        verified=$((verified + 1))
      else
        say "FAILED (md5 mismatch: expected $EXPECTED, got $actual): $file"
        ok=0
      fi
    else
      say "FAILED ($DECRYPT_FAIL): $file"
      ok=0
    fi
  elif ! c4gh_decrypt < "$file" > "$tmp"; then
    say "FAILED ($DECRYPT_FAIL): $file"
    ok=0
  fi

  if ((ok)); then
    # mv -n prevents overwriting output if another process created it in the meantime.
    if chmod "$OUT_MODE" -- "$tmp" && mv -n -- "$tmp" "$output" && [[ ! -e "$tmp" ]]; then
      tmp=""
      if [[ -n "$EXPECTED" ]]; then
        say "SUCCESS (md5 verified): $output"
      elif [[ -n "$MD5_LIST" ]]; then
        say "SUCCESS (NOT md5 verified: $NOTE): $output"
        unverified=$((unverified + 1))
      else
        say "SUCCESS: $output"
      fi
      success=$((success + 1))
      continue
    fi
    say "FAILED/SKIPPED (output appeared concurrently or cannot rename): $output"
  fi
  rm -f -- "$tmp"
  tmp=""
  failed=$((failed + 1))
done

summary="Finished. Total=${#FILES[@]} Success=$success Skipped=$skipped Failed=$failed"
if [[ -n "$MD5_LIST" ]]; then
  summary+=" Md5Verified=$verified Unverified=$unverified"
fi
say "$summary"
if ((success > 0)) && [[ -z "$MD5_LIST" ]]; then
  say "Note: Crypt4GH cannot detect truncation at a segment boundary; verify against EGA md5 checksums if available."
elif ((unverified > 0)); then
  say "WARNING: $unverified file(s) could not be md5-verified; see the NOT verified lines above."
fi
((failed == 0)) || exit 1
