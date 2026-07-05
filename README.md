# 多服务一键部署脚本

一键部署 Cloudflared Tunnel、Lucky (幸运加速)、3x-ui (X-UI 面板)。

## 一行安装

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/xiaoxinkeji/sh/main/setup.sh)
```

脚本会自动请求 root 权限，启动后进入交互式菜单选择要安装的服务。已安装的服务会自动标注 `[已安装]`。

## 其他用法

```bash
# 查看服务状态
bash setup.sh --status

# 卸载服务 (交互式选择)
bash setup.sh --uninstall
```

## 兼容性

| 维度 | 支持范围 |
|------|----------|
| Init 系统 | systemd / sysvinit / OpenRC (自动检测降级) |
| 发行版 | Ubuntu Debian CentOS RHEL Fedora Arch Alpine OpenWrt openSUSE |
| 架构 | amd64 / arm64 / arm / 386 |
| 包管理器 | apt / dnf / yum / pacman / zypper / apk / opkg |

## 交互流程

```
请选择要安装的服务 (直接回车 = 全部安装):

  1) Cloudflared Tunnel   — Cloudflare 内网穿透隧道
  2) Lucky (幸运加速)      — DDNS / 端口转发 / 反向代理
  3) 3x-ui (X-UI 面板)    — 多协议代理面板

  输入编号, 多选逗号分隔 (如 1,3), 或直接回车全选

[选择] _
```

选择 Cloudflared 时会提示粘贴 Token (从 [Cloudflare Zero Trust Dashboard](https://one.dash.cloudflare.com/) → Networks → Tunnels 获取)。未输入则自动跳过。

## 集成的服务

| 服务 | 说明 | 源码 |
|------|------|------|
| Cloudflared Tunnel | Cloudflare 内网穿透隧道 | [cloudflare/cloudflared](https://github.com/cloudflare/cloudflared) |
| Lucky (幸运加速) | DDNS / 端口转发 / 反向代理 / ACME | [gdy666/lucky](https://gitee.com/gdy666/lucky) |
| 3x-ui (X-UI) | 多协议面板 (VLESS/VMess/Trojan) | [mhsanaei/3x-ui](https://github.com/mhsanaei/3x-ui) |

## 脚本特性

**一体化:** 安装、卸载、状态查看全部集成在一个脚本中。`--uninstall` 不再需要下载远程脚本，`--status` 快速查看运行状态。

**环境自适应:** 自动检测操作系统、架构、包管理器和 init 系统。精简系统 (Alpine / OpenWrt) 也能正常运行。

**Init 三层降级:** systemd → OpenRC → sysvinit → 无 init。无 systemd 时自动生成 `/etc/init.d/` 脚本，启动失败时自动降级为 nohup 直接启动。

**安全:** Cloudflared Token 存入独立配置文件 (权限 600)，不硬编码到 init.d 脚本中。

**健壮性:** 网络连通性预检、下载重试 (3 次)、磁盘空间检查、信号捕获清理临时文件。

**精确进程检测:** 使用 `/proc/<pid>/exe` 验证二进制路径，避免 `pgrep` 误判同名进程。

## 安装后管理

安装完成后，根据系统 init 类型使用对应命令:

```bash
# ── systemd (Ubuntu/Debian/CentOS/Fedora/Arch 等主流发行版) ──
systemctl status cloudflared lucky x-ui     # 查看状态
systemctl restart cloudflared               # 重启单个服务
journalctl -u lucky -f                      # 查看实时日志

# ── sysvinit (精简系统 / 老系统) ──
/etc/init.d/cloudflared status              # 查看状态
/etc/init.d/lucky restart                   # 重启服务

# ── OpenRC (Alpine / Gentoo) ──
rc-service cloudflared status               # 查看状态
rc-service lucky restart                    # 重启服务
```

## License

MIT
