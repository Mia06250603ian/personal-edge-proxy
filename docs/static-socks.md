# 固定 SOCKS5 作为独立出口

这部分是可选增强。

如果你只是想正常使用 HY2 / REALITY：

```text
Client
  ↓
VPS
  ↓
Direct / WARP
```

已经足够。

固定 SOCKS5 的用途是：

> **让某些目标服务长期看到同一个最终出口，而不受入口协议、VPS 迁移或 WARP 重连影响。**

它不是 VLESS、REALITY、HY2 的必需组件。

---

## 1. 什么时候值得用固定出口

比较常见的需求：

- 希望某个服务长期保持相同公网出口；
- VPS 本身会更换，但不希望目标服务看到出口一起变化；
- WARP 会重连或出口变化，但某个服务希望单独固定；
- 希望把“接入线路”和“最终出口身份”彻底解耦。

例如：

```text
Client
  ↓ HY2 / REALITY
VPS
  ↓ Xray routing
static-socks
  ↓
固定公网出口
  ↓
目标服务
```

这个固定 SOCKS5 可以来自你自己控制的另一台服务器或正规供应商提供的私人代理服务。

不要使用来源不明、多人共享、公开泄露或违反供应商条款的代理。

---

## 2. Claude / Anthropic 的示例策略

如果你希望 Claude / Anthropic 始终使用一个固定出口，可以配置：

```text
claude.ai
anthropic.com
      ↓
static-socks
      ↓
固定出口
```

注意：

> 这只是本项目的一个策略示例，不代表 Claude “必须”使用住宅 IP 或固定 SOCKS5。

如果你的 VPS / WARP 出口本身稳定、目标服务所在地区受支持，也可以不用这一层。

---

## 3. Xray SOCKS outbound

```json
{
  "tag": "static-socks",
  "protocol": "socks",
  "settings": {
    "servers": [
      {
        "address": "YOUR_SOCKS_HOST",
        "port": 12324,
        "users": [
          {
            "user": "YOUR_SOCKS_USERNAME",
            "pass": "YOUR_SOCKS_PASSWORD"
          }
        ]
      }
    ]
  }
}
```

替换：

```text
YOUR_SOCKS_HOST
YOUR_SOCKS_USERNAME
YOUR_SOCKS_PASSWORD
```

端口也按实际供应商修改。

不要把这些真实值提交到公开 GitHub。

---

## 4. 域名路由

例如：

```json
{
  "type": "field",
  "domain": [
    "domain:anthropic.com",
    "domain:claude.ai"
  ],
  "network": "tcp,udp",
  "outboundTag": "static-socks"
}
```

放在更宽泛的 catch-all 规则之前。

Xray routing 从上到下匹配；如果先被更宽的 WARP / direct 规则命中，后面的固定出口规则就不会再生效。

推荐思路：

```text
最具体的固定出口规则
        ↓
指定 WARP 规则
        ↓
普通 fallback / direct
```

---

## 5. Fail Closed

如果某个服务的目标是“保持固定出口”，那么上游 SOCKS5 挂掉后，我更倾向于：

```text
连接失败
```

而不是：

```text
自动回落到 VPS Direct
```

这叫 **Fail Closed**。

原因是：

```text
服务可用但出口偷偷变了
```

往往比：

```text
暂时不可用
```

更难发现。

只要 Xray 中这条域名规则仍明确指向 `static-socks`，上游不可达时通常会表现为该连接失败，而不会自动替你改走 `direct`。

真正危险的是你自己写了 fallback / balancer，或者删掉固定路由后让流量落到默认出口。

---

## 6. 不要让固定 SOCKS5 再绕进 WARP

希望的路径：

```text
Xray
  ↓
static-socks
  ↓
VPS 原生网络
  ↓
SOCKS5 upstream
```

不希望：

```text
Xray
  ↓
static-socks
  ↓
系统全局 WARP
  ↓
SOCKS5 upstream
```

这也是为什么本项目使用 WARP Local Proxy，而不是让 WARP 接管 Linux 默认路由。

这样可以保证：

- `warp-official` 分支才走 WARP；
- `static-socks` 分支仍通过 VPS 原生默认网关去连接上游；
- 两个出口真正彼此独立。

---

## 7. 先单独测试上游，不要直接怪 Xray

拿到一个 SOCKS5 后，先从 VPS 测：

```text
VPS → SOCKS5_HOST:PORT
```

至少确认：

- TCP 可以建立；
- 延迟稳定；
- 没有频繁超时；
- 凭据有效；
- 最终出口地区正确。

测试时不要把真实用户名 / 密码复制到聊天记录、Issue 或公开日志。

如果必须在 Shell 临时测试，注意很多命令会把参数暴露在：

```text
shell history
process list
CI log
```

生产凭据更适合放在 root-only 配置文件、secret manager 或部署阶段注入，而不是写进教程命令。

---

## 8. 怎么验证路由真的生效

不要只测“网站能不能打开”。

应该分别比较：

```text
VPS Direct 出口 IP
WARP 出口 IP
static-socks 出口 IP
```

然后针对目标域名确认它实际命中哪一个 outbound。

推荐在部署阶段短时间提高 Xray 日志级别或查看 access log；确认完成后再恢复较低日志级别，避免日志长期膨胀。

---

## 9. 固定出口 ≠ 一定要“住宅 IP”

教程里不建议写成：

```text
AI 必须买住宅 IP
```

更准确的表达是：

```text
如果你有固定出口需求，可以使用可信的固定 SOCKS5。
```

它可能是：

- 自己另一台有固定公网 IP 的 VPS；
- 企业 / 家庭网络中你自己控制的出口；
- 正规供应商提供的私人固定代理。

关键是：

- 来源可信；
- 你有权使用；
- 服务条款允许；
- 不公开共享；
- 凭据不泄露。

---

## 10. 和 WARP 怎么选

简单理解：

| 出口 | 优点 | 适合 |
|---|---|---|
| VPS Direct | 最简单、最快 | 普通流量 |
| WARP | 独立 Cloudflare 出口、易分流 | 指定 AI / SaaS |
| Fixed SOCKS5 | 出口长期固定 | 对固定身份有明确需求的服务 |

推荐先从简单开始：

```text
Direct
  ↓
需要时加 WARP
  ↓
确实需要固定出口时再加 SOCKS5
```

不要为了“看起来高级”一开始就把三层全部叠上。
