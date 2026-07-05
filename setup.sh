#!/usr/bin/env bash
# ============================================================================
#  多服务一键部署脚本  v3.5.0
#  集成: Cloudflared Tunnel / Lucky(幸运加速) / 3x-ui (X-UI)
#
#  Init 支持: systemd / sysvinit / OpenRC
#  发行版:    Ubuntu Debian CentOS RHEL Fedora Arch Alpine OpenWrt openSUSE
#  架构:      amd64 arm64 arm 386
#
#  用法: sudo bash setup.sh
# ============================================================================

set -uo pipefail

# ========================== 全局变量 ==========================
SCRIPT_VERSION="3.5.1"
CLOUDFLARED_TOKEN=""
INSTALL_CF=true
INSTALL_LUCKY=true
INSTALL_3XUI=true
CONF_DIR="/etc/services-deploy"
TMP_FILES=()

# 颜色
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

# ---------- --uninstall 快捷入口 ----------
if [[ "${1:-}" == "--uninstall" || "${1:-}" == "-u" ]]; then
    echo -e "${YELLOW}正在下载卸载脚本...${NC}"
    bash <(curl -fsSL https://raw.githubusercontent.com/xiaoxinkeji/sh/main/uninstall.sh)
    exit $?
fi

# ============================================================================
#                          基础设施
# ============================================================================

# ---------- 信号捕获: 清理临时文件 ----------
cleanup() {
    for f in "${TMP_FILES[@]}"; do
        [[ -f "$f" ]] && rm -f "$f" 2>/dev/null
    done
}
trap cleanup EXIT INT TERM

# ---------- 日志 ----------
log_info()    { echo -e "${BLUE}[INFO]${NC}  $*"; }
log_success() { echo -e "${GREEN}[ OK ]${NC} $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error()   { echo -e "${RED}[FAIL]${NC} $*"; }
log_step()    { echo -e "\n${CYAN}${BOLD}━━━ $* ━━━${NC}"; }
divider()     { echo -e "${BLUE}──────────────────────────────────────────────────────${NC}"; }

# ---------- 带重试的下载 ----------
# 用法: download_retry <url> <output> [max_retries]
download_retry() {
    local url="$1" output="$2" retries="${3:-3}"
    local attempt=1
    while (( attempt <= retries )); do
        if curl -fsSL --connect-timeout 15 --max-time 120 -o "$output" "$url" 2>/dev/null; then
            return 0
        fi
        log_warn "下载失败 (第 ${attempt}/${retries} 次): $url"
        (( attempt++ ))
        sleep $(( attempt - 1 ))
    done
    log_error "下载最终失败: $url"
    return 1
}

# ---------- 网络连通性预检 ----------
check_network() {
    log_step "网络连通性检查"
    local targets=("https://github.com" "https://raw.githubusercontent.com" "http://release.66666.host")
    local ok=0 fail=0

    for target in "${targets[@]}"; do
        if curl -fsS --connect-timeout 8 --max-time 15 -o /dev/null "$target" 2>/dev/null; then
            log_success "可达: $target"
            (( ok++ ))
        else
            log_warn "不可达: $target"
            (( fail++ ))
        fi
    done

    if (( fail == ${#targets[@]} )); then
        log_error "所有目标均不可达, 请检查网络连接"
        exit 1
    fi
    if (( fail > 0 )); then
        log_warn "${fail} 个目标不可达, 部分服务可能安装失败"
    fi
}

# ---------- 磁盘空间检查 (至少需要 500MB) ----------
check_disk_space() {
    local required_mb=500
    local available_mb
    available_mb="$(df -m / | awk 'NR==2 {print $4}')"

    if [[ -n "$available_mb" ]] && (( available_mb < required_mb )); then
        log_error "磁盘空间不足: 需要 ${required_mb}MB, 仅有 ${available_mb}MB"
        exit 1
    fi
    log_info "磁盘可用空间: ${available_mb}MB"
}

# ============================================================================
#                          环境检测
# ============================================================================

detect_os() {
    OS=""; OS_ID=""; OS_VER=""; ARCH=""; PKG_MGR=""; INIT_SYSTEM=""

    # ---------- 操作系统 ----------
    if [[ -f /etc/os-release ]]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        OS="${NAME:-Unknown}"; OS_ID="${ID:-unknown}"; OS_VER="${VERSION_ID:-}"
    elif [[ -f /etc/redhat-release ]]; then
        OS="RedHat"; OS_ID="rhel"
    elif [[ -f /etc/debian_version ]]; then
        OS="Debian"; OS_ID="debian"; OS_VER="$(cat /etc/debian_version)"
    elif [[ -f /etc/alpine-release ]]; then
        OS="Alpine Linux"; OS_ID="alpine"; OS_VER="$(cat /etc/alpine-release)"
    elif [[ -f /etc/openwrt_release ]]; then
        OS="OpenWrt"; OS_ID="openwrt"
    else
        OS="$(uname -s)"; OS_ID="unknown"
    fi

    # ---------- 架构 ----------
    local raw_arch
    raw_arch="$(uname -m)"
    case "$raw_arch" in
        x86_64)             ARCH="amd64" ;;
        aarch64|arm64)      ARCH="arm64" ;;
        armv7l|armhf|armv7) ARCH="arm"   ;;
        i386|i686)          ARCH="386"   ;;
        *)                  ARCH="$raw_arch"; log_warn "未识别架构 $raw_arch, 保持原值" ;;
    esac

    # ---------- 包管理器 ----------
    if   command -v apt-get  &>/dev/null; then PKG_MGR="apt"
    elif command -v dnf      &>/dev/null; then PKG_MGR="dnf"
    elif command -v yum      &>/dev/null; then PKG_MGR="yum"
    elif command -v pacman   &>/dev/null; then PKG_MGR="pacman"
    elif command -v zypper   &>/dev/null; then PKG_MGR="zypper"
    elif command -v apk      &>/dev/null; then PKG_MGR="apk"
    elif command -v opkg     &>/dev/null; then PKG_MGR="opkg"
    else
        log_warn "未检测到已知包管理器, 跳过依赖安装"
        PKG_MGR="none"
    fi

    # ---------- Init 系统 ----------
    if _systemd_works; then
        INIT_SYSTEM="systemd"
    elif command -v rc-service &>/dev/null && [[ -d /etc/init.d ]]; then
        INIT_SYSTEM="openrc"
    elif [[ -d /etc/init.d ]] || command -v service &>/dev/null; then
        INIT_SYSTEM="sysvinit"
    else
        INIT_SYSTEM="none"
        log_warn "未检测到任何 init 系统, 仅安装二进制, 不注册自启"
    fi

    echo ""
    divider
    log_info "系统信息检测:"
    log_info "  操作系统:   ${BOLD}${OS}${NC}  ${OS_VER}"
    log_info "  系统标识:   ${OS_ID}"
    log_info "  架构:       ${ARCH}"
    log_info "  包管理器:   ${PKG_MGR}"
    log_info "  Init 系统:  ${BOLD}${INIT_SYSTEM}${NC}"
    log_info "  内核版本:   $(uname -r)"
    divider
}

