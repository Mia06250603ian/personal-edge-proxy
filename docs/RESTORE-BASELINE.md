# 回到基线：把服务端和客户端拆回最初搭好那天的状态

**这份文档的优先级高于 `docs/NEXT-SESSION.md` 的全部内容。**
`NEXT-SESSION.md` 记的是 2026-09-06 到 09-07 那两轮排查的过程，其中大部分
改动要么已被后续证据推翻、要么从未验证。**基线跑通之前，不要照它做任何事。**

---

## 0. 为什么要回退

线上现在同时挂着这些东西，而它们互相依赖、又都没有被完整验证过：

| 现在挂着的 | 状态 | 问题 |
|---|---|---|
| iptables `UDP 443 → 24443` | 生效 | 客户端连的端口和服务端配置里写的端口不是同一个 |
| iptables `UDP 20000:30000 → 24443` | 生效但**没有任何客户端在用** | 看到规则就以为端口跳跃在生效 |
| 端口跳跃客户端字段 | **实测失败，已回滚**（`port` 与 `ports` 互斥写错了） | 手机上残留半份 |
| Salamander 混淆 | 已开 | 两端必须同时带，少一边就是恒失败 |
| Brutal（`ignoreClientBandwidth: false`） | 已开 | 客户端虚报带宽时会自造丢包 |
| VLESS 在 443 / 8443 之间来回搬 | 最终 8443 | 净变化为零，只留下教训 |
| 两台客户端配置不一致 | 手机按 Clash 改过、实际跑 sing-box | 任何现象都无法归因到某一端 |
| `/etc/sysctl.d/99-hy2.conf` 与 `99-hysteria-udp.conf` 并存 | 内容重叠 | 生效值来自哪一份要靠文件名排序去猜 |

**核心问题不是其中任何一条，是它们叠在一起之后没人能说清"这个现象是谁造成
的"。** 排查的前提是一次只有一个变量，现在有六七个。

回退不是放弃那些手段——它们的加装步骤写在 §4，**基线稳住之后一次加一项**。

---

## 1. 基线是什么

就是 `scripts/install-hy2-official.sh` + `scripts/add-tcp-entry.sh`
本来会生成的那份配置，一个入口一个端口，中间没有任何转发层：

| 项 | 基线值 |
|---|---|
| HY2 | `listen: :24443`（UDP） |
| 混淆 | **无** |
| `ignoreClientBandwidth` | `true`（BBR） |
| `quic.maxIdleTimeout` | `60s` |
| `udpIdleTimeout` | `90s` |
| masquerade | `proxy` → `https://www.bing.com/` |
| VLESS | `TCP 8443`（**不是 443**，理由见 §3） |
| iptables nat PREROUTING | **一条 REDIRECT 都没有** |
| sysctl | 只有 `/etc/sysctl.d/99-hysteria-udp.conf` 一份 |
| 客户端 | 两台同一份，见 `examples/client-baseline.md` |

**密码、UUID、证书都不动。** 还原脚本从现有配置里把密码原样读出来沿用，
不会重新生成——重新生成会让两台设备同时失联，而失联之后只能走 Vultr
网页控制台，代价极高。

---

## 2. 怎么做（服务端，一次一条短命令）

> 用户是纯手机运维，iOS SSH 客户端会在粘贴的行内**静默插入和吞掉空格**。
> 所以下面每一步都是**一条短命令**，不要合并、不要用多行脚本。

**第一条，把脚本拉到服务器：**

```
curl -fsSL https://raw.githubusercontent.com/Mia06250603ian/personal-edge-proxy/main/scripts/restore-baseline.sh -o /root/rb.sh
```

（仓库是私有的话这条会拿到 404。那就在能打字的设备上 clone 仓库、
把脚本 `scp` 上去，或者直接用 §5 的手工步骤。）

**第二条，先只看会改什么，不动手：**

```
bash /root/rb.sh --dry-run
```

它会打印现状和目标状态。**看一眼再往下走。**

**第三条，真的还原：**

```
bash /root/rb.sh
```

脚本会先把当前整机状态快照到 `/root/pre-baseline-<时间戳>/`（配置、
iptables、密码、混淆密码都在里面），然后才动手；HY2 起不来会自动回滚。

**第四条，确认端口真的在听：**

```
ss -ulnp | grep 24443; ss -tlnp | grep 8443
```

**第五条，确认转发层真的没了：**

```
iptables -t nat -L PREROUTING -n
```

必须是空的。**如果这里还有 REDIRECT，说明规则被持久化过**，
不清掉的话下次重启会原样长回来。

---

## 3. 怎么做（客户端）

服务端还原完，两端就对不上了，节点此时是不通的——**这是预期的，不是故障**。

按 `examples/client-baseline.md` **整段替换**两台设备的配置。要点：

- 端口回 `24443`
- 删掉 `obfs` / `obfs-password`
- 删掉 `ports` / `server_ports` / `hop-interval` / `hop_interval`
- VLESS 端口 `8443`
- 两台用同一份

**关于 VLESS 为什么不搬到 443：** 本项目的证书是自签的、CN 为 `www.bing.com`。
自签证书挂在 443 上是很明显的代理特征，而 443 是全互联网被扫得最狠的端口。
2026-09-07 迁过去当天日志里就出现了扫描器（`unknown version: 71`，即 `GET`
的首字节）。**拿到域名和真证书之前，TCP 入口留在 8443。**

