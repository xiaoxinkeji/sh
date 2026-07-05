#!/usr/bin/env bash
# ============================================================================
#  多服务一键部署脚本  v2.0.0
#  集成: Cloudflared Tunnel / Lucky(幸运加速) / 3x-ui (X-UI)
#
#  Init 支持: systemd / sysvinit / OpenRC
#  发行版:    Ubuntu Debian CentOS RHEL Fedora Arch Alpine OpenWrt openSUSE
#  架构:      amd64 arm64 arm 386
#
#  用法: sudo bash setup.sh <cloudflared_token>
# ============================================================================

set -uo pipefail

# ========================== 全局变量 ==========================
SCRIPT_VERSION="2.0.0"
CLOUDFLARED_TOKEN="${1:-}"

# 颜色
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

# ========================== 日志函数 ==========================
log_info()    { echo -e "${BLUE}[INFO]${NC}  $*"; }
log_success() { echo -e "${GREEN}[ OK ]${NC} $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error()   { echo -e "${RED}[FAIL]${NC} $*"; }
log_step()    { echo -e "\n${CYAN}${BOLD}━━━ $* ━━━${NC}"; }
divider()     { echo -e "${BLUE}──────────────────────────────────────────────────────${NC}"; }

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
        x86_64)           ARCH="amd64" ;;
        aarch64|arm64)    ARCH="arm64" ;;
        armv7l|armhf|armv7) ARCH="arm" ;;
        i386|i686)        ARCH="386"   ;;
        *)                ARCH="$raw_arch"; log_warn "未识别架构 $raw_arch, 保持原值" ;;
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
        log_warn "未检测到已知包管理器, 将跳过依赖安装 (请手动确保 curl/wget 可用)"
        PKG_MGR="none"
    fi

    # ---------- Init 系统 ----------
    # 优先级: systemd > OpenRC > sysvinit
    # 注意: 某些容器/WSL 中 systemctl 存在但不可用, 需要实测
    if _systemd_works; then
        INIT_SYSTEM="systemd"
    elif command -v rc-service &>/dev/null && [[ -d /etc/init.d ]]; then
        INIT_SYSTEM="openrc"
    elif [[ -d /etc/init.d ]] || command -v service &>/dev/null; then
        INIT_SYSTEM="sysvinit"
    else
        INIT_SYSTEM="none"
        log_warn "未检测到任何 init 系统, 服务将仅安装二进制, 不注册自启"
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
    # PID 1 是 systemd 才算数
    [[ -d /run/systemd/system ]] && return 0
    # 退而检查 systemctl 是否能实际通信
    command -v systemctl &>/dev/null && systemctl is-system-running &>/dev/null 2>&1 && return 0
    return 1
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "此脚本需要 root 权限运行"
        echo "请使用: sudo bash $0 <token>"
        exit 1
    fi
}

check_args() {
    if [[ -z "$CLOUDFLARED_TOKEN" ]]; then
        log_error "缺少 Cloudflared Token 参数"
        echo ""
        echo "用法: sudo bash $0 <cloudflared_token>"
        echo "示例: sudo bash $0 eyJhIjoi..."
        echo ""
        echo "Token 获取方式:"
        echo "  1. 登录 Cloudflare Zero Trust Dashboard"
        echo "  2. Networks → Tunnels → 创建/选择 Tunnel"
        echo "  3. 复制安装命令中的 token"
        exit 1
    fi
}