# 检测 systemd 是否真正可用 (排除容器假阳性)
_systemd_works() {
    [[ -d /run/systemd/system ]] && return 0
    command -v systemctl &>/dev/null && systemctl is-system-running &>/dev/null 2>&1 && return 0
    return 1
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_warn "需要 root 权限, 自动切换 sudo..."
        exec sudo bash "$0" "$@"
    fi
}

# ---------- 自动从已安装的 cloudflared 提取 Token ----------
_auto_extract_cf_token() {
    local token=""

    # 1) 我们之前存的配置文件
    if [[ -f "${CONF_DIR}/cloudflared.conf" ]]; then
        token="$(grep -oP 'CLOUDFLARED_TOKEN=\K.*' "${CONF_DIR}/cloudflared.conf" 2>/dev/null)"
    fi

    # 2) cloudflared 自身的 service 配置 (systemd 会生成)
    if [[ -z "$token" ]] && [[ -f /etc/systemd/system/cloudflared.service ]]; then
        token="$(grep -oP -- '--token\s+\K\S+' /etc/systemd/system/cloudflared.service 2>/dev/null)"
    fi

    # 3) init.d 脚本中
    if [[ -z "$token" ]] && [[ -f /etc/init.d/cloudflared ]]; then
        token="$(grep -oP -- '--token\s+\K\S+' /etc/init.d/cloudflared 2>/dev/null)"
        # 也可能是从 conf 文件 source 的
        if [[ -z "$token" ]] && grep -q 'cloudflared.conf' /etc/init.d/cloudflared 2>/dev/null; then
            token="$(grep -oP 'CLOUDFLARED_TOKEN=\K.*' "${CONF_DIR}/cloudflared.conf" 2>/dev/null)"
        fi
    fi

    # 4) cloudflared 内部配置目录
    if [[ -z "$token" ]] && [[ -d /etc/cloudflared ]]; then
        token="$(grep -rhoP '"token":\s*"\K[^"]+' /etc/cloudflared/ 2>/dev/null | head -1)"
    fi

    if [[ -n "$token" ]]; then
        CLOUDFLARED_TOKEN="$token"
        log_success "已自动提取 Cloudflared Token (${#token} 字符)"
        return 0
    fi
    return 1
}

# ---------- Token 清洗: 从各种格式中提取真正的 base64 token ----------
_sanitize_cf_token() {
    local raw="$1"
    local token=""

    # 尝试提取: 找最长的 base64url 字符串 (eyJ... 或类似)
    # 支持用户粘贴: "cloudflared.exe service install eyJ..." / "cloudflared tunnel run --token eyJ..." / 纯 token
    token="$(echo "$raw" | grep -oP 'eyJ[A-Za-z0-9_\-+/=]{50,}' | head -1)"

    if [[ -n "$token" ]]; then
        CLOUDFLARED_TOKEN="$token"
        return 0
    fi

    # 如果没找到 eyJ 开头的, 尝试提取最后一个长单词 (可能是其他格式的 token)
    token="$(echo "$raw" | awk '{print $NF}')"
    if [[ ${#token} -ge 50 ]]; then
        CLOUDFLARED_TOKEN="$token"
        return 0
    fi

    # 原样返回
    CLOUDFLARED_TOKEN="$raw"
    return 1
}

# ---------- 交互式: 选择服务 + 输入 Token ----------
interactive_prompt() {
    echo ""
    echo -e "${CYAN}${BOLD}请选择要安装的服务 (直接回车 = 全部安装):${NC}"
    echo ""
    echo -e "  ${GREEN}1${NC}) Cloudflared Tunnel   — Cloudflare 内网穿透隧道"
    echo -e "  ${GREEN}2${NC}) Lucky (幸运加速)      — DDNS / 端口转发 / 反向代理"
    echo -e "  ${GREEN}3${NC}) 3x-ui (X-UI 面板)    — 多协议代理面板"
    echo ""
    echo -e "  输入编号, 多选逗号分隔 (如 ${BOLD}1,3${NC}), 或直接回车全选"
    echo ""
    read -rp "$(echo -e "${BLUE}[选择]${NC} ")" choice

    if [[ -n "$choice" ]]; then
        INSTALL_CF=false
        INSTALL_LUCKY=false
        INSTALL_3XUI=false

        # 解析选择 (支持 1,3 或 1 3 或 1,2,3 等格式)
        choice="${choice// /,}"
        IFS=',' read -ra items <<< "$choice"
        for item in "${items[@]}"; do
            case "$item" in
                1) INSTALL_CF=true ;;
                2) INSTALL_LUCKY=true ;;
                3) INSTALL_3XUI=true ;;
                *) log_warn "忽略未知选项: $item" ;;
            esac
        done
    fi

    # 显示已选服务
    echo ""
    log_info "已选服务:"
    $INSTALL_CF    && log_success "  Cloudflared Tunnel"
    $INSTALL_LUCKY && log_success "  Lucky (幸运加速)"
    $INSTALL_3XUI  && log_success "  3x-ui (X-UI 面板)"
    echo ""

    # 如果选了 Cloudflared, 先尝试自动提取 Token
    if $INSTALL_CF; then
        if _auto_extract_cf_token; then
            echo ""
            read -rp "$(echo -e "${BLUE}[确认]${NC} 使用此 Token? (Y/n/输入新Token): ")" token_choice
            case "$token_choice" in
                ""|[Yy]*)
                    # 使用已提取的 token
                    ;;
                [Nn]*)
                    INSTALL_CF=false
                    log_warn "已跳过 Cloudflared"
                    ;;
                *)
                    # 用户输入了新 token, 自动清洗
                    _sanitize_cf_token "$token_choice"
                    log_success "Token 已更新 (${#CLOUDFLARED_TOKEN} 字符)"
                    ;;
            esac
        else
            echo -e "${CYAN}请输入 Cloudflared Tunnel Token:${NC}"
            echo -e "(获取方式: Cloudflare Zero Trust Dashboard → Networks → Tunnels → 复制 token)"
            echo -e "${YELLOW}提示: 可以直接粘贴整条命令, 脚本会自动提取 token${NC}"
            echo ""
            read -rp "$(echo -e "${BLUE}[Token]${NC} ")" raw_token

            if [[ -z "$raw_token" ]]; then
                log_warn "未输入 Token, 将跳过 Cloudflared 安装"
                INSTALL_CF=false
            else
                # 自动清洗: 从 "cloudflared.exe service install eyJ..." 中提取 token
                if _sanitize_cf_token "$raw_token"; then
                    log_info "已自动提取 Token (原始输入 ${#raw_token} 字符 → 清洗后 ${#CLOUDFLARED_TOKEN} 字符)"
                fi
                log_success "Token 已接收 (${#CLOUDFLARED_TOKEN} 字符)"
            fi
        fi
    fi

    echo ""
    divider
}

