#!/usr/bin/env bash
# =============================================================================
# EGA Live Outbox 多线程下载脚本（rclone + SFTP）
#
#  - 交互输入账户（邮箱）
#  - 从 ~/.ssh/key/ 中选择私钥
#  - 列出 Outbox 中的文件夹，按编号选择要下载的文件夹
#  - 使用 --ignore-existing：本地已存在的文件一律跳过，不覆盖
#  - 多文件并行 + 单个大文件多线程分段下载
#
# 用法:  bash ega_rclone_download.sh
# =============================================================================
set -uo pipefail

DEFAULT_HOST="outbox.ega-archive.org"
DEFAULT_PORT="22"
KEY_DIR="$HOME/.ssh/key"
MIN_RCLONE="1.63"          # 1.63+ 下载时先写 .partial 临时文件，中断不会留下"假完成"文件

c_red()   { printf '\033[31m%s\033[0m\n' "$*"; }
c_green() { printf '\033[32m%s\033[0m\n' "$*"; }
c_yellow(){ printf '\033[33m%s\033[0m\n' "$*"; }
c_bold()  { printf '\033[1m%s\033[0m\n' "$*"; }

ver_ge() { [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n1)" = "$2" ]; }

# -----------------------------------------------------------------------------
# 1. 检查 / 安装 rclone
# -----------------------------------------------------------------------------
install_rclone() {
    c_yellow "将使用 rclone 官方脚本安装最新版（需要 sudo）..."
    if ! command -v curl >/dev/null || ! command -v unzip >/dev/null; then
        sudo apt-get update && sudo apt-get install -y curl unzip
    fi
    curl -fsSL https://rclone.org/install.sh | sudo bash
}

if ! command -v rclone >/dev/null 2>&1; then
    c_yellow "未检测到 rclone。"
    read -rp "现在安装最新版 rclone? [Y/n] " ans
    if [[ "${ans:-Y}" =~ ^[Yy]$ ]]; then install_rclone; else exit 1; fi
fi

RCLONE_VER="$(rclone version 2>/dev/null | head -n1 | sed -E 's/^rclone v?([0-9.]+).*/\1/')"
if ! ver_ge "$RCLONE_VER" "$MIN_RCLONE"; then
    c_yellow "当前 rclone 版本 $RCLONE_VER 过旧（Ubuntu apt 源的版本通常较老），建议 >= $MIN_RCLONE。"
    c_yellow "旧版本中断下载可能留下不完整文件，而 --ignore-existing 会把它当作已下载而跳过。"
    read -rp "现在升级到最新版? [Y/n] " ans
    if [[ "${ans:-Y}" =~ ^[Yy]$ ]]; then install_rclone; fi
fi
c_green "rclone 版本: $(rclone version | head -n1)"
echo

# -----------------------------------------------------------------------------
# 2. 输入账户（邮箱）与服务器
# -----------------------------------------------------------------------------
while true; do
    read -rp "请输入 EGA 账户（邮箱地址）: " EGA_USER
    [[ "$EGA_USER" == *@*.* ]] && break
    c_red "邮箱格式不正确，请重新输入。"
done

read -rp "SFTP 服务器 [默认 $DEFAULT_HOST]: " EGA_HOST
EGA_HOST="${EGA_HOST:-$DEFAULT_HOST}"
read -rp "端口 [默认 $DEFAULT_PORT]: " EGA_PORT
EGA_PORT="${EGA_PORT:-$DEFAULT_PORT}"
echo

# -----------------------------------------------------------------------------
# 3. 选择私钥（~/.ssh/key/ 下的文件，排除 .pub）
# -----------------------------------------------------------------------------
if [ -d "$KEY_DIR" ]; then
    SEARCH_DIR="$KEY_DIR"
else
    c_yellow "目录 $KEY_DIR 不存在，改为在 ~/.ssh 中查找私钥。"
    SEARCH_DIR="$HOME/.ssh"
fi

mapfile -t KEYS < <(find "$SEARCH_DIR" -maxdepth 1 -type f \
    ! -name '*.pub' ! -name 'known_hosts*' ! -name 'config' ! -name 'authorized_keys*' \
    | sort)

if [ "${#KEYS[@]}" -eq 0 ]; then
    c_red "在 $SEARCH_DIR 中没有找到私钥文件。"
    exit 1
fi

c_bold "可用私钥（$SEARCH_DIR）:"
for i in "${!KEYS[@]}"; do
    printf '  %2d) %s\n' "$((i + 1))" "$(basename "${KEYS[$i]}")"
done
while true; do
    read -rp "请选择私钥编号: " k
    if [[ "$k" =~ ^[0-9]+$ ]] && [ "$k" -ge 1 ] && [ "$k" -le "${#KEYS[@]}" ]; then
        KEY_FILE="${KEYS[$((k - 1))]}"
        break
    fi
    c_red "无效编号。"
done
chmod 600 "$KEY_FILE" 2>/dev/null || true
c_green "使用私钥: $KEY_FILE"

# 私钥是否带密码
KEY_PASS_OBSCURED=""
if ! ssh-keygen -y -P "" -f "$KEY_FILE" >/dev/null 2>&1; then
    read -rsp "该私钥有密码保护，请输入私钥密码: " KEY_PASS; echo
    if ! ssh-keygen -y -P "$KEY_PASS" -f "$KEY_FILE" >/dev/null 2>&1; then
        c_red "私钥密码错误，或文件不是有效私钥。"
        exit 1
    fi
    KEY_PASS_OBSCURED="$(printf '%s' "$KEY_PASS" | rclone obscure -)"
    unset KEY_PASS
fi
echo

# -----------------------------------------------------------------------------
# 4. 配置 rclone（通过环境变量，不写入 rclone.conf，不保存任何凭据）
# -----------------------------------------------------------------------------
export RCLONE_SFTP_HOST="$EGA_HOST"
export RCLONE_SFTP_PORT="$EGA_PORT"
export RCLONE_SFTP_USER="$EGA_USER"
export RCLONE_SFTP_KEY_FILE="$KEY_FILE"
[ -n "$KEY_PASS_OBSCURED" ] && export RCLONE_SFTP_KEY_FILE_PASS="$KEY_PASS_OBSCURED"
export RCLONE_SFTP_SHELL_TYPE="none"          # Outbox 不提供 shell，避免 rclone 尝试执行远程命令
export RCLONE_SFTP_DISABLE_HASHCHECK="true"   # 同上，无法远程计算 md5/sha1
REMOTE=":sftp:"

# -----------------------------------------------------------------------------
# 5. 列出远程文件夹并选择
# -----------------------------------------------------------------------------
read -rp "远程起始路径（直接回车 = Outbox 根目录）: " BASE
BASE="${BASE%/}"; BASE="${BASE#/}"

c_yellow "正在连接 $EGA_USER@$EGA_HOST:$EGA_PORT 并列出文件夹..."
LIST_OUT="$(rclone lsf "${REMOTE}${BASE}" --dirs-only --contimeout 30s 2>&1)"
if [ $? -ne 0 ]; then
    c_red "连接或列目录失败："
    echo "$LIST_OUT"
    exit 1
fi
mapfile -t DIRS < <(printf '%s\n' "$LIST_OUT" | sed '/^$/d; s:/$::')

if [ "${#DIRS[@]}" -eq 0 ]; then
    c_red "该路径下没有文件夹。"
    exit 1
fi

# 本地保存目录
while true; do
    read -erp "请输入本地保存目录（可用 Tab 补全）: " DEST
    DEST="${DEST/#\~/$HOME}"
    DEST="${DEST%/}"
    if [ -z "$DEST" ]; then
        c_red "保存目录不能为空。"
        continue
    fi
    if [ ! -d "$DEST" ]; then
        read -rp "目录 $DEST 不存在，是否创建? [Y/n] " ans
        [[ "${ans:-Y}" =~ ^[Yy]$ ]] || continue
    fi
    if mkdir -p "$DEST/.logs" 2>/dev/null && [ -w "$DEST" ]; then
        DEST="$(cd "$DEST" && pwd)"
        break
    fi
    c_red "无法创建或写入 $DEST，请换一个目录。"
done
c_green "保存目录: $DEST"
STATE_FILE="$DEST/.ega_done_folders"
touch "$STATE_FILE"

remote_path() { if [ -n "$BASE" ]; then printf '%s/%s' "$BASE" "$1"; else printf '%s' "$1"; fi; }

echo
c_bold "远程文件夹列表（[已完成] = 之前已完整下载并校验通过）:"
for i in "${!DIRS[@]}"; do
    rp="$(remote_path "${DIRS[$i]}")"
    tag=""
    if grep -Fxq "$rp" "$STATE_FILE"; then tag=" [已完成]"
    elif [ -d "$DEST/$rp" ]; then tag=" [部分已下载]"; fi
    printf '  %3d) %s%s\n' "$((i + 1))" "${DIRS[$i]}" "$tag"
done
echo "输入示例:  1 3 5-8   |  all = 全部  |  todo = 全部未完成的"

SELECTED=()
while [ "${#SELECTED[@]}" -eq 0 ]; do
    read -rp "请选择要下载的文件夹: " sel
    SELECTED=()
    case "$sel" in
        all) SELECTED=("${!DIRS[@]}") ;;
        todo)
            for i in "${!DIRS[@]}"; do
                grep -Fxq "$(remote_path "${DIRS[$i]}")" "$STATE_FILE" || SELECTED+=("$i")
            done ;;
        *)
            ok=1
            for tok in $sel; do
                if [[ "$tok" =~ ^([0-9]+)-([0-9]+)$ ]]; then
                    for ((n = BASH_REMATCH[1]; n <= BASH_REMATCH[2]; n++)); do SELECTED+=("$((n - 1))"); done
                elif [[ "$tok" =~ ^[0-9]+$ ]]; then
                    SELECTED+=("$((tok - 1))")
                else ok=0; fi
            done
            for i in "${SELECTED[@]}"; do
                { [ "$i" -lt 0 ] || [ "$i" -ge "${#DIRS[@]}" ]; } && ok=0
            done
            [ "$ok" -eq 1 ] || { c_red "输入有误。"; SELECTED=(); } ;;
    esac
    [ "${#SELECTED[@]}" -eq 0 ] && [ "$sel" = "todo" ] && { c_green "所有文件夹都已完成。"; exit 0; }
