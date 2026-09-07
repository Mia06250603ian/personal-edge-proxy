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

> ✅ **2026-09-07 实机跑通。** 服务端自测通过、经 Cloudflare 的链路验证通过
> （§4 那条 curl 得到 `HTTP 400`）、iOS sing-box 客户端点测延迟出数字。
> 全程端口 8443、协议 VLESS、UUID 均未改动，HY2 未受影响。
> 这一轮踩到的两个坑都写进下面了：**§1 的空行**和 **§2 的子域名 SNI**。

---

## 0. 动手之前：Cloudflare 那边的四个前提

缺任何一条，服务端配得再对也不通。

> **两个占位符不是一回事，混了就会连不上：**
> `YOUR_DOMAIN` = 证书那个域名（如 `example.com`，只用来命名证书文件）；
> `YOUR_HOSTNAME` = **DNS 记录实际用的主机名**（如 `cdn.example.com`），
> 客户端的 SNI / `Host`、服务端的 `--sni` 全部用它。两者相同就当同一个用。

> ### 子域名别取名叫 `vless` / `proxy` / `v2ray`
>
> **TLS 握手里的 SNI 是明文的**（除非开 ECH，Cloudflare 目前默认没开）。
> 链路上任何一个 DPI 盒子都能直接读到 `SNI: vless.example.com`——
> 前面费劲把流量伪装成"访问 Cloudflare 上的普通网站"，域名却把协议名写在脸上。
>
> 这和 `AGENTS.md` §0.6 记的"自签证书别挂 443"是同一类错误：**招牌和内容对不上。**
> 用 `cdn` / `static` / `assets` / `img` 这种满互联网都是的名字。
> 2026-09-07 最初建的就是 `vless.`，当天改掉了。
>
> 注意这不影响账号安全（账号只看出口 IP），**纯粹是隐蔽性**。

| 前提 | 说明 |
|---|---|
| DNS 有 A 记录 | `YOUR_HOSTNAME` → VPS 的 IP |
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

**必须打印 `PAIR_OK`。**

### ⚠️ 实机最常见的失败：粘贴时每行后面被插了一个空行

2026-09-07 实机踩到。表现是 `Could not read key from ...`，而**文件看上去是好的**：
`-----BEGIN PRIVATE KEY-----` 在，`-----END PRIVATE KEY-----` 也在，内容一个字节没少。

这是 `AGENTS.md` §0.11 那个"手机 SSH 会改写粘贴内容"的另一种形态——不是吞空格，
是**每行后面多一个空行**，2048 位私钥于是从 28 行变成 55 行。

先确认是不是它（**不会打印私钥正文**）：

```
grep -c . /etc/ssl/YOUR_DOMAIN.key; grep -n -- '-----' /etc/ssl/YOUR_DOMAIN.key
```

非空行 28 左右、但 `END` 落在第 55 行 → 就是它。**删掉空行就能救，不用重贴**：

```
sed -i '/^[[:space:]]*$/d' /etc/ssl/YOUR_DOMAIN.key; chmod 600 /etc/ssl/YOUR_DOMAIN.key
```

然后回去重跑上面那条 `PAIR_OK`。

其余情况（`PAIR_OK` 没打印、或打出一堆 `<` `>` 开头的行）是两个文件不配对，
两个都重贴一次，别只重贴一个。

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

> ### ⚠️ DNS 记录建在子域名上，就必须加 `--sni`
>
> 2026-09-07 实机踩到。脚本会自动从证书里取 SNI，但证书里有的是
> `*.example.com` 和 `example.com`，取出来是**主域名**；而 DNS 记录实际建在
> `vless.example.com` 上，**Cloudflare 回源时发的 SNI 是子域名**，两边对不上。
>
> 所以用了子域名就在命令末尾加上：`--sni vless.example.com`
>
> 脚本打印 `SNI（自动取自证书）` 时会跟一条提醒；打印 `SNI（--sni 指定）`
> 就说明用的是你给的值。**改客户端之前先把这一项对齐**，否则排查起来会
> 表现成"证书问题"，方向全错。

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

> **节点名沿用原来的 `my-tcp`，只换里面的内容。** 这样 selector / proxy-groups
> 一个字都不用动，少一处能出错的地方。2026-09-07 实机就是这么换的。