# ============================================================================
#                     统一服务管理抽象层
# ============================================================================

svc_daemon_reload() {
    [[ "$INIT_SYSTEM" == "systemd" ]] && systemctl daemon-reload 2>/dev/null
    return 0
}

svc_enable() {
    local name="$1"
    case "$INIT_SYSTEM" in
        systemd)
            systemctl enable "$name" 2>/dev/null || true
            ;;
        sysvinit)
            if command -v update-rc.d &>/dev/null; then
                update-rc.d "$name" defaults 2>/dev/null || true
            elif command -v chkconfig &>/dev/null; then
                chkconfig --add "$name" 2>/dev/null || true
                chkconfig "$name" on 2>/dev/null || true
            elif command -v insserv &>/dev/null; then
                insserv "$name" 2>/dev/null || true
            else
                _add_to_rc_local "$name"
            fi
            ;;
        openrc)
            rc-update add "$name" default 2>/dev/null || true
            ;;
    esac
}

svc_start() {
    local name="$1"
    case "$INIT_SYSTEM" in
        systemd)  systemctl start "$name" 2>/dev/null ;;
        sysvinit)
            if command -v service &>/dev/null; then
                service "$name" start 2>/dev/null
            elif [[ -x "/etc/init.d/$name" ]]; then
                "/etc/init.d/$name" start 2>/dev/null
            fi
            ;;
        openrc)   rc-service "$name" start 2>/dev/null ;;
    esac
}

svc_restart() {
    local name="$1"
    case "$INIT_SYSTEM" in
        systemd)  systemctl restart "$name" 2>/dev/null ;;
        sysvinit)
            if command -v service &>/dev/null; then
                service "$name" restart 2>/dev/null
            elif [[ -x "/etc/init.d/$name" ]]; then
                "/etc/init.d/$name" restart 2>/dev/null
            fi
            ;;
        openrc)   rc-service "$name" restart 2>/dev/null ;;
    esac
}

svc_stop() {
    local name="$1"
    case "$INIT_SYSTEM" in
        systemd)  systemctl stop "$name" 2>/dev/null ;;
        sysvinit)
            if command -v service &>/dev/null; then
                service "$name" stop 2>/dev/null
            elif [[ -x "/etc/init.d/$name" ]]; then
                "/etc/init.d/$name" stop 2>/dev/null
            fi
            ;;
        openrc)   rc-service "$name" stop 2>/dev/null ;;
    esac
}

# 返回 0 = 运行中, 1 = 未运行
# 使用精确二进制路径匹配, 避免 pgrep 误判
svc_status() {
    local name="$1"
    local bin_path="$2"  # 可选: 传入精确二进制路径

    case "$INIT_SYSTEM" in
        systemd)
            systemctl is-active --quiet "$name" 2>/dev/null
            ;;
        sysvinit|openrc)
            # 方法1: PID 文件 + 验证 PID 确实属于目标进程
            if [[ -f "/var/run/${name}.pid" ]]; then
                local pid
                pid="$(cat "/var/run/${name}.pid" 2>/dev/null)"
                if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
                    # 进一步验证: 检查 /proc/<pid>/exe 是否指向正确二进制
                    if [[ -n "$bin_path" ]] && [[ -L "/proc/${pid}/exe" ]]; then
                        local real_exe
                        real_exe="$(readlink -f "/proc/${pid}/exe" 2>/dev/null)"
                        if [[ "$real_exe" == *"$bin_path"* ]] || [[ "$(basename "$real_exe")" == "$(basename "$bin_path")" ]]; then
                            return 0
                        fi
                        # PID 文件存在但指向错误进程 → 残留 pidfile
                        rm -f "/var/run/${name}.pid" 2>/dev/null
                    else
                        # 无法验证 exe (容器/权限限制), 信任 PID
                        return 0
                    fi
                else
                    # PID 无效, 清理残留
                    rm -f "/var/run/${name}.pid" 2>/dev/null
                fi
            fi
            # 方法2: init.d status 命令
            if [[ -x "/etc/init.d/$name" ]]; then
                if "/etc/init.d/$name" status &>/dev/null; then
                    return 0
                fi
            fi
            # 方法3: pgrep 精确匹配二进制名 + 验证 exe 路径
            if [[ -n "$bin_path" && -x "$bin_path" ]]; then
                local matched_pids
                matched_pids="$(pgrep -x "$(basename "$bin_path")" 2>/dev/null)"
                if [[ -n "$matched_pids" ]]; then
                    while IFS= read -r mpid; do
                        if [[ -L "/proc/${mpid}/exe" ]]; then
                            local real_exe
                            real_exe="$(readlink -f "/proc/${mpid}/exe" 2>/dev/null)"
                            if [[ "$real_exe" == *"$bin_path"* ]] || [[ "$(basename "$real_exe")" == "$(basename "$bin_path")" ]]; then
                                return 0
                            fi
                        else
                            # 无法读取 exe (容器限制), 信任 pgrep
                            return 0
                        fi
                    done <<< "$matched_pids"
                fi
            fi
            return 1
            ;;
        *)
            # 无 init 系统: 直接查进程 + 验证 exe
            if [[ -n "$bin_path" && -x "$bin_path" ]]; then
                local matched_pids
                matched_pids="$(pgrep -x "$(basename "$bin_path")" 2>/dev/null)"
                if [[ -n "$matched_pids" ]]; then
                    while IFS= read -r mpid; do
                        if [[ -L "/proc/${mpid}/exe" ]]; then
                            local real_exe
                            real_exe="$(readlink -f "/proc/${mpid}/exe" 2>/dev/null)"
                            if [[ "$real_exe" == *"$bin_path"* ]] || [[ "$(basename "$real_exe")" == "$(basename "$bin_path")" ]]; then
                                return 0
                            fi
                        else
                            return 0
                        fi
                    done <<< "$matched_pids"
                fi
            fi
            return 1
            ;;
    esac
}

