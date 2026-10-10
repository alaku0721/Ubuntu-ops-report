#!/usr/bin/env bash
#===============================================================================
# 脚本名  ：ops_report.sh
# 用途    ：Linux/WSL 运维体检脚本，一键查看系统资源、磁盘、进程、端口、服务、日志与容器状态。
# 适用环境：Ubuntu（含 WSL2），需要 bash 4+。
# 运行方式：chmod +x ops_report.sh && ./ops_report.sh
#===============================================================================

# 只对未定义变量报错；不启用 set -e，避免某个探测命令失败就直接中断整个脚本。
set -u

# 如果输出不是终端（例如被重定向），就关闭颜色，避免在日志里出现乱码。
if [ -t 1 ]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    NC='\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; BLUE=''; NC=''
fi

LINE='----------------------------------------------------------------'
WARN_COUNT=0

# 打印辅助函数：统一输出格式，方便阅读。
info()    { printf "${BLUE}[信息]${NC} %s\n" "$*"; }
ok()      { printf "${GREEN}[通过]${NC} %s\n" "$*"; }
warn()    { WARN_COUNT=$((WARN_COUNT + 1)); printf "${YELLOW}[警告]${NC} %s\n" "$*"; }
err()     { printf "${RED}[错误]${NC} %s\n" "$*"; }
section() { printf "\n${GREEN}== %s ==${NC}\n%s\n" "$*" "$LINE"; }

echo "$LINE"
echo "  Linux 运维体检脚本"
echo "  运行时间：$(date '+%Y-%m-%d %H:%M:%S')"
echo "$LINE"

#===============================================================================
# 0. 运行前自检
#===============================================================================
section "0. 环境自检"

# 0.1 检查是否是 Linux 内核
KERNEL_NAME=$(uname -s 2>/dev/null || true)
if [ "$KERNEL_NAME" != "Linux" ]; then
    err "当前系统不是 Linux（uname -s 返回：${KERNEL_NAME:-未知}）。"
    echo "  本脚本需要在 Linux 或 WSL (Ubuntu) 环境运行，请在 WSL/虚拟机中执行。"
    exit 1
fi
ok "检测到 Linux 内核：$(uname -r)"

# 0.2 判断是否运行在 WSL 中（WSL 的 /proc/version 会包含 microsoft 字样）
if grep -qi microsoft /proc/version 2>/dev/null; then
    info "检测到 WSL 环境（/proc/version 中包含 microsoft 标识）。"
else
    info "未检测到 WSL 标识，按原生 Linux 处理。"
fi

# 0.3 判断 root / sudo 权限：只读命令大多不需要 root，缺少权限时降级提示而不退出。
SUDO=""
if [ "$(id -u)" -eq 0 ]; then
    ok "当前以 root 运行，权限完整。"
elif sudo -n true 2>/dev/null; then
    ok "当前用户 $(whoami) 具备免密 sudo 权限。"
    SUDO="sudo"
else
    warn "当前用户 $(whoami) 不是 root，且无法免密 sudo（执行 sudo 可能需要输入密码）。"
    warn "只读命令仍可继续，但端口/进程的详细归属信息可能不完整。"
fi

# 0.4 必需命令自检：这些命令是脚本正常工作的基础，缺失则给出安装方法并退出。
REQUIRED_CMDS=(ps df du free ss curl awk grep sed head sort uptime nproc hostname)
MISSING_REQUIRED=()
for c in "${REQUIRED_CMDS[@]}"; do
    if ! command -v "$c" >/dev/null 2>&1; then
        MISSING_REQUIRED+=("$c")
    fi
done

