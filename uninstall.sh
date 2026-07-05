#!/usr/bin/env bash
# ============================================================================
#  多服务一键卸载脚本
#  彻底清理: Cloudflared Tunnel / Lucky / 3x-ui
#  用法: sudo bash uninstall.sh
# ============================================================================

set -uo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

log_info()    { echo -e "${BLUE}[INFO]${NC}  $*"; }
log_success() { echo -e "${GREEN}[ OK ]${NC} $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error()   { echo -e "${RED}[FAIL]${NC} $*"; }
log_step()    { echo -e "\n${CYAN}${BOLD}━━━ $* ━━━${NC}"; }
divider()     { echo -e "${BLUE}──────────────────────────────────────────────────────${NC}"; }

# ---------- 自动提权 ----------
if [[ $EUID -ne 0 ]]; then
    log_warn "需要 root 权限, 自动切换 sudo..."
    exec sudo bash "$0" "$@"
fi

# ---------- 检测 init 系统 ----------
detect_init() {
    if [[ -d /run/systemd/system ]] || (command -v systemctl &>/dev/null && systemctl is-system-running &>/dev/null 2>&1); then
        INIT_SYSTEM="systemd"
    elif command -v rc-service &>/dev/null && [[ -d /etc/init.d ]]; then
        INIT_SYSTEM="openrc"
    elif [[ -d /etc/init.d ]] || command -v service &>/dev/null; then
        INIT_SYSTEM="sysvinit"
    else
        INIT_SYSTEM="none"
    fi
}

# ---------- 统一停止 ----------
svc_stop() {
    local name="$1"
    case "$INIT_SYSTEM" in
        systemd)  systemctl stop "$name" 2>/dev/null || true ;;
        sysvinit)
            if command -v service &>/dev/null; then
                service "$name" stop 2>/dev/null || true
            elif [[ -x "/etc/init.d/$name" ]]; then
                "/etc/init.d/$name" stop 2>/dev/null || true
            fi
            ;;
        openrc)   rc-service "$name" stop 2>/dev/null || true ;;
    esac
    # 兜底: 强杀进程
    pkill -f "$name" 2>/dev/null || true
}

svc_disable() {
    local name="$1"
    case "$INIT_SYSTEM" in
        systemd)  systemctl disable "$name" 2>/dev/null || true ;;
        sysvinit)
            command -v update-rc.d &>/dev/null && update-rc.d -f "$name" remove 2>/dev/null || true
            command -v chkconfig &>/dev/null && chkconfig --del "$name" 2>/dev/null || true
            ;;
        openrc)   rc-update del "$name" 2>/dev/null || true ;;
    esac
}

# ============================================================================
echo ""
echo -e "${CYAN}${BOLD}"
echo "  ╔══════════════════════════════════════════════╗"
echo "  ║       多服务一键卸载脚本                      ║"
echo "  ║  Cloudflared · Lucky · 3x-ui                ║"
echo "  ╚══════════════════════════════════════════════╝"
echo -e "${NC}"

detect_init
log_info "Init 系统: ${INIT_SYSTEM}"

# ---------- 确认 ----------
echo ""
echo -e "${YELLOW}${BOLD}警告: 此操作将彻底删除以下服务及其配置:${NC}"
echo "  - Cloudflared Tunnel"
echo "  - Lucky (幸运加速)"
echo "  - 3x-ui (X-UI 面板)"
echo ""
read -rp "$(echo -e "${RED}[确认]${NC} 输入 YES 继续卸载: ")" confirm
if [[ "$confirm" != "YES" ]]; then
    log_info "已取消"
    exit 0
fi

# ============================================================================
#  1. Cloudflared
# ============================================================================
log_step "卸载 Cloudflared"

svc_stop cloudflared
svc_disable cloudflared

# 用 cloudflared 自带命令卸载服务
if command -v cloudflared &>/dev/null; then
    log_info "执行 cloudflared service uninstall..."
    cloudflared service uninstall 2>/dev/null || true
fi

# 清理文件
rm -f /usr/local/bin/cloudflared
rm -f /usr/bin/cloudflared
rm -f /etc/init.d/cloudflared
rm -f /etc/systemd/system/cloudflared.service
rm -f /lib/systemd/system/cloudflared.service
rm -rf /etc/cloudflared
rm -f /var/run/cloudflared.pid

# Token 配置文件
rm -rf /etc/services-deploy/cloudflared.conf

log_success "Cloudflared 已清除"

# ============================================================================
#  2. Lucky
# ============================================================================
log_step "卸载 Lucky"

svc_stop lucky
svc_disable lucky

# Lucky 官方卸载脚本 (如果存在)
if [[ -x /usr/share/lucky.daji/scripts/luckyservice ]]; then
    log_info "执行 Lucky 自带卸载..."
    /usr/share/lucky.daji/scripts/luckyservice uninstall 2>/dev/null || true
fi

# 清理所有可能的安装路径
rm -rf /usr/share/lucky.daji
rm -rf /usr/share/lucky
rm -rf /etc/lucky
rm -rf /etc/lucky.daji
rm -f /usr/local/bin/lucky
rm -f /etc/init.d/lucky
rm -f /etc/systemd/system/lucky.service
rm -f /lib/systemd/system/lucky.service
rm -f /var/run/lucky.pid
rm -rf /var/log/lucky

# 清理 profile 中可能的 PATH 注入
sed -i '/lucky/d' /etc/profile 2>/dev/null || true

log_success "Lucky 已清除"

# ============================================================================
#  3. 3x-ui
# ============================================================================
log_step "卸载 3x-ui"

svc_stop x-ui
svc_disable x-ui

# 3x-ui 自带卸载
if [[ -f /usr/local/x-ui/x-ui.sh ]]; then
    log_info "执行 3x-ui 自带卸载..."
    echo "y" | /usr/local/x-ui/x-ui.sh uninstall 2>/dev/null || true
fi

# 清理文件
rm -rf /usr/local/x-ui
rm -rf /etc/x-ui
rm -f /etc/init.d/x-ui
rm -f /etc/systemd/system/x-ui.service
rm -f /lib/systemd/system/x-ui.service
rm -f /var/run/x-ui.pid

# 清理 fail2ban (3x-ui 安装的)
if command -v fail2ban-client &>/dev/null; then
    log_info "清理 fail2ban 配置..."
    fail2ban-client stop 2>/dev/null || true
    rm -rf /etc/fail2ban/jail.d/x-ui* 2>/dev/null || true
    rm -rf /etc/fail2ban/jail.d/3x-ui* 2>/dev/null || true
fi

log_success "3x-ui 已清除"

# ============================================================================
#  4. 公共清理
# ============================================================================
log_step "清理残留"

# 空的配置目录
rmdir /etc/services-deploy 2>/dev/null || true

# systemd 重载
if [[ "$INIT_SYSTEM" == "systemd" ]]; then
    systemctl daemon-reload 2>/dev/null || true
fi

# 刷新 PATH 缓存
hash -r 2>/dev/null || true

divider
echo ""
log_success "${BOLD}全部服务已彻底卸载!${NC}"
echo ""