# ---------- 直接启动 (绕过 init.d, 用于降级兜底) ----------
# 用法: _direct_start <服务名> <二进制路径> <工作目录|-> [启动参数...]
#   工作目录传 "-" 表示不切换目录
_direct_start() {
    local name="$1" bin="$2" workdir="$3"
    shift 3
    local args=("$@")
    local pidfile="/var/run/${name}.pid"
    local logfile="/var/log/${name}.log"

    # 清理残留
    pkill -x "$name" 2>/dev/null
    sleep 1

    log_info "尝试直接启动 ${name} (nohup 模式)..."

    if [[ "$workdir" != "-" && -d "$workdir" ]]; then
        # 需要指定工作目录 (3x-ui 等依赖相对路径的程序)
        (cd "$workdir" && nohup "$bin" "${args[@]}" >> "$logfile" 2>&1 &)
        sleep 1
        # 子 shell 里拿不到 PID, 用 pgrep 补
        pgrep -x "$(basename "$bin")" | head -1 > "$pidfile" 2>/dev/null
    else
        nohup "$bin" "${args[@]}" >> "$logfile" 2>&1 &
        local pid=$!
        echo "$pid" > "$pidfile"
    fi

    sleep 3
    # 检查进程是否存活
    local pid
    pid="$(cat "$pidfile" 2>/dev/null)"
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
        log_success "${name} 直接启动成功 (PID: ${pid})"
        return 0
    fi
    # 也试试 pgrep 兜底
    if pgrep -x "$(basename "$bin")" &>/dev/null; then
        pgrep -x "$(basename "$bin")" | head -1 > "$pidfile"
        log_success "${name} 直接启动成功 (PID: $(cat "$pidfile"))"
        return 0
    fi

    log_error "${name} 直接启动也失败了"
    if [[ -s "$logfile" ]]; then
        tail -5 "$logfile" 2>/dev/null | while IFS= read -r line; do echo "    $line"; done
    fi
    rm -f "$pidfile"
    return 1
}

# 写入 /etc/rc.local 作为最后的自启兜底
_add_to_rc_local() {
    local name="$1"
    local rc_local="/etc/rc.local"

    if [[ ! -f "$rc_local" ]]; then
        printf '#!/bin/sh\n# rc.local\nexit 0\n' > "$rc_local"
        chmod +x "$rc_local"
    fi

    if ! grep -q "/etc/init.d/${name}" "$rc_local" 2>/dev/null; then
        # 兼容无 -i 的 sed (虽然 Linux 一般都有 GNU sed)
        if grep -q "^exit 0" "$rc_local" 2>/dev/null; then
            sed -i "/^exit 0/i /etc/init.d/${name} start" "$rc_local" 2>/dev/null || \
                echo "/etc/init.d/${name} start" >> "$rc_local"
        else
            echo "/etc/init.d/${name} start" >> "$rc_local"
        fi
    fi
}

# ============================================================================
#                  通用 init.d 脚本生成 (跨发行版)
# ============================================================================

# 用法: _gen_initd_script <服务名> <描述> <可执行文件路径> <启动参数> <PID文件> [工作目录]
# 始终使用 nohup + shell 重定向, 最可靠, 日志一定能写入
_gen_initd_script() {
    local name="$1" desc="$2" bin="$3" args="$4" pidfile="$5"
    local workdir="${6:-}"
    local script="/etc/init.d/${name}"

    # 如果有工作目录, 在启动前 cd 过去
    local cd_prefix=""
    if [[ -n "$workdir" ]]; then
        cd_prefix="cd ${workdir} && "
    fi

    cat > "$script" << INITD_EOF
#!/bin/sh
### BEGIN INIT INFO
# Provides:          ${name}
# Required-Start:    \$network \$remote_fs \$syslog
# Required-Stop:     \$network \$remote_fs \$syslog
# Default-Start:     2 3 4 5
# Default-Stop:      0 1 6
# Short-Description: ${desc}
### END INIT INFO

NAME="${name}"
DAEMON="${bin}"
DAEMON_ARGS="${args}"
PIDFILE="${pidfile}"
LOGFILE="/var/log/\${NAME}.log"
DESC="${desc}"
WORKDIR="${workdir}"

_is_running() {
    if [ -f "\$PIDFILE" ]; then
        local pid
        pid=\$(cat "\$PIDFILE" 2>/dev/null)
        if [ -n "\$pid" ] && kill -0 "\$pid" 2>/dev/null; then
            return 0
        fi
        rm -f "\$PIDFILE"
    fi
    return 1
}

do_start() {
    if _is_running; then
        echo "\$NAME is already running (PID: \$(cat \$PIDFILE))"
        return 0
    fi

    # 清理可能残留的同名进程
    pkill -x "\$NAME" 2>/dev/null
    sleep 1

    echo "Starting \$DESC: \$NAME"

    # 直接后台运行, stdout+stderr 都写入日志
    if [ -n "\$WORKDIR" ] && [ -d "\$WORKDIR" ]; then
        cd "\$WORKDIR" || exit 1
    fi
    nohup "\$DAEMON" \$DAEMON_ARGS >> "\$LOGFILE" 2>&1 &
    local pid=\$!
    echo \$pid > "\$PIDFILE"

    # 启动后验证: 等 3 秒确认进程没有立即崩溃
    sleep 3
    if kill -0 "\$pid" 2>/dev/null; then
        return 0
    fi
    # 进程已死, 输出日志帮助排查
    echo "ERROR: \$NAME 启动后退出 (PID \$pid 已不存在), 最近日志:"
    if [ -s "\$LOGFILE" ]; then
        tail -10 "\$LOGFILE" 2>/dev/null
    else
        echo "(日志文件为空, 进程可能在启动瞬间就退出了)"
    fi
    rm -f "\$PIDFILE"
    return 1
}

do_stop() {
    if ! _is_running; then
        echo "\$NAME is not running"
        pkill -x "\$NAME" 2>/dev/null
        return 0
    fi
    echo "Stopping \$DESC: \$NAME"
    local pid
    pid=\$(cat "\$PIDFILE" 2>/dev/null)
    kill "\$pid" 2>/dev/null
    local i=0
    while [ \$i -lt 10 ] && kill -0 "\$pid" 2>/dev/null; do
        sleep 1; i=\$((i+1))
    done
    if kill -0 "\$pid" 2>/dev/null; then
        kill -9 "\$pid" 2>/dev/null
    fi
    rm -f "\$PIDFILE"
    return 0
}

do_status() {
    if _is_running; then
        echo "\$NAME is running (PID: \$(cat \$PIDFILE))"
        return 0
    fi
    echo "\$NAME is not running"
    return 1
}

case "\$1" in
    start)   do_start   ;;
    stop)    do_stop    ;;
    restart) do_stop; sleep 1; do_start ;;
    status)  do_status  ;;
    *)
        echo "Usage: \$0 {start|stop|restart|status}"
        exit 1
        ;;
