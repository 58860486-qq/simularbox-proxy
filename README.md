# Simular Box Tailscale HTTP 代理一键恢复

通过 Tailscale 将 Simular Box 内置的 HTTP 代理转发到 Tailnet，供 Windows
浏览器、ZeroOmega 等客户端使用。

## 功能

脚本 `rebuild-simular-proxy.sh` 用于在**全新创建的 Simular Box Ubuntu
实例**上恢复代理节点配置：

-   检查 Ubuntu、`silkd` 服务和 `cbonline` 网卡。
-   使用 Simular Box 内置的 `silkd`，上游代理地址为 `127.0.0.1:3128`。
-   配置 APT 通过本机 HTTP 代理访问网络。
-   配置 `cbonline` 辅助地址 `192.0.2.10/32` 和 metric 为 `5000`
    的默认路由。
-   安装并配置 Tailscale，令 `tailscaled` 通过本机 HTTP 代理联网。
-   配置 Tailscale 启动前的网络和代理就绪检查。
-   使用 `socat` 将 Tailscale IPv4 地址的 TCP `18080` 转发到
    `127.0.0.1:3128`。
-   在 Simular Box 的 nftables 规则链中放行 Tailscale 接口访问 TCP
    `18080`。
-   创建并启用 systemd 服务，实现重启后自动恢复。
-   输出 Tailscale IP、代理监听状态和本机代理出口检测结果。

## 环境要求

本脚本针对已验证的 Simular Box 环境编写，**不是通用 Ubuntu
代理安装脚本**。

运行前需要满足：

1.  系统为 Ubuntu。
2.  实例提供 `silkd.service`，并由它在 `127.0.0.1:3128` 提供 HTTP 代理。
3.  实例存在 `cbonline` 网络接口。
4.  Simular Box 已创建 nftables 规则链 `inet cocoonbox input`。
5.  以 `root` 身份在交互式终端中运行。
6.  实例能够通过本机 `127.0.0.1:3128` 访问外部网络。

如果缺少 `silkd` 或
`cbonline`，脚本会停止，避免把专用网络配置盲目应用到其他机器。

## 一键安装

在新建的 Simular Box 终端中执行：

``` bash
bash <(curl -fsSL https://raw.githubusercontent.com/58860486-qq/simularbox-proxy/refs/heads/main/rebuild-simular-proxy.sh)
```

也可以先下载，再执行：

``` bash
curl -fsSLo /root/rebuild-simular-proxy.sh \
  https://raw.githubusercontent.com/58860486-qq/simularbox-proxy/refs/heads/main/rebuild-simular-proxy.sh

chmod +x /root/rebuild-simular-proxy.sh
bash /root/rebuild-simular-proxy.sh
```

## Tailscale 授权

脚本运行到授权步骤时，会提示输入 Tailscale Auth Key：

-   输入 Auth Key：脚本尝试自动完成节点授权。
-   直接回车：脚本尝试启动网页登录授权流程；按终端显示的链接完成授权。

建议在 Tailscale 管理后台创建短有效期、可重复使用且权限范围尽量小的 Auth
Key。**不要将 Auth Key 写入脚本、提交到 GitHub 或发送给他人。**

如果使用网页登录，完成授权后若脚本因尚未取得 Tailscale IP
而退出，可重新运行脚本。脚本会重新检查并配置相关服务。

## 安装完成后的信息

成功后，脚本会显示新节点的 Tailscale IPv4 地址，例如：

``` text
Tailscale IP：100.x.x.x
HTTP 代理地址：100.x.x.x:18080
上游代理地址：127.0.0.1:3128
```

代理链路：

``` text
Windows / 浏览器
       |
       | Tailscale 网络
       v
新实例 Tailscale_IP:18080
       |
       | socat 转发
       v
127.0.0.1:3128
       |
       v
Simular Box silkd
       |
       v
公网
```

## 客户端测试

在 Windows PowerShell 中，将下面的 `100.x.x.x` 替换为脚本输出的
Tailscale IP：

``` powershell
Test-NetConnection 100.x.x.x -Port 18080
curl.exe -x http://100.x.x.x:18080 https://api.ipify.org
```

第一条命令应显示 `TcpTestSucceeded : True`。第二条命令会返回该 Simular
Box 节点的公网出口 IP。