# ============================================================================
#                     统一服务管理抽象层
#  屏蔽 systemd / sysvinit / openrc 差异, 对外暴露统一接口:
#    svc_enable   <name>          设置开机自启
#    svc_start    <name>          启动服务
#    svc_restart  <name>          重启服务
#    svc_stop     <name>          停止服务
#    svc_status   <name>          检查是否运行中 (返回 0/1)
#    svc_daemon_reload            重载配置 (仅 systemd 需要)
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
            # Debian 系用 update-rc.d, RedHat 系用 chkconfig
            if command -v update-rc.d &>/dev/null; then
                update-rc.d "$name" defaults 2>/dev/null || true
            elif command -v chkconfig &>/dev/null; then
                chkconfig --add "$name" 2>/dev/null || true
                chkconfig "$name" on 2>/dev/null || true
            elif command -v insserv &>/dev/null; then
                insserv "$name" 2>/dev/null || true
            else
                # 最后手段: 写入 rc.local
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
svc_status() {
    local name="$1"
    case "$INIT_SYSTEM" in
        systemd)
            systemctl is-active --quiet "$name" 2>/dev/null
            ;;
        sysvinit|openrc)
            # 优先用 service 命令
            if command -v service &>/dev/null; then
                service "$name" status &>/dev/null && return 0
            fi
            # 尝试 init.d 脚本
            if [[ -x "/etc/init.d/$name" ]]; then
                "/etc/init.d/$name" status &>/dev/null && return 0
            fi
            # 最终手段: 检查 PID 文件
            if [[ -f "/var/run/${name}.pid" ]]; then
                local pid
                pid="$(cat "/var/run/${name}.pid" 2>/dev/null)"
                [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null && return 0
            fi
            # pgrep 兜底
            pgrep -f "$name" &>/dev/null && return 0
            return 1
            ;;
        *)
            # 无 init 系统, 用进程检测
            pgrep -f "$name" &>/dev/null && return 0
            return 1
            ;;
    esac
}

# 写入 /etc/rc.local 作为最后的自启兜底
_add_to_rc_local() {
    local name="$1"
    local rc_local="/etc/rc.local"

    # 确保 rc.local 存在
    if [[ ! -f "$rc_local" ]]; then
        cat > "$rc_local" << 'RCEOF'
#!/bin/sh
# rc.local - 开机自启脚本
exit 0
RCEOF
        chmod +x "$rc_local"
    fi

    # 避免重复添加
    if ! grep -q "/etc/init.d/${name}" "$rc_local" 2>/dev/null; then
        sed -i "/^exit 0/i /etc/init.d/${name} start" "$rc_local" 2>/dev/null || \
            echo "/etc/init.d/${name} start" >> "$rc_local"
    fi
}

# ============================================================================
#                     生成 SysVinit 脚本的通用函数
# ============================================================================

# 用法: _gen_initd_script <服务名> <描述> <可执行文件路径> <启动参数> <PID文件>
_gen_initd_script() {
    local name="$1" desc="$2" bin="$3" args="$4" pidfile="$5"
    local script="/etc/init.d/${name}"

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
DESC="${desc}"
SCRIPTNAME=\$0

# 读取系统函数
if [ -f /lib/lsb/init-functions ]; then
    . /lib/lsb/init-functions
elif [ -f /etc/init.d/functions ]; then
    . /etc/init.d/functions
fi

do_start() {
    if [ -f "\$PIDFILE" ] && kill -0 \$(cat "\$PIDFILE") 2>/dev/null; then
        echo "\$NAME 已在运行"
        return 1
    fi
    echo "启动 \$DESC: \$NAME"
    start-stop-daemon --start --quiet --background --make-pidfile \\
        --pidfile "\$PIDFILE" --exec "\$DAEMON" -- \$DAEMON_ARGS
    return \$?
}

do_stop() {
    if [ ! -f "\$PIDFILE" ] || ! kill -0 \$(cat "\$PIDFILE") 2>/dev/null; then
        echo "\$NAME 未在运行"
        return 0
    fi
    echo "停止 \$DESC: \$NAME"
    start-stop-daemon --stop --quiet --pidfile "\$PIDFILE" --retry 10
    rm -f "\$PIDFILE"
    return \$?
}

do_status() {
    if [ -f "\$PIDFILE" ] && kill -0 \$(cat "\$PIDFILE") 2>/dev/null; then
        echo "\$NAME 正在运行 (PID: \$(cat \$PIDFILE))"
        return 0
    fi
    echo "\$NAME 未在运行"
    return 1
}

do_restart() {
    do_stop
    sleep 1
    do_start
}

case "\$1" in
    start)   do_start   ;;
    stop)    do_stop    ;;
    restart) do_restart ;;
    status)  do_status  ;;
    *)
        echo "用法: \$0 {start|stop|restart|status}"
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
            # Alpine Linux
            apk add --quiet --no-cache curl wget unzip ca-certificates procps > /dev/null 2>&1
            ;;
        opkg)
            # OpenWrt
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

        curl -fsSL -o /usr/local/bin/cloudflared "$cf_url"
        chmod +x /usr/local/bin/cloudflared

        if cloudflared --version &>/dev/null; then
            log_success "Cloudflared 安装成功: $(cloudflared --version 2>&1)"
        else
            log_error "Cloudflared 二进制执行失败"; return 1
        fi
    fi

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
            # 生成 /etc/init.d/cloudflared 脚本
            _gen_initd_script "cloudflared" \
                "Cloudflared Tunnel" \
                "/usr/local/bin/cloudflared" \
                "tunnel --no-autoupdate run --token ${CLOUDFLARED_TOKEN}" \
                "/var/run/cloudflared.pid"
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
    svc_restart cloudflared
    sleep 2

    if svc_status cloudflared; then
        log_success "Cloudflared 服务运行正常"
    else
        log_warn "Cloudflared 服务状态异常, 请检查日志"
    fi
}