esac
exit \$?
INITD_EOF

    chmod +x "$script"
}

# ============================================================================
#                          依赖安装
# ============================================================================

install_dependencies() {
    log_step "安装基础依赖"

    if [[ "$PKG_MGR" == "none" ]]; then
        log_warn "无包管理器, 跳过依赖安装"
        return 0
    fi

    case "$PKG_MGR" in
        apt)
            apt-get update -qq
            apt-get install -y -qq curl wget unzip ca-certificates lsb-release procps > /dev/null 2>&1
            ;;
        dnf)
            dnf install -y -q curl wget unzip ca-certificates procps-ng > /dev/null 2>&1
            ;;
        yum)
            yum install -y -q curl wget unzip ca-certificates procps-ng > /dev/null 2>&1
            ;;
        pacman)
            pacman -Sy --noconfirm --quiet curl wget unzip ca-certificates procps-ng > /dev/null 2>&1
            ;;
        zypper)
            zypper --non-quiet install -y curl wget unzip ca-certificates procps > /dev/null 2>&1
            ;;
        apk)
            apk add --quiet --no-cache curl wget unzip ca-certificates procps > /dev/null 2>&1
            ;;
        opkg)
            opkg update >/dev/null 2>&1
            opkg install curl wget unzip ca-certificates procps-ng > /dev/null 2>&1 || \
            opkg install curl wget unzip ca-certificates procps > /dev/null 2>&1
            ;;
    esac

    log_success "基础依赖安装完成 (${PKG_MGR})"
}

# ============================================================================
#                     1. Cloudflared Tunnel
# ============================================================================

# 将 token 存入独立配置文件, 权限 600, 不暴露在 init.d 脚本中
_save_cloudflared_token() {
    mkdir -p "$CONF_DIR"
    cat > "${CONF_DIR}/cloudflared.conf" << CEOF
# Cloudflared Tunnel Token — 由 setup.sh 生成, 请勿泄露
CLOUDFLARED_TOKEN=${CLOUDFLARED_TOKEN}
CEOF
    chmod 600 "${CONF_DIR}/cloudflared.conf"
}

install_cloudflared() {
    log_step "1/3  安装 Cloudflared"

    # ---------- 安装二进制 ----------
    if command -v cloudflared &>/dev/null; then
        local current_ver
        current_ver="$(cloudflared --version 2>&1 | head -1)"
        log_info "Cloudflared 已安装: ${current_ver}"
    else
        log_info "正在下载 Cloudflared (${ARCH})..."

        local cf_url=""
        case "$ARCH" in
            amd64)  cf_url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64" ;;
            arm64)  cf_url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64" ;;
            arm)    cf_url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm" ;;
            386)    cf_url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-386" ;;
            *)      log_error "不支持的架构: $ARCH"; return 1 ;;
        esac

        if ! download_retry "$cf_url" /usr/local/bin/cloudflared; then
            log_error "Cloudflared 下载失败"; return 1
        fi
        chmod +x /usr/local/bin/cloudflared

        if cloudflared --version &>/dev/null; then
            log_success "Cloudflared 安装成功: $(cloudflared --version 2>&1)"
        else
            log_error "Cloudflared 二进制执行失败"; return 1
        fi
    fi

    # ---------- 保存 token 到安全配置文件 ----------
    _save_cloudflared_token
    log_info "Token 已存入 ${CONF_DIR}/cloudflared.conf (权限 600)"

    # ---------- 注册服务 ----------
    log_info "正在注册 Cloudflared Tunnel 服务..."

    case "$INIT_SYSTEM" in
        systemd)
            # cloudflared service install 原生支持 systemd
            if cloudflared service install "$CLOUDFLARED_TOKEN" 2>&1; then
                log_success "Cloudflared systemd 服务注册成功"
            else
                log_warn "cloudflared service install 失败, 手动创建 unit 文件..."
                _gen_cloudflared_systemd
            fi
            ;;
        sysvinit)
            # 生成 init.d 脚本, 从配置文件读 token, 不硬编码
            _gen_cloudflared_sysvinit
            log_success "Cloudflared SysVinit 脚本已生成 (/etc/init.d/cloudflared)"
            ;;
        openrc)
            _gen_cloudflared_openrc
            log_success "Cloudflared OpenRC 脚本已生成"
            ;;
        *)
            log_warn "无 init 系统, 仅安装二进制, 请手动启动"
            ;;
    esac

    # ---------- 启动 ----------
    svc_daemon_reload
    svc_enable cloudflared
    svc_stop cloudflared 2>/dev/null
    sleep 1

    # 先尝试 init.d 启动
    local start_rc=0
    if [[ "$INIT_SYSTEM" == "sysvinit" || "$INIT_SYSTEM" == "openrc" ]]; then
        "/etc/init.d/cloudflared" start || start_rc=$?
    else
        svc_start cloudflared || start_rc=$?
    fi

    if (( start_rc != 0 )); then
        # init.d 失败, 降级: 直接用 nohup 启动
        log_warn "init.d 启动失败, 尝试直接启动..."
        _direct_start cloudflared /usr/local/bin/cloudflared - \
            tunnel --no-autoupdate run --token "$CLOUDFLARED_TOKEN"
    else
        # init.d 启动成功, 再做一轮快速确认
        sleep 2
        if svc_status cloudflared /usr/local/bin/cloudflared; then
            log_success "Cloudflared 服务运行正常"
        else
            log_error "Cloudflared 启动后进程消失"
            [[ -f /var/log/cloudflared.log ]] && tail -10 /var/log/cloudflared.log 2>/dev/null | while IFS= read -r line; do echo "    $line"; done
        fi
    fi
}