## ZeroOmega 示例

如果希望主用节点优先、备用节点故障时回退到本节点，可以使用 PAC：

``` javascript
function FindProxyForURL(url, host) {
    return "PROXY 主用节点Tailscale_IP:18080; PROXY 备用节点Tailscale_IP:18080";
}
```

请将两个占位地址替换为实际 Tailscale IP。重建实例后，Tailscale IP
可能变化，需要同步更新 PAC。

PAC
的代理回退属于浏览器连接层面的故障回退，并不等同于持续的应用层健康检查。不要在
PAC 末尾随意添加 `DIRECT`，否则代理不可用时浏览器可能直接连接互联网。

## 重启后的自动恢复

脚本会创建并启用以下服务：

-   `tailscaled.service`
-   `simular-proxy-relay.service`

并创建网络就绪检查脚本：

-   `/usr/local/sbin/wait-simular-network.sh`

重启后可以检查：

``` bash
systemctl is-active systemd-networkd
systemctl is-active silkd
systemctl is-active tailscaled
systemctl is-active simular-proxy-relay

ip -br addr
ip route
tailscale status
ss -lntp | grep -E '127.0.0.1:3128|:18080'
```

四个服务应显示 `active`，并应看到本机 `127.0.0.1:3128` 和 Tailscale IP
的 `18080` 监听。

## 常见问题

### 1. 提示没有找到 `silkd.service`

说明当前实例没有检测到 Simular Box
内置代理服务。请确认实例类型和平台服务状态；不要在普通 Ubuntu VPS
上直接套用本脚本。

### 2. 提示没有发现 `cbonline` 网卡

脚本依赖当前已验证环境中的 `cbonline` dummy
网卡。若平台调整了网络实现，需要先检查网络结构，再修改脚本。

### 3. Tailscale 没有获取到 IP

先检查：

``` bash
systemctl status silkd tailscaled --no-pager -l
journalctl -u tailscaled -n 100 --no-pager
tailscale status
```

确认本机代理可用，并完成 Tailscale 授权后，再运行恢复脚本。

### 4. 找不到 nftables 规则链

脚本依赖 Simular Box 创建的 `inet cocoonbox input`
规则链。如果平台尚未创建该链或其名称发生变化，代理转发服务会无法启动。先检查：

``` bash
nft list tables
nft list ruleset
```

不要在不了解平台防火墙规则的情况下自行创建或替换整套防火墙规则。

### 5. Windows 无法连接代理端口

检查新实例的 Tailscale IP、服务状态和防火墙规则：

``` bash
tailscale ip -4
systemctl status simular-proxy-relay --no-pager -l
nft list chain inet cocoonbox input
ss -lntp | grep 18080
```

同时确认 Windows 已连接到同一个 Tailscale 网络。

## 安全与注意事项

-   本项目脚本会修改 systemd、systemd-networkd、APT 代理配置和 nftables
    规则，请先阅读脚本内容，再以 root 执行。
-   `192.0.2.10/32` 是文档示例保留网段中的辅助地址，仅用于当前已验证的
    `cbonline` 本地网络配置，不是公网地址。
-   脚本会备份原有 `/etc/systemd/network/05-cocoonbox-online.network`
    文件，备份文件名带时间戳。
-   脚本依赖 Simular Box 平台提供的 `silkd` 和 nftables
    规则链。平台升级后应重新验证。
-   GitHub Raw
    地址公开可访问，任何人都可以读取仓库中的脚本。不要在仓库中保存 Auth
    Key、密码或其他凭据。
-   `curl | bash`
    便捷但会直接执行远程脚本。对生产实例，建议先下载、检查脚本内容，再运行。

## 项目地址

-   GitHub 仓库：<https://github.com/58860486-qq/simularbox-proxy>
-   一键恢复脚本：<https://raw.githubusercontent.com/58860486-qq/simularbox-proxy/refs/heads/main/rebuild-simular-proxy.sh>

## 免责声明

本脚本根据特定 Simular Box
实例的实际部署配置整理，尚不能保证适用于所有实例类型、系统版本或平台网络实现。首次用于新实例时，建议保留平台控制台访问方式，并在完成后验证代理出口及重启恢复情况。