_gen_cloudflared_systemd() {
    cat > /etc/systemd/system/cloudflared.service << 'EOF'
[Unit]
Description=Cloudflared Tunnel
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/cloudflared --no-autoupdate tunnel run
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
command_args="tunnel --no-autoupdate run"
command_background=true
pidfile="/var/run/cloudflared.pid"
retry="SIGTERM 10"

depend() {
    need net
    after firewall
}
EOF
    chmod +x /etc/init.d/cloudflared

    # OpenRC 需要 conf.d 文件传入 token
    cat > /etc/conf.d/cloudflared << CEOF
# Cloudflared Tunnel Token
command_args="\${command_args} --token ${CLOUDFLARED_TOKEN}"
CEOF
}

# ============================================================================
#                     2. Lucky (幸运加速)
# ============================================================================

install_lucky() {
    log_step "2/3  安装 Lucky (幸运加速)"

    # ---------- 已安装检测 ----------
    if command -v lucky &>/dev/null || [[ -f /usr/local/bin/lucky ]]; then
        log_info "Lucky 已安装, 跳过安装步骤"
        if svc_status lucky; then
            log_success "Lucky 服务已在运行"
            return 0
        fi
        svc_restart lucky
        return 0
    fi

    log_info "正在下载并安装 Lucky..."

    # ---------- 官方脚本安装 ----------
    local LUCKY_URL="http://release.66666.host"
    local INSTALL_SCRIPT="/tmp/lucky_install.sh"

    if curl -fsSL -o "$INSTALL_SCRIPT" "${LUCKY_URL}/install.sh" 2>/dev/null; then
        chmod +x "$INSTALL_SCRIPT"
        if sh "$INSTALL_SCRIPT" "$LUCKY_URL" 2>&1; then
            log_success "Lucky 安装成功 (官方脚本)"
        else
            log_warn "官方脚本安装失败, 尝试备用方案..."
            _install_lucky_manual
        fi
        rm -f "$INSTALL_SCRIPT"
    else
        log_warn "无法下载 Lucky 官方安装脚本, 尝试备用方案..."
        _install_lucky_manual
    fi

    # ---------- 非 systemd 系统: 确保有对应的服务脚本 ----------
    _ensure_lucky_service

    # ---------- 启动 ----------
    svc_daemon_reload
    svc_enable lucky
    svc_restart lucky
    sleep 2

    if svc_status lucky; then
        log_success "Lucky 服务运行正常"
    else
        log_warn "Lucky 服务状态异常, 请检查 /etc/init.d/lucky status 或进程"
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

    curl -fsSL -o /usr/local/bin/lucky "$lucky_url"
    chmod +x /usr/local/bin/lucky
    mkdir -p /etc/lucky /var/log/lucky

    log_success "Lucky 二进制安装完成"
}

