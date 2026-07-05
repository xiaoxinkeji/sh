# 多服务一键部署脚本

一键部署 Cloudflared Tunnel、Lucky (幸运加速)、3x-ui (X-UI 面板) 三大服务。

## 兼容性

**Init 系统:** systemd / sysvinit / OpenRC (自动检测，无 systemd 时自动降级为 sysvinit 或 OpenRC)

**发行版:** Ubuntu / Debian / CentOS / RHEL / Fedora / Arch / Alpine / OpenWrt / openSUSE

**架构:** amd64 / arm64 / arm / 386

**包管理器:** apt / dnf / yum / pacman / zypper / apk / opkg (无包管理器时跳过依赖安装)

## 快速开始

```bash
curl -fsSLO https://raw.githubusercontent.com/xiaoxinkeji/sh/main/setup.sh
chmod +x setup.sh
sudo bash setup.sh <your_cloudflared_token>
```

Token 获取: [Cloudflare Zero Trust Dashboard](https://one.dash.cloudflare.com/) → Networks → Tunnels → 复制 token

## 集成的服务

| 服务 | 说明 | 源码 |
|------|------|------|
| Cloudflared Tunnel | Cloudflare 内网穿透隧道 | [cloudflare/cloudflared](https://github.com/cloudflare/cloudflared) |
| Lucky (幸运加速) | DDNS / 端口转发 / 反向代理 / ACME | [gdy666/lucky](https://gitee.com/gdy666/lucky) |
| 3x-ui (X-UI) | 多协议面板 (VLESS/VMess/Trojan) | [mhsanaei/3x-ui](https://github.com/mhsanaei/3x-ui) |

## 脚本特性

- 自动检测操作系统、架构、包管理器和 init 系统
- 统一服务管理抽象层，屏蔽 systemd / sysvinit / OpenRC 差异
- 无 systemd 时自动生成 `/etc/init.d/` 脚本或 OpenRC 配置
- 每个服务安装前检查是否已存在，避免重复安装
- 精简系统 (Alpine / OpenWrt) 也能正常运行
- 安装完成后展示服务运行状态总览

## 管理命令

根据 init 系统不同，管理命令也有区别:

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