# SysVinit: init.d 脚本 + 独立 conf 文件存 token
_gen_cloudflared_sysvinit() {
    local script="/etc/init.d/cloudflared"

    cat > "$script" << 'INITD_EOF'
#!/bin/sh
### BEGIN INIT INFO
# Provides:          cloudflared
# Required-Start:    $network $remote_fs $syslog
# Required-Stop:     $network $remote_fs $syslog
# Default-Start:     2 3 4 5
# Default-Stop:      0 1 6
# Short-Description: Cloudflared Tunnel
### END INIT INFO

NAME="cloudflared"
DAEMON="/usr/local/bin/cloudflared"
PIDFILE="/var/run/cloudflared.pid"
DESC="Cloudflared Tunnel"
CONF_FILE="/etc/services-deploy/cloudflared.conf"
LOGFILE="/var/log/cloudflared.log"

# 从配置文件加载 token
if [ -f "$CONF_FILE" ]; then
    . "$CONF_FILE"
else
    echo "ERROR: Token 配置文件不存在: $CONF_FILE"
    exit 1
fi

DAEMON_ARGS="tunnel --no-autoupdate run --token ${CLOUDFLARED_TOKEN}"

# 始终使用直接后台 + shell 重定向, 最可靠且日志一定能写入
# start-stop-daemon --stdout/--stderr 搭配 --exec 在某些系统上重定向不生效

_is_running() {
    if [ -f "$PIDFILE" ]; then
        local pid
        pid=$(cat "$PIDFILE" 2>/dev/null)
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            return 0
        fi
        rm -f "$PIDFILE"
    fi
    return 1
}

do_start() {
    if _is_running; then
        echo "$NAME is already running (PID: $(cat $PIDFILE))"
        return 0
    fi

    # 清理可能残留的同名进程
    pkill -x "$NAME" 2>/dev/null
    sleep 1

    echo "Starting $DESC: $NAME"

    # 直接后台运行, stdout+stderr 都写入日志
    nohup "$DAEMON" $DAEMON_ARGS >> "$LOGFILE" 2>&1 &
    local pid=$!
    echo $pid > "$PIDFILE"

    # 启动后验证: 等 3 秒确认进程没有立即崩溃
    sleep 3
    if kill -0 "$pid" 2>/dev/null; then
        return 0
    fi
    # 进程已死, 输出日志帮助排查
    echo "ERROR: $NAME 启动后退出 (PID $pid 已不存在), 最近日志:"
    if [ -s "$LOGFILE" ]; then
        tail -10 "$LOGFILE" 2>/dev/null
    else
        echo "(日志文件为空, 进程可能在启动瞬间就退出了)"
    fi
    rm -f "$PIDFILE"
    return 1
}

do_stop() {
    if ! _is_running; then
        echo "$NAME is not running"
        # 兜底: 杀掉所有残留 cloudflared 进程
        pkill -x "$NAME" 2>/dev/null
        return 0
    fi
    echo "Stopping $DESC: $NAME"
    local pid
    pid=$(cat "$PIDFILE" 2>/dev/null)
    kill "$pid" 2>/dev/null
    local i=0
    while [ $i -lt 10 ] && kill -0 "$pid" 2>/dev/null; do
        sleep 1; i=$((i+1))
    done
    # 如果还没死, 强制杀
    if kill -0 "$pid" 2>/dev/null; then
        kill -9 "$pid" 2>/dev/null
    fi
    rm -f "$PIDFILE"
    return 0
}

do_status() {
    if _is_running; then
        echo "$NAME is running (PID: $(cat $PIDFILE))"
        return 0
    fi
    echo "$NAME is not running"
    return 1
}

case "$1" in
    start)   do_start   ;;
    stop)    do_stop    ;;
    restart) do_stop; sleep 1; do_start ;;
    status)  do_status  ;;
    *) echo "Usage: $0 {start|stop|restart|status}"; exit 1 ;;
esac
exit $?
INITD_EOF

    chmod +x "$script"
}

_gen_cloudflared_systemd() {
    cat > /etc/systemd/system/cloudflared.service << 'EOF'
[Unit]
Description=Cloudflared Tunnel
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=/etc/services-deploy/cloudflared.conf
ExecStart=/usr/local/bin/cloudflared --no-autoupdate tunnel run --token ${CLOUDFLARED_TOKEN}
Restart=always
RestartSec=5
TimeoutStartSec=0
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF
}

_gen_cloudflared_openrc() {
    cat > /etc/init.d/cloudflared << 'EOF'
#!/sbin/openrc-run

description="Cloudflared Tunnel"
command="/usr/local/bin/cloudflared"
command_background=true
pidfile="/var/run/cloudflared.pid"
retry="SIGTERM 10"

depend() {
    need net
    after firewall
}

start_pre() {
    # 从配置文件加载 token
    if [ -f /etc/services-deploy/cloudflared.conf ]; then
        . /etc/services-deploy/cloudflared.conf
        command_args="tunnel --no-autoupdate run --token ${CLOUDFLARED_TOKEN}"
    else
        eerror "Token 配置文件不存在: /etc/services-deploy/cloudflared.conf"
        return 1
    fi
}
EOF
    chmod +x /etc/init.d/cloudflared
}

# ============================================================================
#                     2. Lucky (幸运加速)
# ============================================================================