# 根据 init 系统确保 Lucky 有对应的服务注册
_ensure_lucky_service() {
    case "$INIT_SYSTEM" in
        systemd)
            # 如果官方脚本没有创建 unit, 手动补一个
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
            # 如果 /etc/init.d/lucky 不存在, 手动生成
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
        if svc_status x-ui; then
            log_success "3x-ui 服务已在运行"
            return 0
        fi
        svc_restart x-ui
        return 0
    fi

    log_info "正在下载并安装 3x-ui..."

    # ---------- 下载并执行官方安装脚本 ----------
    local INSTALL_SCRIPT="/tmp/3xui_install.sh"
    if curl -fsSL -o "$INSTALL_SCRIPT" "https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh" 2>/dev/null; then
        chmod +x "$INSTALL_SCRIPT"

        log_info "执行 3x-ui 安装脚本 (自动模式)..."
        yes | bash "$INSTALL_SCRIPT" 2>&1 || true

        rm -f "$INSTALL_SCRIPT"
    else
        log_error "无法下载 3x-ui 安装脚本, 请检查网络连接"
        return 1
    fi

    # ---------- 非 systemd 系统: 确保有服务脚本 ----------
    _ensure_3xui_service

    # ---------- 启动 ----------
    svc_daemon_reload
    svc_enable x-ui
    svc_restart x-ui
    sleep 3

    if svc_status x-ui; then
        log_success "3x-ui 服务运行正常"
    else
        log_warn "3x-ui 服务状态异常, 请检查日志"
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
                    "/var/run/x-ui.pid"
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

    _print_svc_status "Cloudflared Tunnel" "cloudflared" "command:cloudflared"
    _print_svc_status "Lucky (幸运加速)"   "lucky"       "file:/usr/local/bin/lucky"
    _print_svc_status "3x-ui (X-UI 面板)"  "x-ui"        "file:/usr/local/x-ui/x-ui"

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
            log_info "  查看状态:  /etc/init.d/<cloudflared|lucky|x-ui> status"
            log_info "  重启服务:  /etc/init.d/<服务名> restart"
            log_info "  查看日志:  tail -f /var/log/<服务名>.log"
            ;;
        openrc)
            log_info "  查看状态:  rc-service <cloudflared|lucky|x-ui> status"
            log_info "  重启服务:  rc-service <服务名> restart"
            log_info "  查看日志:  rc-status / tail -f /var/log/<服务名>.log"
            ;;
        *)
            log_info "  当前无 init 系统, 请手动管理进程"
            ;;
    esac
    echo ""
}

# 用法: _print_svc_status <显示名> <服务名> <检测方式>
# 检测方式: command:xxx 或 file:xxx
_print_svc_status() {
    local display="$1" svc_name="$2" detect="$3"
    local installed=false

    case "${detect%%:*}" in
        command)
            command -v "${detect#command:}" &>/dev/null && installed=true
            ;;
        file)
            [[ -f "${detect#file:}" ]] && installed=true
            ;;
    esac

    printf "  %-22s : " "$display"
    if $installed; then
        if svc_status "$svc_name"; then
            echo -e "${GREEN}● 运行中${NC}"
        else
            echo -e "${YELLOW}● 已安装 (未运行)${NC}"
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
    check_args
    detect_os
    install_dependencies

    install_cloudflared
    install_lucky
    install_3xui

    show_status

    log_success "${BOLD}全部服务部署完成!${NC}"
    echo ""
}

main "$@"
