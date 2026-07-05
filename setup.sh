#!/usr/bin/env bash
# ============================================================================
#  多服务一键部署脚本
#  集成: Cloudflared Tunnel / Lucky(幸运加速) / 3x-ui (X-UI)
#  适用: 主流 Linux 发行版 (Ubuntu/Debian/CentOS/RHEL/Fedora/Arch)
#  用法: bash setup.sh <cloudflared_token>
# ============================================================================

set -euo pipefail

# ========================== 全局变量 ==========================
SCRIPT_VERSION="1.0.0"
CLOUDFLARED_TOKEN="${1:-}"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ========================== 工具函数 ==========================
log_info()    { echo -e "${BLUE}[INFO]${NC}  $*"; }
log_success() { echo -e "${GREEN}[OK]${NC}    $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $*"; }
log_step()    { echo -e "\n${CYAN}${BOLD}━━━ $* ━━━${NC}"; }

divider() { echo -e "${BLUE}──────────────────────────────────────────────────────${NC}"; }

# ========================== 环境检测 ==========================
detect_os() {
    OS=""
    OS_ID=""
    ARCH=""
    PKG_MGR=""
    INIT_SYSTEM=""

    # 检测操作系统
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        OS="${NAME:-Unknown}"
        OS_ID="${ID:-unknown}"
    elif [[ -f /etc/redhat-release ]]; then
        OS="RedHat"
        OS_ID="rhel"
    elif [[ -f /etc/debian_version ]]; then
        OS="Debian"
        OS_ID="debian"
    else
        OS="$(uname -s)"
        OS_ID="$(echo "$OS" | tr '[:upper:]' '[:lower:]')"
    fi

    # 检测架构
    ARCH="$(uname -m)"
    case "$ARCH" in
        x86_64)  ARCH="amd64" ;;
        aarch64|arm64) ARCH="arm64" ;;
        armv7l|armhf) ARCH="arm" ;;
        i386|i686) ARCH="386" ;;
        *) log_warn "未识别的架构: $(uname -m), 使用 uname -m 原始值" ;;
    esac

    # 检测包管理器
    if command -v apt-get &>/dev/null; then
        PKG_MGR="apt"
    elif command -v dnf &>/dev/null; then
        PKG_MGR="dnf"
    elif command -v yum &>/dev/null; then
        PKG_MGR="yum"
    elif command -v pacman &>/dev/null; then
        PKG_MGR="pacman"
    elif command -v zypper &>/dev/null; then
        PKG_MGR="zypper"
    else
        log_error "未检测到支持的包管理器"
        exit 1
    fi

    # 检测 init 系统
    if [[ -d /run/systemd/system ]] || command -v systemctl &>/dev/null; then
        INIT_SYSTEM="systemd"
    elif [[ -f /etc/init.d/cron ]] || command -v service &>/dev/null; then
        INIT_SYSTEM="sysvinit"
    else
        INIT_SYSTEM="unknown"
    fi

    echo ""
    divider
    log_info "系统信息检测:"
    log_info "  操作系统:   ${BOLD}${OS}${NC}"
    log_info "  系统标识:   ${OS_ID}"
    log_info "  架构:       ${ARCH}"
    log_info "  包管理器:   ${PKG_MGR}"
    log_info "  Init 系统:  ${INIT_SYSTEM}"
    log_info "  内核版本:   $(uname -r)"
    divider
}

# 检查 root 权限
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "此脚本需要 root 权限运行"
        echo "请使用: sudo bash $0 <token>"
        exit 1
    fi
}

# 检查参数
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

# ========================== 依赖安装 ==========================
install_dependencies() {
    log_step "安装基础依赖"

    case "$PKG_MGR" in
        apt)
            apt-get update -qq
            apt-get install -y -qq curl wget unzip ca-certificates lsb-release > /dev/null 2>&1
            ;;
        dnf)
            dnf install -y -q curl wget unzip ca-certificates > /dev/null 2>&1
            ;;
        yum)
            yum install -y -q curl wget unzip ca-certificates > /dev/null 2>&1
            ;;
        pacman)
            pacman -Sy --noconfirm --quiet curl wget unzip ca-certificates > /dev/null 2>&1
            ;;
        zypper)
            zypper --non-quiet install -y curl wget unzip ca-certificates > /dev/null 2>&1
            ;;
    esac

    log_success "基础依赖安装完成"
}

