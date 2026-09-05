# 交接手册模板

节点搭好之后，**这套东西的实际状态没有任何地方记录**。教程告诉你「怎么搭」，
但三周后你回来排错时需要的是「我这台到底是什么状态」。

这份模板就是补这个缺口。**复制一份填好，存在你自己能找到的地方**
（备忘录、密码管理器、私有仓库）。

## ⚠️ 填好的那份不要提交到公开仓库

里面有 IP 和密码。放进 Git 就等于公开了，而且历史记录删不干净。
这份模板本身用占位符，可以放仓库；填好的那份不行。

也不要截图发给任何人，包括 AI 助手——**要粘贴排错信息时，先把密码和 UUID 涂掉。**
分享链接（`hysteria2://`、`vless://`）里就带着密码，同样不能发。

---

# 我的节点 · 交接手册

> 最后更新：`YYYY-MM-DD`

## 1. 一句话架构

```text
手机 / 平板
  ├─ Hysteria2 (UDP)      日常主用
  └─ VLESS + TLS (TCP)    备用，UDP 被限制时切过去
        ↓
     VPS（服务商 / 地区）
        ↓ Direct
     Internet
```

**两条入口，一个出口。** 入口决定「怎么进 VPS」，出口决定「目标网站看到谁」。
加备用入口不改变出口身份，对账号零影响。

故意没有装 WARP / 固定 SOCKS5——目标是「单一、稳定、不变的独享出口」，
而 WARP 的出口池是共享且轮换的，正好相反。理由见第 5 节。

## 2. 关键参数

| 项目 | 值 |
|---|---|
| 服务商 / 地区 | `例：Vultr / Singapore` |
| 实例规格 / 月费 | `例：1 vCPU 1GB / $5` |
| **IP** | `YOUR_SERVER_IP` |
| SSH | `root` + 密码，端口 22 |
| 系统 | `例：Ubuntu 24.04 LTS x64` |

**入口一（主用）Hysteria2 官方服务端**

| | |
|---|---|
| 端口 | `24443 (UDP)` |
| SNI / 伪装域名 | `www.bing.com` |
| 证书 | 自签 → 客户端必须开 `insecure` / `skip-cert-verify` |
| **密码** | `存密码管理器，不要写在这里` |
| 配置 | `/etc/hysteria/config.yaml` |
| 服务名 | `hysteria-server` |

**入口二（备用）sing-box VLESS + TLS**

| | |
|---|---|
| 端口 | `8443 (TCP)` |
| SNI | `www.bing.com` |
| 证书 | 自签 → 客户端必须开 `skip-cert-verify` |
| **UUID** | `存密码管理器，不要写在这里` |
| 配置 | `/etc/sing-box/config.json` |
| 服务名 | `sing-box` |

> **为什么不用 443**：自签证书挂在 443 上是很明显的代理特征，而 443 是全互联网
> 被扫得最狠的端口。换个非标端口，被主动探测命中的概率低一个数量级，代价几乎为零。
> 等有了域名和真证书，再用 443 才有意义。

**IP 信誉基线**（换 IP 后重新记一次）：

| 检测站 | 分数 | 日期 |
|---|---|---|
| Scamalytics | `例：0 / Low Risk` | |
| ping0.cc | `例：23% 纯净，共享 1-10 人` | |
| AbuseIPDB | `例：滥用置信度 0%，90 天举报 0 次` | |
| ASN | `例：AS20473 Vultr` | |

> **看到「IDC 机房 IP」「广播 IP」是正常的**，任何 $5 的 VPS 都一样。
> 四项指标的真实权重：
>
> ```text
> 独享性    ⭐⭐⭐   决定性
> 稳定性    ⭐⭐⭐   决定性
> 纯净度    ⭐⭐     次要
> 原生性    —       只影响流媒体解锁，与账号风险无关
> ```
>
> 详见 `docs/mobile-quickstart.md` §1.3.5。**别为了让评分好看去换 IP**——
> 换 IP 本身才是风控最敏感的动作。

## 3. 服务端装了什么、改过什么

- [ ] Hysteria2 官方服务端（`install-hy2-official.sh`）
- [ ] TCP 备用入口（`add-tcp-entry.sh`，sing-box）
- [ ] 私网 ACL（禁止经隧道访问机房内网 / 回环）
- [ ] fail2ban（SSH 爆破自动封禁）
- [ ] unattended-upgrades（自动安全补丁）
- [ ] BBR
- [ ] 密码轮换记录：`YYYY-MM-DD`
- [ ] UUID 轮换记录：`YYYY-MM-DD`