if [ ${#MISSING_REQUIRED[@]} -gt 0 ]; then
    err "缺少以下必需命令：${MISSING_REQUIRED[*]}"
    echo "  请先安装后重新运行："
    echo "    sudo apt update"
    echo "    sudo apt install -y procps coreutils iproute2 curl"
    exit 1
fi
ok "必需基础命令均已就绪：${REQUIRED_CMDS[*]}"

# 0.5 可选命令自检：docker/systemctl 等在裸 WSL 上常常没有，缺失时跳过对应模块，
#      而不是让整个脚本退出，保证脚本在任何 WSL 上都能跑出效果。
OPTIONAL_ORDER=(docker systemctl journalctl netstat ip hostnamectl)
declare -A OPTIONAL_TIPS=(
    [docker]="sudo apt install -y docker.io（或安装 Docker Desktop 并开启 WSL 集成）"
    [systemctl]="systemd 自带；旧版 WSL 需在 /etc/wsl.conf 中启用 systemd"
    [journalctl]="与 systemd 一同提供（systemd 包）"
    [netstat]="sudo apt install -y net-tools"
    [ip]="sudo apt install -y iproute2"
    [hostnamectl]="由 systemd 提供"
)
declare -A HAVE
for c in "${OPTIONAL_ORDER[@]}"; do
    if command -v "$c" >/dev/null 2>&1; then
        HAVE[$c]=1
    else
        HAVE[$c]=0
        warn "未检测到可选命令 $c，将跳过相关模块。补齐方法：${OPTIONAL_TIPS[$c]}"
    fi
done

# systemd 是否真的在运行：不能只看 systemctl 是否存在，旧版 WSL 装了命令也不运行 systemd。
SYSTEMD_RUNNING=0
if [ -d /run/systemd/system ]; then
    SYSTEMD_RUNNING=1
fi

#===============================================================================
# 1. 系统概览
#===============================================================================
section "1. 系统概览"

printf "主机名  ：%s\n" "$(hostname 2>/dev/null || cat /etc/hostname 2>/dev/null || echo 未知)"
printf "当前用户：%s (UID=%s)\n" "$(whoami)" "$(id -u)"

# 读取发行版信息；/etc/os-release 是 systemd 时代的标准文件。
if [ -r /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    printf "发行版  ：%s\n" "$PRETTY_NAME"
fi

printf "内核    ：%s\n" "$(uname -r)"
printf "架构    ：%s\n" "$(uname -m)"
printf "CPU 核心：%s 个\n" "$(nproc)"
grep -m1 'model name' /proc/cpuinfo 2>/dev/null | cut -d: -f2- | sed 's/^[[:space:]]*//' | sed 's/^/CPU 型号：/'
printf "运行时间：%s\n" "$(uptime -p 2>/dev/null || uptime)"
printf "平均负载(1/5/15 分钟)：%s\n" "$(cut -d' ' -f1-3 /proc/loadavg)"

#===============================================================================
# 2. CPU 与内存
#===============================================================================
section "2. CPU 与内存"

echo "内存使用概况："
free -h
echo

# free -b 的最后一列 available 是第 7 列，用它计算使用率最准确。
MEM_USED=$(free -b | awk '/^Mem:/ {printf "%.1f", ($2-$7)/$2*100}')
MEM_AVAIL=$(free -b | awk '/^Mem:/ {printf "%.1f", $7/$2*100}')
printf "内存使用率：%s%%（可用 %s%%）\n" "$MEM_USED" "$MEM_AVAIL"

#===============================================================================
# 3. 进程信息
#===============================================================================
section "3. 进程信息"

echo "内存占用 TOP 10："
ps aux --sort=-%mem | head -n 11
echo
echo "CPU 占用 TOP 10："
ps aux --sort=-%cpu | head -n 11
echo
printf "进程总数：%s\n" "$(ps -e --no-headers | wc -l)"
printf "线程总数（约）：%s\n" "$(ps -eLf --no-headers 2>/dev/null | wc -l)"

#===============================================================================
# 4. 磁盘空间
#===============================================================================
section "4. 磁盘空间"

echo "文件系统使用情况（df -h）："
df -h -x tmpfs -x devtmpfs -x overlay
echo
echo "inode 使用情况（df -i）："
df -i -x tmpfs -x devtmpfs -x overlay
echo
echo "当前用户家目录总大小（du -sh）："
du -sh "$HOME" 2>/dev/null
echo
echo "家目录下最大的子目录/文件 TOP 5（du）："
du -sh "$HOME"/.[!.]* "$HOME"/* 2>/dev/null | sort -rh | head -5

#===============================================================================
# 5. 网络与端口
#===============================================================================
section "5. 网络与端口"

if [ "${HAVE[ip]:-0}" = "1" ]; then
    echo "网络接口与 IP 地址（ip -brief address）："
    ip -brief address
    echo
fi

echo "正在监听的 TCP/UDP 端口（ss -tulnp）："
$SUDO ss -tulnp 2>/dev/null || ss -tuln
if [ "$(id -u)" -ne 0 ] && [ -z "$SUDO" ]; then
    warn "非 root 运行时，ss 的进程名列可能为空；如需查看端口属于哪个进程，请用 sudo 运行本脚本。"
fi
echo
echo "TCP 连接状态统计（ss -s）："
ss -s

if [ "${HAVE[netstat]:-0}" = "1" ]; then
    echo
    echo "补充：netstat 端口视图（netstat -tuln）："
    netstat -tuln 2>/dev/null
fi

#===============================================================================
# 6. 系统服务
#===============================================================================
section "6. 系统服务 (systemd)"

if [ "${HAVE[systemctl]:-0}" = "1" ] && [ "$SYSTEMD_RUNNING" = "1" ]; then
    echo "正在运行的服务（最多 15 个）："
    systemctl list-units --type=service --state=running --no-pager --no-legend 2>/dev/null | head -15
    echo
    echo "失败的服务单元："
    FAILED_UNITS=$(systemctl --failed --no-pager --no-legend 2>/dev/null)
    if [ -n "$FAILED_UNITS" ]; then
        echo "$FAILED_UNITS"
    else
        echo "（无失败服务）"
    fi
else
    warn "systemd 未运行（常见于旧版 WSL），跳过 systemctl 模块。"
    info "WSL2 启用 systemd 的方法：编辑 /etc/wsl.conf，加入以下内容："
    echo "      [boot]"
    echo "      systemd=true"
    echo "  保存后在 Windows 运行 wsl --shutdown，再重新打开 WSL 即可。"
fi

#===============================================================================
# 7. 日志检查
#===============================================================================
section "7. 日志检查"

if [ "${HAVE[journalctl]:-0}" = "1" ] && [ "$SYSTEMD_RUNNING" = "1" ]; then
    echo "本次启动以来 ERROR 级别的系统日志（最近 20 条）："
    ERRLOG=$(journalctl -p err -b --no-pager 2>/dev/null | tail -20)
    if [ -n "$ERRLOG" ]; then
        echo "$ERRLOG"
    else
        echo "（无错误日志或当前用户无权读取）"
    fi
else
    warn "journalctl 不可用或 systemd 未运行，尝试读取 /var/log/syslog。"
    tail -n 20 /var/log/syslog 2>/dev/null || warn "/var/log/syslog 不存在，跳过日志模块。"
fi

#===============================================================================
# 8. Docker 容器
#===============================================================================
section "8. Docker 容器"

if [ "${HAVE[docker]:-0}" = "1" ]; then
    if $SUDO docker info >/dev/null 2>&1; then
        echo "Docker 服务端版本："
        $SUDO docker version --format '{{.Server.Version}}' 2>/dev/null
        echo
        echo "容器列表（含已停止）："
        $SUDO docker ps -a --format 'table {{.ID}}\t{{.Names}}\t{{.Image}}\t{{.Status}}' 2>/dev/null
        echo
        echo "容器资源占用快照："
        $SUDO docker stats --no-stream 2>/dev/null
    else
        warn "docker 命令存在，但 Docker 守护进程未启动或当前用户无权限。"
        echo "  若使用 Docker Desktop，请确认已启动并在 Settings 中开启 WSL Integration。"
        echo "  若使用 docker.io，请执行：sudo service docker start"
    fi
else
    warn "未安装 docker，跳过容器模块。"
fi

#===============================================================================
# 9. 网络连通性
#===============================================================================
section "9. 网络连通性"

# 用 curl 检测常见站点是否可达，并输出 HTTP 状态码与耗时。
check_url() {
    local url="$1" label="$2" result code time_t
    result=$(curl -sS -o /dev/null -m 6 -w '%{http_code} %{time_total}' "$url" 2>/dev/null)
    code=$(echo "$result" | awk '{print $1}')
    time_t=$(echo "$result" | awk '{print $2}')
    if [ -n "$code" ] && [ "$code" != "000" ]; then
        ok "$label（$url）HTTP $code，耗时 ${time_t}s"
    else
        warn "$label（$url）无法访问（超时或 DNS 解析失败）。"
    fi
}

check_url "https://www.baidu.com" "百度"
check_url "https://www.example.com" "Example"

#===============================================================================
# 完成汇总
#===============================================================================
section "体检完成"

ok "脚本运行结束。"
if [ "$WARN_COUNT" -gt 0 ]; then
    info "本次共产生 $WARN_COUNT 条警告，可按提示补齐相关组件后获得更完整的结果。"
else
    info "本次检查未产生警告，环境比较完整。"
fi