# ========================== 1. Cloudflared ==========================
install_cloudflared() {
    log_step "1/3  安装 Cloudflared"

    if command -v cloudflared &>/dev/null; then
        local current_ver
        current_ver="$(cloudflared --version 2>&1 | sed -n 's/.*\([0-9]\{4\}\.[0-9]*\.[0-9]*\).*/\1/p' | head -1)"
        [[ -z "$current_ver" ]] && current_ver="$(cloudflared --version 2>&1 | head -1)"
        log_info "Cloudflared 已安装 (版本: ${current_ver})"
    else
        log_info "正在下载 Cloudflared (${ARCH})..."

        local cf_url=""
        case "$ARCH" in
            amd64)  cf_url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64" ;;
            arm64)  cf_url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64" ;;
            arm)    cf_url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm" ;;
            386)    cf_url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-386" ;;
            *)
                log_error "不支持的架构: $ARCH"
                return 1
                ;;
        esac

        curl -fsSL -o /usr/local/bin/cloudflared "$cf_url"
        chmod +x /usr/local/bin/cloudflared

        if cloudflared --version &>/dev/null; then
            log_success "Cloudflared 安装成功: $(cloudflared --version 2>&1)"
        else
            log_error "Cloudflared 安装失败"
            return 1
        fi
    fi

    # 安装 tunnel 服务
    log_info "正在注册 Cloudflared Tunnel 服务..."
    if cloudflared service install "$CLOUDFLARED_TOKEN" 2>&1; then
        log_success "Cloudflared Tunnel 服务注册成功"
    else
        log_error "Cloudflared Tunnel 服务注册失败"
        return 1
    fi

    # 启动并设置开机自启
    if [[ "$INIT_SYSTEM" == "systemd" ]]; then
        systemctl daemon-reload
        systemctl enable cloudflared 2>/dev/null || true
        systemctl restart cloudflared
        sleep 2
        if systemctl is-active --quiet cloudflared; then
            log_success "Cloudflared 服务运行正常"
        else
            log_warn "Cloudflared 服务状态异常，请检查: journalctl -u cloudflared -n 50"
        fi
    fi
}

# ========================== 2. Lucky (幸运加速) ==========================
install_lucky() {
    log_step "2/3  安装 Lucky (幸运加速)"

    # 检查是否已安装
    if command -v lucky &>/dev/null || [[ -f /usr/local/bin/lucky ]]; then
        log_info "Lucky 已安装，跳过安装步骤"

        if [[ "$INIT_SYSTEM" == "systemd" ]]; then
            if systemctl is-active --quiet lucky 2>/dev/null; then
                log_success "Lucky 服务已在运行"
                return 0
            fi
            systemctl start lucky 2>/dev/null || true
        fi
        return 0
    fi

    log_info "正在下载并安装 Lucky..."

    # 官方安装方式
    local LUCKY_URL="http://release.66666.host"
    local INSTALL_SCRIPT="/tmp/lucky_install.sh"

    if curl -fsSL -o "$INSTALL_SCRIPT" "${LUCKY_URL}/install.sh" 2>/dev/null; then
        chmod +x "$INSTALL_SCRIPT"
        if sh "$INSTALL_SCRIPT" "$LUCKY_URL" 2>&1; then
            log_success "Lucky 安装成功 (官方脚本)"
        else
            log_warn "官方脚本安装失败，尝试备用方案..."
            _install_lucky_manual
        fi
        rm -f "$INSTALL_SCRIPT"
    else
        log_warn "无法下载 Lucky 官方安装脚本，尝试备用方案..."
        _install_lucky_manual
    fi

    # 确保服务运行
    if [[ "$INIT_SYSTEM" == "systemd" ]]; then
        systemctl daemon-reload
        systemctl enable lucky 2>/dev/null || true
        systemctl restart lucky 2>/dev/null || true
        sleep 2
        if systemctl is-active --quiet lucky 2>/dev/null; then
            log_success "Lucky 服务运行正常"
        else
            log_warn "Lucky 服务状态异常，可通过 Web UI 或 systemctl status lucky 检查"
        fi
    fi
}

# Lucky 备用手动安装
_install_lucky_manual() {
    log_info "使用备用方案安装 Lucky..."

    local lucky_url=""
    case "$ARCH" in
        amd64) lucky_url="https://github.com/gdy666/lucky/releases/latest/download/lucky_linux_amd64" ;;
        arm64) lucky_url="https://github.com/gdy666/lucky/releases/latest/download/lucky_linux_arm64" ;;
        arm)   lucky_url="https://github.com/gdy666/lucky/releases/latest/download/lucky_linux_arm" ;;
        *)
            log_error "不支持的架构: $ARCH"
            return 1
            ;;
    esac

    curl -fsSL -o /usr/local/bin/lucky "$lucky_url"
    chmod +x /usr/local/bin/lucky

    # 创建配置目录
    mkdir -p /etc/lucky
    mkdir -p /var/log/lucky

    # 创建 systemd 服务
    if [[ "$INIT_SYSTEM" == "systemd" ]]; then
        cat > /etc/systemd/system/lucky.service << 'SYSTEMD_EOF'
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
SYSTEMD_EOF
        systemctl daemon-reload
        systemctl enable lucky
        systemctl start lucky
    fi

    log_success "Lucky 手动安装完成"
}