done
# 去重并保持顺序
mapfile -t SELECTED < <(printf '%s\n' "${SELECTED[@]}" | awk '!seen[$0]++')

# -----------------------------------------------------------------------------
# 6. 并发参数
# -----------------------------------------------------------------------------
echo
read -rp "同时下载的文件数 --transfers [默认 8]: " TRANSFERS
TRANSFERS="${TRANSFERS:-8}"
read -rp "单个大文件分段线程数 --multi-thread-streams [默认 4]: " STREAMS
STREAMS="${STREAMS:-4}"

echo
c_bold "下载限速 --bwlimit（所有并行下载的总速度）:"
echo "  直接回车 = 不限速"
echo "  200Mbps  = 总速度上限 200 Mbps（与进度显示的单位一致）"
echo "  50M      = 总速度上限 50 MiB/s（rclone 原生写法，单位 K/M/G，字节每秒）"
echo "  \"08:00,20M 19:00,off\"  = 按时间段：8 点到 19 点限 20 MiB/s，19 点后不限"
BWLIMIT_ARGS=()
while true; do
    read -rp "请输入限速 [默认 不限速]: " BWLIMIT
    BWLIMIT="$(echo "$BWLIMIT" | sed -E 's/^["'\'']|["'\'']$//g')"   # 去掉首尾引号
    if [ -z "$BWLIMIT" ] || [ "$BWLIMIT" = "off" ]; then
        BWLIMIT="off"
        break
    fi
    # 支持 Mbps / Gbps 写法，换算成 rclone 的 KiB/s
    if [[ "$BWLIMIT" =~ ^([0-9]+(\.[0-9]+)?)[[:space:]]*([MmGg])bps$ ]]; then
        num="${BASH_REMATCH[1]}"; unit="${BASH_REMATCH[3]}"
        mult=1000000; [[ "$unit" =~ [Gg] ]] && mult=1000000000
        kib="$(awk -v n="$num" -v m="$mult" 'BEGIN { printf "%d", n * m / 8 / 1024 }')"
        if [ "$kib" -lt 1 ]; then c_red "限速值太小。"; continue; fi
        c_yellow "  $BWLIMIT ≈ ${kib}K（KiB/s）"
        BWLIMIT="${kib}K"
    fi
    # 让 rclone 自己解析，格式不对会报错
    if rclone version --bwlimit "$BWLIMIT" >/dev/null 2>&1; then
        BWLIMIT_ARGS=(--bwlimit "$BWLIMIT")
        break
    fi
    c_red "限速格式无效：$BWLIMIT"
done
if [ "$BWLIMIT" = "off" ]; then c_green "限速: 不限速"; else c_green "限速: $BWLIMIT"; fi

# -----------------------------------------------------------------------------
# 7. 自定义进度显示：已下载量/总量用 GiB，速率用 Mbps
#    rclone 的 --stats-unit 会同时改变数据量和速率的单位，无法分开，
#    所以这里开启 rclone 的本地 rc 接口，每 2 秒读取统计信息自己格式化。
# -----------------------------------------------------------------------------
read -r -d '' PROGRESS_PY <<'PYEOF'
import json, sys
try:
    s = json.load(sys.stdin)
except Exception:
    sys.exit(1)

def size(b):
    # 自动选择单位，从 M 起：不足 1G 显示 M，不足 1T 显示 G，否则显示 T
    b = float(b or 0) / 1024 / 1024
    for u in ("M", "G", "T"):
        if b < 1024 or u == "T":
            return f"{b:.2f}{u}"
        b /= 1024

def mbps(bps):
    return f"{float(bps or 0) * 8 / 1e6:.1f} Mbps"

def dur(sec):
    if sec is None:
        return "-"
    sec = int(sec)
    h, r = divmod(sec, 3600)
    m, s_ = divmod(r, 60)
    return f"{h}h{m:02d}m{s_:02d}s" if h else f"{m}m{s_:02d}s"

done, total = s.get("bytes", 0), s.get("totalBytes", 0)
pct = done * 100 / total if total else 0
width = int(sys.argv[1]) if len(sys.argv) > 1 else 100
maxfiles = int(sys.argv[2]) if len(sys.argv) > 2 else 8

out = [
    f"已下载: {size(done)} / {size(total)}, {pct:.1f}%, {mbps(s.get('speed'))}, ETA {dur(s.get('eta'))}",
    f"文件:   {s.get('transfers', 0)} / {s.get('totalTransfers', 0)} 已完成, "
    f"已检查 {s.get('checks', 0)}, 错误 {s.get('errors', 0)}, 用时 {dur(s.get('elapsedTime'))}",
]
tr = s.get("transferring") or []
if tr:
    out.append("正在下载:")
    for t in tr[:maxfiles]:
        name = t.get("name", "")
        info = f" {t.get('percentage', 0):3d}% / {size(t.get('size'))}, {mbps(t.get('speed'))}"
        room = max(10, width - len(info) - 6)
        if len(name) > room:
            name = "…" + name[-(room - 1):]
        out.append(f"  * {name}:{info}")
    if len(tr) > maxfiles:
        out.append(f"  ... 另外 {len(tr) - maxfiles} 个文件")
print("\n".join(line[:width] for line in out))
PYEOF

# 用法: run_rclone_with_progress <rclone 子命令和参数...>
run_rclone_with_progress() {
    if ! command -v python3 >/dev/null 2>&1; then
        c_yellow "    未找到 python3，改用 rclone 自带进度显示（单位为字节）。"
        rclone "$@" --progress --stats-one-line
        return $?
    fi

    local port user pass url pid rc lines=0 cols stats block
    port=$(( 20000 + RANDOM % 20000 ))
    user="ega$RANDOM"
    pass="$(head -c 18 /dev/urandom | base64 | tr -dc 'A-Za-z0-9')"
    url="http://127.0.0.1:$port/"

    rclone "$@" --rc --rc-addr "127.0.0.1:$port" --rc-user "$user" --rc-pass "$pass" &
    pid=$!
    trap 'kill -INT "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; echo; c_red "已中断。"; exit 130' INT TERM

    while kill -0 "$pid" 2>/dev/null; do
        sleep 2
        stats="$(rclone rc core/stats --url "$url" --user "$user" --pass "$pass" 2>/dev/null)" || continue
        cols="$(tput cols 2>/dev/null || echo 100)"
        block="$(printf '%s' "$stats" | python3 -c "$PROGRESS_PY" "$cols" 8)" || continue
        # 清除上一次的输出再重绘
        [ "$lines" -gt 0 ] && printf '\033[%dA\033[J' "$lines"
        printf '%s\n' "$block"
        lines="$(printf '%s\n' "$block" | wc -l)"
    done

    wait "$pid"; rc=$?
    trap - INT TERM
    return $rc
}

# -----------------------------------------------------------------------------
# 8. 逐个文件夹下载
# -----------------------------------------------------------------------------
FAILED=()
for i in "${SELECTED[@]}"; do
    name="${DIRS[$i]}"
    rp="$(remote_path "$name")"
    local_dir="$DEST/$rp"
    log="$DEST/.logs/$(echo "$rp" | tr '/ ' '__')_$(date +%Y%m%d_%H%M%S).log"
    mkdir -p "$local_dir"

    echo
    c_bold "==> 下载: $rp  ->  $local_dir"
    run_rclone_with_progress copy "${REMOTE}${rp}" "$local_dir" \
        --ignore-existing \
        --transfers "$TRANSFERS" \
        --checkers 16 \
        --multi-thread-streams "$STREAMS" \
        --multi-thread-cutoff 256M \
        "${BWLIMIT_ARGS[@]}" \
        --retries 10 \
        --low-level-retries 20 \
        --retries-sleep 10s \
        --contimeout 60s \
        --timeout 10m \
        --stats 1m \
        --log-level INFO \
        --log-file "$log"
    rc=$?

    if [ $rc -ne 0 ]; then
        c_red "    下载出错 (exit $rc)，日志: $log"
        FAILED+=("$rp")
        continue
    fi

    # 按文件大小做单向校验：发现远程有但本地缺失 / 大小不一致的文件
    c_yellow "    校验文件大小..."
    diff_file="$DEST/.logs/$(echo "$rp" | tr '/ ' '__')_mismatch.txt"
    if rclone check "${REMOTE}${rp}" "$local_dir" --one-way --size-only \
            --differ "$diff_file" --missing-on-dst "$diff_file.missing" \
            --log-level ERROR >/dev/null 2>&1; then
        c_green "    完成并校验通过: $rp"
        grep -Fxq "$rp" "$STATE_FILE" || echo "$rp" >> "$STATE_FILE"
        rm -f "$diff_file" "$diff_file.missing"
    else
        c_red "    校验未通过，大小不一致的文件见: $diff_file"
        c_red "    （这些文件未被覆盖；如需重下，请先删除本地对应文件再运行本脚本）"
        FAILED+=("$rp")
    fi
done

# -----------------------------------------------------------------------------
# 9. 汇总
# -----------------------------------------------------------------------------
echo
c_bold "================ 汇总 ================"
echo "保存目录: $DEST"
echo "日志目录: $DEST/.logs"
if [ "${#FAILED[@]}" -eq 0 ]; then
    c_green "全部所选文件夹下载完成。"
else
    c_red "以下文件夹未完成（重新运行脚本并选择 todo 即可续传，已下载文件不会重复下载）:"
    printf '  - %s\n' "${FAILED[@]}"
    exit 1
fi