---

## 4. 加装项：稳住之后一次加一项

基线连续跑够一整天、心里有底之后再考虑。**每次只加一项，加完记下实测结果，
不满意就退回去，再加下一项。** 顺序按"代价从小到大"排：

### 加装项一：客户端自动切换（只动客户端，服务端零风险）

把 `PROXY` 组从 `select` 改成 `fallback`，加 `interval: 30` 和 `lazy: false`。
HY2 死掉时 30 秒内自动切到 VLESS，恢复后自动切回。

**要解决的现象：** 连接断了之后客户端不会自己爬起来——2026-09-07 那次最长的
连接撑了 3 小时 12 分，断在 02:20，此后近两小时一次重连都没有。飞行模式之所以
有效，不是在修网络，是在**强迫客户端重建连接**。

`lazy: false` 必须写：默认 `true` 会在无流量时停止探测，等于没做健康检查。

**验收：** 早上醒来还需不需要开飞行模式。不需要测速。

### 加装项二：Brutal（一条命令，可回退）

```
sed -i 's/^ignoreClientBandwidth: true/ignoreClientBandwidth: false/' /etc/hysteria/config.yaml
```

改完 `grep` 确认、再 `systemctl restart hysteria-server`。

**已有实测**（iPad / speed.cloudflare.com，2026-09-07）：

| | BBR | Brutal |
|---|---|---|
| 下载 | 5.74 Mbps | **27.3 Mbps** |
| 延迟 | 358 ms | 257 ms |
| 抖动 | 226 ms | **22.6 ms** |
| 丢包 | 50% | 30.5% |

**代价：** 高速无视丢包的 UDP 流可能招来运营商 QoS。**这是取舍不是纯收益，
让用户自己选。** 开了就必须同时把客户端的 `up` / `down` 改成实测值——虚报会
让多出来的带宽全变成丢包。实测这条路约 27 Mbps，别再写 150。

### 加装项三：Salamander 混淆（**服务端和客户端必须同时改**）

服务端加 `obfs` 段并重启，两台客户端同时加 `obfs: salamander` 和
`obfs-password`。**少改一边就是节点恒失败**，而且失败形式是"连不上"，
很容易被误判成别的问题。

混淆改变的是流量**看起来像什么**，只覆盖 HY2。它是最后一张牌：
如果开了混淆手机仍然不通，那就指向这个 IP 在该运营商蜂窝网上被针对，
再往端口和参数上绕没有意义。

### 明确不要做的

- **端口跳跃。** 2026-09-07 实测失败并已回滚。而且手机存在过一条 3 小时 12 分的
  连接——如果运营商真的按"流的年龄"掐断，这条连接不可能存在。
- **Mimic。** Linux 专用、要装内核模块、要 root，**用户客户端是 iOS，装不了**。
- **`tune-hy2.sh`。** 审计列了 6 个问题，见 `docs/AUDIT-RESULT.md` 三。
- **换 IP / 换机房 / 迁东京。** 用户账号认着这个出口 IP，换 IP 有真实代价。
- **只改服务端的 `maxIdleTimeout`。** RFC 9000 取两端最小值，客户端默认 30s，
  单改服务端不生效。基线里那条 60s 是基线的一部分，不是修复。

---

## 5. 万一脚本用不了：手工还原的最小命令序列

一条一条发，每条都短。

```
cp /etc/hysteria/config.yaml /root/hy2.bak
```

```
grep -A2 '^auth:' /etc/hysteria/config.yaml
```

（把打印出来的密码记下来，下面要用，**不要重新生成**。）

```
iptables -t nat -F PREROUTING
```

```
netfilter-persistent save
```

（没装 iptables-persistent 会提示找不到命令，那说明规则本来就不会持久化，
忽略即可。）

```
sed -i 's/^ignoreClientBandwidth: false/ignoreClientBandwidth: true/' /etc/hysteria/config.yaml
```

```
sed -i 's/^listen: :443$/listen: :24443/' /etc/hysteria/config.yaml
```

混淆要手工删掉 `obfs:` 那三到四行——这一步用 `sed` 不可靠，**用编辑器删，
删完先 `grep obfs` 确认没了再重启**。

```
systemctl restart hysteria-server
```

```
ss -ulnp | grep 24443
```

---

## 6. 还原之后，下一步问什么

基线跑通、两台客户端都换完之后，原始问题依然在那儿没解决：
**HY2 在手机蜂窝上会死。**

现在真正站得住的只有三条：

1. **不是 IP 被针对** —— 5G、代理全关，SSH TCP 22 连得上（实测有截图）
2. **不是服务器** —— iPad 走家宽可用；负载 0、机房出口 0% 丢包
3. **死法是连续 30 秒完全断流**，不是渐进变慢（服务端日志实证：
   `accepting stream failed: timeout: no recent network activity`）

**下一轮的取证纪律**（上一轮违反过，用户明确抗议）：

1. **能从服务器只读日志拿到的，绝不让用户动客户端。** 日志是免费的。
2. **要复现用 iPad。** 它本来就走这个节点，出口 IP 不变，零风险。
3. **不要为了取证要求用户在手机上切代理。** 一次都不要——他的账号认着出口 IP。
4. 遇到不认识的症状**先搜索再推理**。上一轮前几小时全在推理，推一个塌一个；
   搜索十分钟就定位到了症状和上游记录。
