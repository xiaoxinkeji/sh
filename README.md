# 多服务一键部署脚本

一键部署 Cloudflared Tunnel、Lucky (幸运加速)、3x-ui (X-UI 面板) 三大服务。

## 兼容性

| 维度 | 支持范围 |
|------|----------|
| Init 系统 | systemd / sysvinit / OpenRC (自动检测降级) |
| 发行版 | Ubuntu Debian CentOS RHEL Fedora Arch Alpine OpenWrt openSUSE |
| 架构 | amd64 / arm64 / arm / 386 |
| 包管理器 | apt / dnf / yum / pacman / zypper / apk / opkg |

## 快速开始

```bash
curl -fsSLO https://raw.githubusercontent.com/xiaoxinkeji/sh/main/setup.sh
sudo bash setup.sh
```

脚本启动后会进入交互式菜单:

1. 选择要安装的服务 (支持多选, 直接回车全选)
2. 如果选择了 Cloudflared, 按提示粘贴 Token

Token 获取: [Cloudflare Zero Trust Dashboard](https://one.dash.cloudflare.com/) → Networks → Tunnels → 复制 token

## 集成的服务

| 服务 | 说明 | 源码 |
|------|------|------|
| Cloudflared Tunnel | Cloudflare 内网穿透隧道 | [cloudflare/cloudflared](https://github.com/cloudflare/cloudflared) |
| Lucky (幸运加速) | DDNS / 端口转发 / 反向代理 / ACME | [gdy666/lucky](https://gitee.com/gdy666/lucky) |
| 3x-ui (X-UI) | 多协议面板 (VLESS/VMess/Trojan) | [mhsanaei/3x-ui](https://github.com/mhsanaei/3x-ui) |

## 脚本特性

**环境自适应:** 自动检测操作系统、架构、包管理器和 init 系统。精简系统 (Alpine / OpenWrt) 也能正常运行。

**Init 三层降级:** systemd → OpenRC → sysvinit → 无 init。无 systemd 时自动生成 `/etc/init.d/` 脚本，init.d 脚本内部还会自动检测 `start-stop-daemon` / `daemon` / `nohup` 哪种可用。

**安全:** Cloudflared Token 存入独立配置文件 (权限 600)，不硬编码到 init.d 脚本中。

**健壮性:** 网络连通性预检、下载重试 (3 次)、磁盘空间检查、文件日志 (`/var/log/setup-services.log`)、信号捕获清理临时文件。

**精确进程检测:** 使用二进制路径精确匹配，避免 `pgrep -f` 误杀同名进程。

## 管理命令

```bash
# systemd
systemctl status cloudflared
systemctl restart lucky
journalctl -u x-ui -f

# sysvinit
/etc/init.d/cloudflared status
/etc/init.d/lucky restart

# OpenRC
rc-service cloudflared status
rc-service lucky restart
```

## License

MIT
