# 多服务一键部署脚本

一键部署 Cloudflared Tunnel、Lucky (幸运加速)、3x-ui (X-UI 面板) 三大服务。

## 支持系统

Ubuntu / Debian / CentOS / RHEL / Fedora / Arch Linux 等主流发行版，自动识别系统架构 (amd64 / arm64 / arm)。

## 快速开始

```bash
# 下载脚本
curl -fsSLO https://raw.githubusercontent.com/<用户名>/<仓库名>/main/setup.sh

# 赋予执行权限
chmod +x setup.sh

# 运行 (需要 Cloudflared Token)
sudo bash setup.sh <your_cloudflared_token>
```

## 参数说明

| 参数 | 必填 | 说明 |
|------|------|------|
| `cloudflared_token` | 是 | Cloudflare Zero Trust Tunnel Token |

Token 获取方式：登录 [Cloudflare Zero Trust Dashboard](https://one.dash.cloudflare.com/) → Networks → Tunnels → 创建或选择已有 Tunnel → 复制安装命令中的 token。

## 集成的服务

### Cloudflared Tunnel

Cloudflare 官方隧道服务，将内网服务安全暴露到公网。脚本会自动下载对应架构的二进制文件并注册为 systemd 服务。

### Lucky (幸运加速)

集 DDNS、端口转发、反向代理、WOL、ACME 证书申请等功能于一身的网络工具。默认通过官方安装脚本部署，失败时自动切换备用方案。

- 官方文档: https://lucky666.cn/docs/install/
- 源码: https://gitee.com/gdy666/lucky

### 3x-ui (X-UI 面板)

基于 Xray 的多协议面板，支持 VLESS / VMess / Trojan 等协议。

- 源码: https://github.com/mhsanaei/3x-ui

## 管理命令

```bash
# 查看服务状态
systemctl status cloudflared
systemctl status lucky
systemctl status x-ui

# 重启服务
sudo systemctl restart cloudflared
sudo systemctl restart lucky
sudo systemctl restart x-ui

# 查看实时日志
sudo journalctl -u cloudflared -f
sudo journalctl -u lucky -f
sudo journalctl -u x-ui -f
```

## 脚本特性

- 自动检测操作系统、架构和包管理器
- 自动安装 curl、wget、ca-certificates 等基础依赖
- 每个服务安装前检查是否已存在，避免重复安装
- 自动注册 systemd 服务并设置开机自启
- 安装完成后展示服务运行状态总览

## License

MIT