## 4. 故意没做的事（以及为什么）

**把「没做」和「忘了做」区分开，未来的自己才不会重复调研同一件事。**

| 没做 | 原因 |
|---|---|
| SSH 密钥登录 / 关闭密码登录 | 有 fail2ban 挡着，手机端配密钥的锁死风险大于收益。**密钥没验证成功前绝对不要关密码登录** |
| REALITY 备用入口 | `例：Xray 26.x 上握手失败，排除了所有参数仍不通，改用 sing-box 普通 TLS。见 add-reality.sh 头部` |
| 域名 + 真证书 | `例：暂缓。它的价值是换 IP 不用改客户端、可以用 443、不用勾 insecure` |
| WARP | 出口池共享且轮换，与「稳定独享出口」的目标直接冲突 |
| 固定 SOCKS5 | 出口本来就固定了，没有要补救的问题。多一跳、多一个第三方能看到流量 |
| CDN / Cloudflare Tunnel | 需要域名，且只改入口不改出口，当前用不上 |
| 住宅 IP | 贵，多数是轮换池，且又要换一次出口 IP。没出问题不加 |

## 5. 客户端

| 设备 | App | 配置位置 |
|---|---|---|
| `例：iPad` | `例：sing-box` | 配置 → `名称` → 编辑 |
| `例：iPad` | `例：Clash by Hako` | 配置 → `名称` → 编辑源码 |
| `例：iPhone` | | |

配置模板见 `docs/mobile-quickstart.md` §4.0.5（Clash / mihomo）和
§4.0.6（sing-box），备用入口的片段见 §9。

**两条入口配成两个节点，用 selector / proxy-group 切换**，不要每次改配置：

```json
{ "type": "selector", "tag": "select", "outbounds": ["proxy", "tcp"], "default": "proxy" }
```

然后 `"route": { "final": "select" }`，**DNS 的 `detour` 也要指向 `select`**——
否则切到备用入口之后，DNS 还在往主入口那条死路上发。

**切换器里不要放 `direct`。** iOS 没有系统级 kill switch，配置里不给后门是唯一可行的做法。

**换密码 / 换 UUID 时**：只改客户端配置里对应的那一行，其他不动。

## 6. 泄露自查结果

**每条入口分别记录。换客户端、加新入口之后要重跑，结论不自动继承。**

| 入口 | 日期 | 结果 |
|---|---|---|
| `HY2 (UDP 24443)` | `YYYY-MM-DD` | |
| `VLESS+TLS (TCP 8443)` | `YYYY-MM-DD` | |

每次检查的项目：

- [ ] 出口 IP 正确（`ippure.com`）
- [ ] 无 IPv6（`test-ipv6.com` 应显示「没有检测到 IPv6 地址」）
- [ ] WebRTC：`browserleaks.com/webrtc` 显示 No Leak
- [ ] DNS：`browserleaks.com/dns` 检测到的服务器全部归属 VPS 服务商
- [ ] proxy-group / selector 里没有 `DIRECT`
- [ ] **断线实测**：服务端停掉服务后，**浏览器打不开**
- [ ] **断线实测**：同上，**App / 游戏也断网**

> **两个断线实测都要做。** 浏览器断了不代表 App 也断了——TUN 模式理论上覆盖
> 所有 App，但值得实际验证一次。
>
> ⚠️ **游戏断线检测很慢**，画面还在、人物还能动，不代表还连着服务器。
> 等一分钟再判断，否则会误判成「有 App 绕过了隧道」。

## 7. 常用命令

```bash
# 手机 SSH 连上先跑这条，否则 systemctl / journalctl 会卡进 less 出不来
export SYSTEMD_PAGER=cat

# 状态
systemctl status hysteria-server --no-pager
systemctl status sing-box --no-pager

# 端口真的在监听吗（排错第一步，服务 active ≠ 端口在听）
ss -ulnp | grep 24443
ss -ltnp | grep 8443

# 看日志（-o cat 去掉前缀，手机屏幕才放得下）
journalctl -u hysteria-server -n 30 --no-pager -o cat
journalctl -u sing-box -n 30 --no-pager -o cat

# 服务器自己能不能出网（; echo 不能省，curl 成功时不换行）
curl -4 -m 8 https://api.ipify.org; echo

# 重启
systemctl restart hysteria-server
systemctl restart sing-box

# 换 HY2 密码（随机生成并应用，不用自己想）
cd ~ && NEWPASS=$(openssl rand -hex 12) && bash hy2.sh --password "$NEWPASS"

# 换备用入口 UUID
NEW=$(cat /proc/sys/kernel/random/uuid); \
sed -i "s/\"uuid\": \"[^\"]*\"/\"uuid\": \"$NEW\"/" /etc/sing-box/config.json; \
sing-box check -c /etc/sing-box/config.json && systemctl restart sing-box && echo "新 UUID: $NEW"

# 被封禁的爆破 IP
fail2ban-client status sshd
```