install_lucky() {
    log_step "2/3  安装 Lucky (幸运加速)"

    # ---------- 尝试定位已有的二进制 (含官方脚本装到非标准路径的情况) ----------
    if ! command -v lucky &>/dev/null && [[ ! -f /usr/local/bin/lucky ]]; then
        _link_lucky_binary 2>/dev/null || true
    fi

    # ---------- 如果仍然没有, 执行安装 ----------
    if ! command -v lucky &>/dev/null && [[ ! -f /usr/local/bin/lucky ]]; then
        log_info "正在下载并安装 Lucky..."

        local LUCKY_URL="http://release.66666.host"
        local INSTALL_SCRIPT="/tmp/lucky_install_$$.sh"
        TMP_FILES+=("$INSTALL_SCRIPT")

        if download_retry "${LUCKY_URL}/install.sh" "$INSTALL_SCRIPT"; then
            chmod +x "$INSTALL_SCRIPT"
            if sh "$INSTALL_SCRIPT" "$LUCKY_URL" 2>&1; then
                log_success "Lucky 安装成功 (官方脚本)"
                _link_lucky_binary
            else
                log_warn "官方脚本安装失败, 尝试备用方案..."
                _install_lucky_manual
            fi
        else
            log_warn "无法下载 Lucky 官方安装脚本, 尝试备用方案..."
            _install_lucky_manual
        fi
    else
        log_info "Lucky 已安装, 跳过下载"
    fi

    # ---------- 确保有对应的服务注册 ----------
    _ensure_lucky_service

    # ---------- 启动 ----------
    svc_daemon_reload
    svc_enable lucky
    svc_stop lucky 2>/dev/null
    sleep 1

    local start_rc=0
    if [[ "$INIT_SYSTEM" == "sysvinit" || "$INIT_SYSTEM" == "openrc" ]]; then
        "/etc/init.d/lucky" start || start_rc=$?
    else
        svc_start lucky || start_rc=$?
    fi

    if (( start_rc != 0 )); then
        log_warn "init.d 启动失败, 尝试直接启动..."
        _direct_start lucky /usr/local/bin/lucky - -cd /etc/lucky
    else
        sleep 2
        if svc_status lucky /usr/local/bin/lucky; then
            log_success "Lucky 服务运行正常"
        else
            log_error "Lucky 启动后进程消失"
            [[ -f /var/log/lucky.log ]] && tail -5 /var/log/lucky.log 2>/dev/null | while IFS= read -r line; do echo "    $line"; done
        fi
    fi
}

_install_lucky_manual() {
    log_info "使用备用方案安装 Lucky..."

    local lucky_url=""
    case "$ARCH" in
        amd64) lucky_url="https://github.com/gdy666/lucky/releases/latest/download/lucky_linux_amd64" ;;
        arm64) lucky_url="https://github.com/gdy666/lucky/releases/latest/download/lucky_linux_arm64" ;;
        arm)   lucky_url="https://github.com/gdy666/lucky/releases/latest/download/lucky_linux_arm" ;;
        *)     log_error "不支持的架构: $ARCH"; return 1 ;;
    esac

    if ! download_retry "$lucky_url" /usr/local/bin/lucky; then
        log_error "Lucky 下载失败"; return 1
    fi
    chmod +x /usr/local/bin/lucky
    mkdir -p /etc/lucky /var/log/lucky

    log_success "Lucky 二进制安装完成"
}

# 官方安装脚本可能把 lucky 装到各种位置, 统一查找并建软链接到 /usr/local/bin/lucky
_link_lucky_binary() {
    # 如果已经在标准位置, 不用处理
    [[ -x /usr/local/bin/lucky ]] && return 0

    local search_paths=(
        /usr/share/lucky.daji/lucky
        /usr/share/lucky/lucky
        /etc/lucky/lucky
        /usr/local/lucky/lucky
        /opt/lucky/lucky
    )

    local found=""
    for p in "${search_paths[@]}"; do
        if [[ -x "$p" ]]; then
            found="$p"
            break
        fi
    done

    # 还没找到, 全盘搜一下
    if [[ -z "$found" ]]; then
        found="$(find /usr /etc /opt -name "lucky" -type f -executable 2>/dev/null | head -1)"
    fi

    if [[ -n "$found" ]]; then
        log_info "发现 Lucky 二进制: $found"
        ln -sf "$found" /usr/local/bin/lucky
        log_success "已创建软链接: /usr/local/bin/lucky → $found"
    else
        log_warn "未找到 Lucky 二进制文件"
        return 1
    fi
}

_ensure_lucky_service() {
    case "$INIT_SYSTEM" in
        systemd)
            if [[ ! -f /etc/systemd/system/lucky.service ]]; then
                cat > /etc/systemd/system/lucky.service << 'EOF'
[Unit]
Description=Lucky - Network Tool
After=network.target

[Service]
Type=simple
WorkingDirectory=/etc/lucky
ExecStart=/usr/local/bin/lucky -cd /etc/lucky
Restart=always
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF
                log_info "已补充生成 lucky.service"
            fi
            ;;
        sysvinit)
            if [[ ! -f /etc/init.d/lucky ]]; then
                _gen_initd_script "lucky" \
                    "Lucky Network Tool" \
                    "/usr/local/bin/lucky" \
                    "-cd /etc/lucky" \
                    "/var/run/lucky.pid"
                log_info "已生成 /etc/init.d/lucky"
            fi
            ;;
        openrc)
            if [[ ! -f /etc/init.d/lucky ]]; then
                cat > /etc/init.d/lucky << 'EOF'
#!/sbin/openrc-run

description="Lucky Network Tool"
command="/usr/local/bin/lucky"
command_args="-cd /etc/lucky"
command_background=true
pidfile="/var/run/lucky.pid"
retry="SIGTERM 10"

depend() {
    need net
}
EOF
                chmod +x /etc/init.d/lucky
                log_info "已生成 OpenRC lucky 脚本"
            fi
            ;;
    esac
}

# ============================================================================
#                     3. 3x-ui (X-UI 面板)
# ============================================================================

install_3xui() {
    log_step "3/3  安装 3x-ui (X-UI 面板)"

    # ---------- 已安装检测 ----------
    if [[ -f /usr/local/x-ui/x-ui ]]; then
        log_info "3x-ui 已安装"
        _ensure_3xui_service
        if svc_status x-ui /usr/local/x-ui/x-ui; then
            log_success "3x-ui 服务已在运行"
            return 0
        fi
        # 未运行, 尝试启动
        svc_stop x-ui 2>/dev/null
        sleep 1
        local start_rc=0
        if [[ -x /etc/init.d/x-ui ]]; then
            /etc/init.d/x-ui start || start_rc=$?
        else
            svc_start x-ui || start_rc=$?
        fi
        if (( start_rc != 0 )); then
            _direct_start x-ui /usr/local/x-ui/x-ui /usr/local/x-ui
        elif svc_status x-ui /usr/local/x-ui/x-ui; then
            log_success "3x-ui 服务已启动"
        else
            log_warn "3x-ui 启动后进程消失, 请检查日志"
        fi
        return 0
    fi

    log_info "正在下载并安装 3x-ui..."

    # ---------- 下载并执行官方安装脚本 ----------
    local INSTALL_SCRIPT="/tmp/3xui_install_$$.sh"
    TMP_FILES+=("$INSTALL_SCRIPT")

    if download_retry "https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh" "$INSTALL_SCRIPT"; then
        chmod +x "$INSTALL_SCRIPT"

        log_info "执行 3x-ui 安装脚本 (自动模式)..."
        # 用 here-string 喂入 yes, 避免管道占用 stdin 导致脚本内部 read 异常
        bash "$INSTALL_SCRIPT" <<< "$(yes | head -20)" 2>&1 || true
    else
        log_error "无法下载 3x-ui 安装脚本, 请检查网络连接"
        return 1
    fi

    # ---------- 确保有服务脚本 ----------
    _ensure_3xui_service

    # ---------- 启动 ----------
    svc_daemon_reload
    svc_enable x-ui
    svc_stop x-ui 2>/dev/null
    sleep 1

    local start_rc=0
    if [[ "$INIT_SYSTEM" == "sysvinit" || "$INIT_SYSTEM" == "openrc" ]]; then
        "/etc/init.d/x-ui" start || start_rc=$?
    else
        svc_start x-ui || start_rc=$?
    fi

    if (( start_rc != 0 )); then
        log_warn "init.d 启动失败, 尝试直接启动..."
        _direct_start x-ui /usr/local/x-ui/x-ui /usr/local/x-ui
    else
        sleep 3
        if svc_status x-ui /usr/local/x-ui/x-ui; then
            log_success "3x-ui 服务运行正常"
        else
            log_error "3x-ui 启动后进程消失"
            [[ -f /var/log/x-ui.log ]] && tail -5 /var/log/x-ui.log 2>/dev/null | while IFS= read -r line; do echo "    $line"; done
        fi
    fi
}