### ⛔ 先读这一条：`server` 写域名会让这条节点自己等自己

**2026-09-07 实机踩到，花了近一小时。** 症状极具误导性：

- 客户端点测延迟：`my-tcp` 没数字，`my-hy2-obfs` 有数字
- 服务端日志：**一条连接都没有**（不是握手失败，是根本没拨出去）
- 服务端、Cloudflare、DNS 逐个查过去**全是好的**

成因是配置层面的循环依赖，和网络无关：

```
解析 cdn.example.com  →  DNS 走 detour: PROXY
                      →  PROXY 这时选中的正是 my-tcp
                      →  而 my-tcp 正等着这个解析结果
```

**自己等自己。** HY2 不受影响，因为它的 `server` 是裸 IP，压根不需要解析——
这恰好制造了"只有 VLESS 坏了"的假象，把排查带向握手和证书，方向全错。

> 这个依赖是**从 IP 换成域名那一刻引入的**，以前不存在。
> 一度以为触发条件是"HY2 死了导致 DNS 没路走"，实测推翻：HY2 活得好好的照样复现。
> **真正的触发条件是 `PROXY` 当前选中的就是这条节点本身。**

**修法：让这条节点不需要任何解析——`server` 直接写 Cloudflare 的 anycast IP，
`server_name` 和 `Host` 仍写域名。**

CF 是按 SNI / Host 决定转给谁的，**不看你连的是哪个 IP**，所以这样完全等价，而且更好：

- 隐蔽性没损失，SNI 和 Host 还是你的域名
- **连那次 DNS 查询都不存在了**，运营商看不到你查过什么（§1 说的那个避不开的泄露，就这么没了）
- 顺带打开了"优选 IP"这条调优路

代价只有一个：**CF 哪天收回这个地址，节点会突然连不上**。重新解析拿新的换上即可：

```
curl -sS -H 'accept: application/dns-json' 'https://1.1.1.1/dns-query?name=YOUR_HOSTNAME&type=A'
```

CF 一般给两条 A 记录（`104.21.x` 和 `172.67.x` 两个段），**两个都能用**。
延迟高就换另一个试——它们是 anycast，从不同运营商出去落到的机房不一样。

### 走 Cloudflare（橙云）——推荐

不用跳过证书校验，因为客户端看到的是 CF 的边缘证书。

**mihomo / Clash：**

```yaml
  - name: my-tcp
    type: vless
    server: PASTE_CF_ANYCAST_IP
    port: 8443
    uuid: PASTE_VLESS_UUID
    network: ws
    udp: true
    tls: true
    servername: YOUR_HOSTNAME
    skip-cert-verify: false
    ws-opts:
      path: /ws
      headers:
        Host: YOUR_HOSTNAME
```

**sing-box（这一份 2026-09-07 在 iOS 上实测连通）：**

```json
{
  "type": "vless",
  "tag": "my-tcp",
  "server": "PASTE_CF_ANYCAST_IP",
  "server_port": 8443,
  "uuid": "PASTE_VLESS_UUID",
  "tls": {
    "enabled": true,
    "server_name": "YOUR_HOSTNAME"
  },
  "transport": {
    "type": "ws",
    "path": "/ws",
    "headers": {
      "Host": "YOUR_HOSTNAME"
    }
  }
}
```

和改之前那一块的差别，照着核对最快：

| | 旧（裸 TCP + 自签） | 新（WS + CF） |
|---|---|---|
| `server` | 服务器 IP | **CF 的 anycast IP**（不是域名，见上面那条 ⛔） |
| `server_name` | `www.bing.com` | `YOUR_HOSTNAME` |
| `insecure` | `true` | **整行删掉**（CF 边缘是公共信任的真证书） |
| `transport` | 没有 | `ws` + `path: /ws` + `Host` 头 |

`server` 写 IP 时 **`Host` 头要显式写上**——走 IP 连接，就得自己把域名带上。

### 直连 VPS IP（灰云 / DNS-only）

只有 `server` 和跳过校验这两处不同——源证书不在公共信任链里，不跳过必然失败：

- mihomo：`server: PASTE_SERVER_IP` + `skip-cert-verify: true`，`servername` 和 `Host` 仍然写域名
- sing-box：`"server": "PASTE_SERVER_IP"` + `"insecure": true`，`server_name` 仍然写域名