## 8. 待办

- [ ] **每月查一次服务商余额** —— 归零会暂停实例，再过一段时间销毁，**IP 永久回收**。
      能设自动充值就设，那是唯一一劳永逸的做法
- [ ] 退掉旧线路之前，先用新节点连续跑几天确认稳定
- [ ] 每一两个月复查一次 IP 信誉
- [ ] 其他：

## 9. 这套东西踩过的坑（排错先看这里）

**手机端专属：**

| 症状 | 真正的原因 |
|---|---|
| 终端卡在一屏看不懂的东西里，怎么按都出不来 | 进了 `less` 分页器（误触 `h` 会进帮助页）。按 `q`，可能要两次；没反应就断开重连。**每次连上先 `export SYSTEMD_PAGER=cat`** |
| `curl` 跑完「什么都没输出」 | curl 成功时**不换行**，结果被下一个提示符盖住了。命令后面永远加 `; echo` |
| 日志看不到报错内容 | 默认格式每行前缀就比屏幕宽，真正的错误被挤到右边。用 `-o cat` |
| SSH 报 `unknown node or service` | 主机名里混进了多余字符（复制 IP 时带上的） |
| SSH 密码怎么输都不对 | iOS 键盘的自动大写 / 智能标点改写了密码 |

**服务端：**

| 症状 | 真正的原因 |
|---|---|
| 客户端连不上，但服务 `active`、日志无报错 | **端口根本没监听**。先 `ss -ulnp`，别动客户端 |
| 服务起来又立刻退出，报 `permission denied` | 配置文件属主不对，服务用户读不了自己的配置。`chown -R hysteria:hysteria /etc/hysteria` |
| 日志里 `client connected` 之后 `no recent network activity` | 握手成功、密码正确、包到得了服务器，但 **UDP 断流**。服务器没问题，是运营商在限制 UDP → 切 TCP 备用入口 |
| 加了新入口，端口在监听，客户端却连不通 | **端口在监听 ≠ 这条入口能用**。装完必须真的通过它发一次请求验证（仓库脚本会自动做） |

**客户端：**

| 症状 | 真正的原因 |
|---|---|
| 客户端报 `required GeoIP geodata` | 该客户端强制要这个数据文件，**且 VPN 开着时下不了**。断开、用别的网络、放前台等几分钟 |
| 客户端报「不是有效的 YAML」 | 配置贴到了文件末尾，`proxies` 出现两次；或列表缩进不一致 |
| 切到备用入口后没网，但主入口正常 | DNS 的 `detour` 还指着主入口 |
| 速度偏慢 | hysteria2 没设 `up` / `down` 带宽 |

**排错方法论：**

- **一次只改一个变量。**「iPhone+5G 不通、iPad+WiFi 能通」证明不了是运营商的问题——
  设备和网络同时变了，结论无效。
- **不要用 Xray 部署。** 这个仓库在实机上被它坑过两次：hysteria inbound 配置通过校验、
  服务 `active`、却根本不绑定端口；REALITY 和普通 VLESS+TLS 都握手失败，
  且唯一的报错不说原因。用 hysteria 官方服务端 + sing-box。见 `AGENTS.md` §0.1、§0.6。

完整版见 `docs/mobile-quickstart.md` §6。

## 10. 如果一切都没了，怎么重建

1. 开一台新 VPS（**同一地区，别换国家**）
2. 拿到 IP 先去 `scamalytics.com/ip/<IP>` 和 `ping0.cc` 验，不合格就销毁重开
3. SSH 上去，依次跑：
   ```bash
   bash scripts/install-hy2-official.sh    # 主入口
   bash scripts/harden-server.sh           # fail2ban / 自动补丁 / BBR
   bash scripts/add-tcp-entry.sh           # TCP 备用入口
   ```
4. 客户端按 `docs/mobile-quickstart.md` §4.0.6 配，两条入口都配上
5. 按 §4.2 跑一遍泄露自查，两条入口分别测
6. 按 §5.1 的流程平滑迁移，**不要当天就切**

**从零到能用约 30 分钟**，前提是这份手册和仓库还在。