# ========================== 3. 3x-ui (X-UI) ==========================
install_3xui() {
    log_step "3/3  安装 3x-ui (X-UI 面板)"

    # 检查是否已安装
    if [[ -f /usr/local/x-ui/x-ui ]]; then
        log_info "3x-ui 已安装"

        if [[ "$INIT_SYSTEM" == "systemd" ]]; then
            if systemctl is-active --quiet x-ui 2>/dev/null; then
                log_success "3x-ui 服务已在运行"
                return 0
            fi
            systemctl start x-ui 2>/dev/null || true
        fi
        return 0
    fi

    log_info "正在下载并安装 3x-ui..."

    # 下载官方安装脚本
    local INSTALL_SCRIPT="/tmp/3xui_install.sh"
    if curl -fsSL -o "$INSTALL_SCRIPT" "https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh" 2>/dev/null; then
        chmod +x "$INSTALL_SCRIPT"

        # 非交互式安装: 自动确认所有提示
        log_info "执行 3x-ui 安装脚本 (自动模式)..."
        yes | bash "$INSTALL_SCRIPT" 2>&1 || true

        rm -f "$INSTALL_SCRIPT"
    else
        log_error "无法下载 3x-ui 安装脚本，请检查网络连接"
        return 1
    fi

    # 确保服务运行
    if [[ "$INIT_SYSTEM" == "systemd" ]]; then
        systemctl daemon-reload
        systemctl enable x-ui 2>/dev/null || true
        systemctl restart x-ui 2>/dev/null || true
        sleep 3
        if systemctl is-active --quiet x-ui 2>/dev/null; then
            log_success "3x-ui 服务运行正常"
        else
            log_warn "3x-ui 服务状态异常，请检查: journalctl -u x-ui -n 50"
        fi
    fi
}

# ========================== 服务状态总览 ==========================
show_status() {
    echo ""
    echo ""
    divider
    log_info "${BOLD}服务部署状态总览${NC}"
    divider

    # Cloudflared
    echo -n "  Cloudflared Tunnel : "
    if command -v cloudflared &>/dev/null; then
        if [[ "$INIT_SYSTEM" == "systemd" ]] && systemctl is-active --quiet cloudflared 2>/dev/null; then
            echo -e "${GREEN}● 运行中${NC}"
        else
            echo -e "${YELLOW}● 已安装 (服务状态未知)${NC}"
        fi
    else
        echo -e "${RED}● 未安装${NC}"
    fi

    # Lucky
    echo -n "  Lucky (幸运加速)   : "
    if command -v lucky &>/dev/null || [[ -f /usr/local/bin/lucky ]]; then
        if [[ "$INIT_SYSTEM" == "systemd" ]] && systemctl is-active --quiet lucky 2>/dev/null; then
            echo -e "${GREEN}● 运行中${NC}"
        else
            echo -e "${YELLOW}● 已安装 (服务状态未知)${NC}"
        fi
    else
        echo -e "${RED}● 未安装${NC}"
    fi

    # 3x-ui
    echo -n "  3x-ui (X-UI 面板)  : "
    if [[ -f /usr/local/x-ui/x-ui ]]; then
        if [[ "$INIT_SYSTEM" == "systemd" ]] && systemctl is-active --quiet x-ui 2>/dev/null; then
            echo -e "${GREEN}● 运行中${NC}"
        else
            echo -e "${YELLOW}● 已安装 (服务状态未知)${NC}"
        fi
    else
        echo -e "${RED}● 未安装${NC}"
    fi

    divider
    echo ""
    log_info "管理命令:"
    log_info "  查看状态:  systemctl status cloudflared | lucky | x-ui"
    log_info "  重启服务:  systemctl restart cloudflared | lucky | x-ui"
    log_info "  查看日志:  journalctl -u <服务名> -f"
    echo ""
}

# ========================== 主流程 ==========================
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

    # 依次安装三个服务
    install_cloudflared
    install_lucky
    install_3xui

    # 显示最终状态
    show_status

    log_success "${BOLD}全部服务部署完成!${NC}"
    echo ""
}

main "$@"
