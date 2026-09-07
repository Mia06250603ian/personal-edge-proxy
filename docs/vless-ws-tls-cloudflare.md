# VLESS + WebSocket + TLS（Cloudflare 源证书）

把已有的 VLESS 入口从**裸 TCP + 自签证书**改成 **WebSocket + 真证书**。
端口、协议、UUID 全部不变，HY2 完全不碰。

| | 改前 | 改后 |
|---|---|---|
| 实现 | sing-box | sing-box（**不变**） |
| 端口 | TCP 8443 | TCP 8443（**不变**） |
| 协议 | VLESS | VLESS（**不变**） |
| UUID | 现有那个 | 现有那个（**不变**，脚本从配置里读出来沿用） |
| 传输 | 裸 TCP | **WebSocket, path `/ws`** |
| 证书 | 自签，CN=`www.bing.com` | **Cloudflare 源证书** |

> **VLESS 在这台机器上是 sing-box 在跑，不是 xray。**
> 依据：`AGENTS.md` §0.1（xray 的 inbound 服务 active 但端口不 bind）、
> §0.6（xray 的 REALITY 和 VLESS+TLS 入口全部握手失败，换 sing-box 一次就通）。
> 所以下面所有命令都是 `sing-box`，配置文件是 `/etc/sing-box/config.json`。
> 在这台机器上把 VLESS 挪回 xray，按两次实机记录，结果大概率是根本不监听。

> **HY2 一个字都不改。** 脚本只读 `/etc/hysteria/config.yaml` 取一个端口号用来打印，
> 不写它、不重启它，跑完还会确认 `hysteria-server` 仍然 active。

---

## 0. 动手之前：Cloudflare 那边的四个前提

缺任何一条，服务端配得再对也不通。

| 前提 | 说明 |
|---|---|
| DNS 有 A 记录 | `YOUR_DOMAIN` → VPS 的 IP |
| SSL/TLS 模式 | **Full** 或 **Full (strict)**。Flexible 会让 CF 用明文回源，源站在 8443 上等的是 TLS，直接不通 |
| 端口 | **8443 是 Cloudflare 支持的 HTTPS 端口之一**，橙云代理可以正常回源，所以不需要迁 443 |
| WebSocket | CF 默认就是开的，一般不用管 |

**源证书（Origin Certificate）只被 Cloudflare 信任，不在公共信任链里。** 这一条决定客户端怎么写：

- **客户端 → Cloudflare（橙云）→ 源站**：客户端看到的是 CF 边缘证书，**正常校验，不用跳过**
- **客户端 → VPS IP 直连（灰云 / 直接写 IP）**：看到的是这张源证书，**必须跳过校验**

---

## 1. 写证书和私钥（一次一条，中间不要合并）

写完**先校验再改配置**——手机 SSH 会静默增删空格（`AGENTS.md` §0.11），
PEM 正文被塞进一个空格，openssl 就解不开了。这一步的全部意义就是把这种情况
在重启服务之前挡住。

**① 写证书**（粘完证书全文，另起一行按 `Ctrl-D` 结束）：

```
cat > /etc/ssl/YOUR_DOMAIN.pem
```

**② 写私钥**（同样，粘完按 `Ctrl-D`）：

```
cat > /etc/ssl/YOUR_DOMAIN.key
```

**③ 收权限**：

```
chmod 644 /etc/ssl/YOUR_DOMAIN.pem; chmod 600 /etc/ssl/YOUR_DOMAIN.key
```

**④ 校验证书能不能解析、什么时候过期**：

```
openssl x509 -in /etc/ssl/YOUR_DOMAIN.pem -noout -subject -enddate
```

打不出 `subject=` 和 `notAfter=` 就是粘坏了，回到 ① 重写，**不要往下走**。

**⑤ 校验私钥和证书是不是一对**（这一条最关键，两个文件各自都对、但不配对的情况是真会发生的）：

```
diff <(openssl x509 -in /etc/ssl/YOUR_DOMAIN.pem -noout -pubkey) <(openssl pkey -in /etc/ssl/YOUR_DOMAIN.key -pubout) && echo PAIR_OK
```

**必须打印 `PAIR_OK`。** 没打印就两个文件都重贴一次，别只重贴一个。

---

## 2. 改服务端（三条）

**① 拉脚本**：

```
curl -fsSL https://raw.githubusercontent.com/Mia06250603ian/personal-edge-proxy/main/scripts/add-ws-tls.sh -o /tmp/add-ws-tls.sh
```

**② 先空跑，看它打算改什么**（这一步不改任何东西）：

```
bash /tmp/add-ws-tls.sh --cert /etc/ssl/YOUR_DOMAIN.pem --key /etc/ssl/YOUR_DOMAIN.key --path /ws --dry-run
```

