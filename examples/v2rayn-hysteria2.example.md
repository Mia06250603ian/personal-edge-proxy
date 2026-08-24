# v2rayN：Hysteria2 客户端示例

这份示例来自当前 Windows 客户端的只读审计。

审计环境：

- v2rayN 7.24.2
- 当前激活节点：Hysteria2
- 实际运行 core：sing-box 1.13.14
- v2rayN 激活节点时生成运行时配置，再交给对应 core

> v2rayN 不是把 GUI 里的字段原封不动交给 core。它保存的是“节点元数据 + 全局偏好”，激活节点时才生成 sing-box / Xray 各自的配置方言。

## 1. 我实际在用的结构

当前 HY2 运行时 outbound 脱敏后是：

```json
{
  "type": "hysteria2",
  "tag": "proxy",
  "server": "YOUR_DOMAIN",
  "server_port": 24443,
  "up_mbps": 100,
  "down_mbps": 100,
  "password": "YOUR_HY2_PASSWORD",
  "tls": {
    "enabled": true,
    "server_name": "YOUR_SERVER_NAME",
    "insecure": false
  }
}
```

其中：

- `server`：你的节点域名；
- `server_port`：服务端 HY2 UDP 端口；
- `password`：HY2 认证密码；
- `server_name`：TLS SNI；
- `insecure: false`：正常验证证书，不跳过验证。

### 关于 `up_mbps` / `down_mbps`

当前机器里 `100 / 100` 来自 v2rayN 的 Hysteria 全局设置，不是服务端带宽承诺，也不是必须照抄的“最佳值”。

根据自己的线路和客户端版本调整即可。

## 2. v2rayN 分享链接

最方便的导入形式：

```text
hysteria2://YOUR_HY2_PASSWORD@YOUR_DOMAIN:24443/?sni=YOUR_SERVER_NAME&insecure=0#HY2-Example
```

把以下占位符替换掉：

```text
YOUR_HY2_PASSWORD
YOUR_DOMAIN
YOUR_SERVER_NAME
```

如果密码包含 URL 特殊字符，请正确 URL Encode，不要直接裸拼。

## 3. 当前节点没有启用的东西

当前实际 HY2 节点没有：

- salamander obfs；
- 端口跳跃；
- ECH；
- mux；
- 自定义 ALPN。

所以基础教程也不默认加入这些选项。

先让最小配置稳定工作，再加增强功能。

## 4. v2rayN 为什么会启动 sing-box

当前 v2rayN 安装目录同时有：

- sing-box；
- Xray；
- Mihomo。

但 HY2 激活时实际启动的是 sing-box。

这意味着教程里不要写成：

```text
v2rayN = Xray 客户端
```

更准确的是：

```text
v2rayN = GUI / 配置管理器
        ↓
根据节点协议和 CoreType
        ↓
选择对应 core
```

在这台机器的当前配置里：

```text
HY2      → sing-box
REALITY  → Xray
```

## 5. TUN / Rule 模式

当前 v2rayN 使用：

```text
TUN: enabled
Rule mode
系统代理: 自动
本地 mixed inbound: 127.0.0.1:10808
```

客户端侧主要负责：

```text
私网 / 中国大陆流量 → direct
其余需要代理的流量 → proxy（VPS）
```

AI 服务最终走 VPS Direct、WARP 还是固定 SOCKS5，是**服务端路由**负责的，不需要把上游 SOCKS5 密码放到每台客户端。

## 6. Mihomo 等价写法（可选）

如果你不是 v2rayN，而是 Mihomo / Clash Meta，可以参考：

```yaml
proxies:
  - name: HY2-Example
    type: hysteria2
    server: YOUR_DOMAIN
    port: 24443
    password: YOUR_HY2_PASSWORD
    up: "100 Mbps"
    down: "100 Mbps"
    sni: YOUR_SERVER_NAME
    skip-cert-verify: false
```

不同核心字段名不一样，不要把 sing-box JSON、Xray JSON 和 Mihomo YAML 混着抄。

## 7. 安全提醒

不要把真实的：

- HY2 password；
- 私人域名（如果不希望公开）；
- 订阅 URL；

提交到公开仓库。