_ensure_3xui_service() {
    case "$INIT_SYSTEM" in
        systemd)
            if [[ ! -f /etc/systemd/system/x-ui.service ]]; then
                cat > /etc/systemd/system/x-ui.service << 'EOF'
[Unit]
Description=3x-ui Panel
After=network.target

[Service]
Type=simple
WorkingDirectory=/usr/local/x-ui
ExecStart=/usr/local/x-ui/x-ui
Restart=always
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF
                log_info "已补充生成 x-ui.service"
            fi
            ;;
        sysvinit)
            if [[ ! -f /etc/init.d/x-ui ]]; then
                _gen_initd_script "x-ui" \
                    "3x-ui Panel" \
                    "/usr/local/x-ui/x-ui" \
                    "" \
                    "/var/run/x-ui.pid" \
                    "/usr/local/x-ui"
                log_info "已生成 /etc/init.d/x-ui"
            fi
            ;;
        openrc)
            if [[ ! -f /etc/init.d/x-ui ]]; then
                cat > /etc/init.d/x-ui << 'EOF'
#!/sbin/openrc-run

description="3x-ui Panel"
command="/usr/local/x-ui/x-ui"
command_background=true
pidfile="/var/run/x-ui.pid"
directory="/usr/local/x-ui"
retry="SIGTERM 10"

depend() {
    need net
}
EOF
                chmod +x /etc/init.d/x-ui
                log_info "已生成 OpenRC x-ui 脚本"
            fi
            ;;
    esac
}

# ============================================================================
#                          服务状态总览
# ============================================================================

show_status() {
    echo ""
    divider
    log_info "${BOLD}服务部署状态总览${NC}"
    divider

    _print_svc_status "Cloudflared Tunnel" "cloudflared" "/usr/local/bin/cloudflared"
    _print_svc_status "Lucky (幸运加速)"   "lucky"       "/usr/local/bin/lucky"
    _print_svc_status "3x-ui (X-UI 面板)"  "x-ui"        "/usr/local/x-ui/x-ui"

    divider
    echo ""
    log_info "管理命令 (${INIT_SYSTEM}):"
    case "$INIT_SYSTEM" in
        systemd)
            log_info "  查看状态:  systemctl status <cloudflared|lucky|x-ui>"
            log_info "  重启服务:  systemctl restart <服务名>"
            log_info "  查看日志:  journalctl -u <服务名> -f"
            ;;
        sysvinit)
            log_info "  查看状态:  /etc/init.d/<服务名> status"
            log_info "  重启服务:  /etc/init.d/<服务名> restart"
            log_info "  查看日志:  tail -f /var/log/<服务名>.log"
            ;;
        openrc)
            log_info "  查看状态:  rc-service <服务名> status"
            log_info "  重启服务:  rc-service <服务名> restart"
            ;;
        *)
            log_info "  当前无 init 系统, 请手动管理进程"
            ;;
    esac
    echo ""
}

_print_svc_status() {
    local display="$1" svc_name="$2" bin_path="$3"
    local installed=false

    # 文件存在 OR 在 PATH 中能找到, 都算已安装
    if [[ -x "$bin_path" ]] || command -v "$svc_name" &>/dev/null; then
        installed=true
    fi

    printf "  %-22s : " "$display"
    if $installed; then
        if svc_status "$svc_name" "$bin_path"; then
            echo -e "${GREEN}● 运行中${NC}"
        else
            echo -e "${YELLOW}● 已安装 (未运行)${NC}"
            # 尝试显示最近日志错误, 帮助排查
            local logfile="/var/log/${svc_name}.log"
            if [[ -f "$logfile" ]]; then
                local last_err
                last_err="$(grep -i 'error\|fail\|fatal\|panic' "$logfile" 2>/dev/null | tail -1)"
                if [[ -n "$last_err" ]]; then
                    echo -e "    ${RED}└ 最近错误: ${last_err:0:80}${NC}"
                fi
            fi
        fi
    else
        echo -e "${RED}● 未安装${NC}"
    fi
}

# ============================================================================
#                          主流程
# ============================================================================

main() {
    echo ""
    echo -e "${CYAN}${BOLD}"
    echo "  ╔══════════════════════════════════════════════╗"
    echo "  ║       多服务一键部署脚本  v${SCRIPT_VERSION}           ║"
    echo "  ║  Cloudflared · Lucky · 3x-ui                ║"
    echo "  ╚══════════════════════════════════════════════╝"
    echo -e "${NC}"

    check_root
    interactive_prompt
    detect_os
    check_disk_space
    check_network
    install_dependencies

    # 根据用户选择安装服务
    if $INSTALL_CF; then
        install_cloudflared
    else
        log_info "跳过 Cloudflared (未选择)"
    fi

    if $INSTALL_LUCKY; then
        install_lucky
    else
        log_info "跳过 Lucky (未选择)"
    fi

    if $INSTALL_3XUI; then
        install_3xui
    else
        log_info "跳过 3x-ui (未选择)"
    fi

    show_status

    log_success "${BOLD}全部服务部署完成!${NC}"
    echo ""
}

main "$@"