确认打印出来的是：端口 8443、协议 VLESS、UUID 沿用、传输 WebSocket。**不是就停下。**

**③ 真的改**（去掉 `--dry-run`）：

```
bash /tmp/add-ws-tls.sh --cert /etc/ssl/YOUR_DOMAIN.pem --key /etc/ssl/YOUR_DOMAIN.key --path /ws
```

脚本自己会做完这些，任何一步不过就**自动回滚**并保留原配置：

1. 校验证书能解析、没过期、和私钥配对
2. 从现有配置里读出 UUID 和端口**沿用**，不生成新的、不迁 443
3. 确认 8443 上监听的确实是 sing-box（是别的实现就停下，因为改这份配置不会有任何效果）
4. 备份 `/etc/sing-box/config.json` 成 `.bak.<时间戳>`
5. 写新配置 → `sing-box check` → `grep` 确认 path 和证书路径真的写进去了
6. `systemctl restart sing-box` → 等端口 bind（`ss` 会比进程 bind 快半秒，不能立刻判）
7. **在本机起一个测试客户端，真的从这条入口过一次请求**，打印出口 IP
8. 确认 `hysteria-server` 仍然活着

> 第 7 条是硬要求，不是保险。`AGENTS.md` §0.6：上一轮有脚本在"端口已监听"的
> 状态下报了部署完成，结果两台客户端配完都连不上。**端口在监听 ≠ 这条入口能用。**

---

## 3. 客户端（两端必须同一次改完）

服务端一旦变成 WS，**还写着裸 TCP 的客户端就直接连不上了**——失败形式是"连不上"，
和故障长得一模一样。所以服务端改完就立刻换客户端。

`path` 大小写敏感，两端必须一模一样。

### 走 Cloudflare（橙云）——推荐

不用跳过证书校验，因为客户端看到的是 CF 的边缘证书。

**mihomo / Clash：**

```yaml
  - name: my-ws
    type: vless
    server: YOUR_DOMAIN
    port: 8443
    uuid: PASTE_VLESS_UUID
    network: ws
    udp: true
    tls: true
    servername: YOUR_DOMAIN
    skip-cert-verify: false
    ws-opts:
      path: /ws
      headers:
        Host: YOUR_DOMAIN
```

**sing-box：**

```json
{
  "type": "vless",
  "tag": "my-ws",
  "server": "YOUR_DOMAIN",
  "server_port": 8443,
  "uuid": "PASTE_VLESS_UUID",
  "tls": {
    "enabled": true,
    "server_name": "YOUR_DOMAIN"
  },
  "transport": {
    "type": "ws",
    "path": "/ws"
  }
}
```

### 直连 VPS IP（灰云 / DNS-only）

只有 `server` 和跳过校验这两处不同——源证书不在公共信任链里，不跳过必然失败：

- mihomo：`server: PASTE_SERVER_IP` + `skip-cert-verify: true`，`servername` 和 `Host` 仍然写域名
- sing-box：`"server": "PASTE_SERVER_IP"` + `"insecure": true`，`server_name` 仍然写域名

### 不要动的

- **HY2 那个节点原样保留**，本次没有任何服务端改动涉及它
- sing-box 的 `selector` / mihomo 的 `proxy-groups` 里，把原来的 `my-tcp` 换成 `my-ws`；
  组里**不要放 `direct` / `DIRECT`**（iOS 没有系统级 kill switch，落到直连就是明文出网且无提示）

---

## 4. 怎么判断"通了"

**不要用"能刷开网页"判断**（Safari 吃缓存、分流规则可能判成直连，两种都会给出假的"通"）。

- 客户端里对节点**点测延迟**：出数字 = 握手成功
- 服务端看有没有真的接住：`journalctl -u sing-box -n 20 --no-pager -o cat`
- 确认 HY2 没被牵连：`systemctl is-active hysteria-server; ss -ulnp | grep 24443`

---

## 5. 回滚

脚本每次都会备份。回到改之前：

```
ls -t /etc/sing-box/config.json.bak.* | head -1
```

```
cp $(ls -t /etc/sing-box/config.json.bak.* | head -1) /etc/sing-box/config.json && systemctl restart sing-box
```

回滚之后服务端又是**裸 TCP + 自签证书**，客户端也要一起换回去，否则同样连不上。

---

## 6. 给下一个会话的两条

1. **`scripts/restore-baseline.sh` 会把 VLESS 打回裸 TCP + 自签证书。**
   跑它之前先想清楚这条 WS 入口要不要留；跑完之后客户端也要跟着回退。
   `examples/client-baseline.md` 里的 `my-tcp` 是**基线形态**，不是当前形态。
2. **这次改动与 HY2 在手机蜂窝上会断那件事无关**，别把它记成对那个问题的修复。
   那条线的状态见 `docs/NEXT-SESSION.md`，本次没有任何进展。