### 不要动的

- **HY2 那个节点原样保留**，本次没有任何服务端改动涉及它
- **`selector` / `proxy-groups` 不用动**——节点名沿用 `my-tcp`，只换了里面的内容
- 组里**不要放 `direct` / `DIRECT`**（iOS 没有系统级 kill switch，落到直连就是明文出网且无提示）
- **两台设备用同一份**，别给单台开小灶（`AGENTS.md` §0.12）

---

## 4. 怎么判断"通了"

**不要用"能刷开网页"判断**（Safari 吃缓存、分流规则可能判成直连，两种都会给出假的"通"）。

**先在服务器上验整条 Cloudflare 链路——不用碰客户端**（`NEXT-SESSION` §0A.10：
能从服务器拿到的证据，绝不让用户去切代理）：

```
curl -sS -o /dev/null -w 'HTTP %{http_code}\n' --max-time 15 https://YOUR_HOSTNAME:8443/ws
```

这条走的是**服务器 → CF 边缘 → 回源 8443**，和客户端将来走的是同一条路。

| 输出 | 含义 |
|---|---|
| `HTTP 400` / `HTTP 404` | ✅ **通了**。这是 sing-box 在说"你不是 WebSocket 请求"——收得到它的回话就说明 CF 回源、TLS、证书全对 |
| `HTTP 502 / 521 / 523 / 525` | ❌ CF 到源站这一段有问题（525 = 回源 TLS 握手失败，先查 SNI 和 SSL 模式） |
| 超时 / curl 报错 | ❌ 卡在 CF 边缘，多半 DNS 还没生效 |

链路验过之后再动客户端：

- 客户端里对节点**点测延迟**：出数字 = 握手成功
- 服务端看有没有真的接住：`journalctl -u sing-box -n 20 --no-pager -o cat`
  - 来源 IP 是 Cloudflare 的（`104.x` / `172.67.x`）才说明走了橙云
  - `bad path: /` 这类来自非 CF 地址的，是扫描器在敲你的源站 IP，与客户端无关
- 确认 HY2 没被牵连：`systemctl is-active hysteria-server; ss -ulnp | grep 24443`

> **服务器日志里完全没有你的连接记录 = 客户端根本没拨出去**，不是被拒。
> 2026-09-07 实机两次都栽在这上面，成因还不一样：
> 一次是配置压根没换（那份里 `my-tcp` 还是旧的），
> 一次是 §3 那条 DNS 自依赖（配置全对，但节点在解析阶段就卡死了）。
> **零条日志时先查客户端，别去查握手和证书。**

### 改完客户端一定要断开重连

iOS 上光"保存"配置经常不生效，跑的还是旧那份。**把 VPN 开关完全关掉再打开**，
不是切节点。2026-09-07 在这上面白绕了一圈。

### 延迟高怎么办：换一个 CF 地址，别动服务器

写死的那个 anycast IP 从你这条线路出去可能绕远。CF 给的两条 A 记录
（`104.21.x` 和 `172.67.x`）**都能用**，换成另一个再点测延迟，30 秒的事。

> **2026-09-07 实测：两个段差别很大**——`104.21.x` 延迟明显偏高，换到
> `172.67.x` 立刻好转，服务端一个字没动。**遇到延迟高，先换段再谈别的。**
>
> 想知道自己实际落在哪个机房，用手机浏览器（不开代理）打开
> `https://YOUR_HOSTNAME:8443/cdn-cgi/trace`，看 `colo=` 那个三字母机场代码。
> 这个地址由 CF 边缘自己应答，不会碰到你的服务器。
> `HKG`/`NRT`/`SIN` 之类是落在亚洲；`LAX`/`SJC` 就是真绕到美西了。
>
> 顺带澄清一个常见误会：**查这些 IP 的归属地会显示"美国"**，因为 CF 把整段
> 注册在美国。但 anycast 是同一个 IP 被全球几百个机房同时宣告，
> **归属地和你实际去哪个机房无关**，别拿它当判据。
两个都不理想的话，再去找第三方整理的 CF 优选 IP 列表——**只改客户端 `server` 一行，
`server_name` 和 `Host` 保持域名不变，服务端一个字都不用动。**

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
