# 独立复核请求

请复核另一个 AI 助手（Claude）对一台个人代理节点所做的改动。
**用户不信任那些改动，需要独立意见。请以挑错为目标来读,不要默认它是对的。**

代码在分支 `claude/node-connection-stability-r70aod`。

---

## 请回答这三个问题

1. **服务器上已生效的改动，有没有引入安全问题或稳定性风险？**
2. **分支上的脚本有没有 bug？** 尤其是会破坏一个正在运行的节点的那种。
3. **用这个节点登录 claude.ai 这类需要账号的服务，实际风险是什么？**
   用户因为不确定，目前不敢用。请给一个明确的判断。

---

## 背景

- Ubuntu 24.04，Vultr VPS，单人自用
- 用户**只有手机**，没有电脑，没有救援控制台。锁死风险要按高估算
- 两条入口，同一台机器同一个出口 IP：
  - **HY2**（Hysteria2 官方服务端）UDP 24443 —— 日常主用
  - **VLESS + TLS**（sing-box）TCP 8443 —— 备用
- 主诉：HY2 反复断线。TCP 那条一直稳定
- 用户仍在用旧机场，正在评估是否切换

---

## 一、服务器上已经生效的改动（2026-09-06）

| 改动 | 声称的理由 | 请复核 |
|---|---|---|
| `/etc/hysteria/config.yaml` 追加 `ignoreClientBandwidth: true` | 客户端声明 `down_mbps: 150` 会让服务端启用 Brutal 拥塞控制，按 150Mbps 发送并**故意无视丢包**。服务端日志每条连接都有 `"tx": 18750000`（=150Mbps），实测 72 小时内 234/235 条如此 | 这个推断成立吗？`ignoreClientBandwidth` 真的会让服务端改用 BBR 吗？追加一个顶层键到该 YAML 末尾安全吗？ |
| `systemctl disable --now xray` | xray 在 TCP 443 上 active 且开机自启，`access.log` 为 0 字节（从未成功服务过一条连接），`error.log` 280KB 且在增长。历史记录（AGENTS.md §0.1/§0.6）显示 Xray 在此机器上两次失败后已被 hysteria + sing-box 取代 | 停用它会不会破坏什么？ |
| `/etc/sing-box/config.json` 644 → 600，属主改为 `sing-box` 用户 | 该文件含 VLESS UUID，原本服务器上任何用户可读 | 属主处理对吗？该服务确实以非 root 运行 |
| 2 个 `*.bak.*` 备份文件 chmod 600 | 内含节点密码 | |
| `apt upgrade` + 重启 | 内核更新待生效 | 重启后两条入口均自动恢复，已验证 |

**没有改**（刻意保留，以免干扰当前的归因实验）：
`quic.maxIdleTimeout`（仍为默认 30s）、`net.core.rmem_max`（仍为 212992）、
`obfs`（未启用）、SSH 策略（root + 密码 + 22 端口）、两条入口的客户端
TLS 校验（仍为 `insecure: true`）。

---

## 二、请重点验证的几个具体技术论断

这些是给用户做决策的依据。**如果哪一条是错的，请直接指出。**

1. **`"tx": 18750000` = 150 Mbps，且表示 Brutal 拥塞控制生效。**
   算式：18,750,000 bytes/s × 8 = 150 Mbps，与客户端配置的 `down_mbps: 150` 相符。

2. **Hysteria2 的 `quic.maxIdleTimeout` 默认值是 30s，`ignoreClientBandwidth` 默认 false。**
   （依据 hysteria 官方 Full Server Config 文档）

3. **quic-go 需要约 7.5MB 的 UDP 接收缓冲区，Ubuntu 默认 `net.core.rmem_max` 为 208KB；
   缓冲区满时内核直接丢弃入站 UDP 包。**

4. **服务端日志里的 `client disconnected` 不等于用户可感知的断线。**
   手机切换基站会获得新的运营商 IP，旧连接随后以
   `timeout: no recent network activity` 过期——与真故障**逐字相同**。
   实测 72 小时 235 次 disconnected，判定为真实故障的只有 7 次（其中 4 次在深夜，
   疑为手机深度睡眠，实际计入的只有 3 次白天的）。
   **判据见下方脚本，请复核这个启发式是否合理、有没有明显的误判情形。**

5. **通过该代理登录 claude.ai，登录凭据与对话内容不会因代理而泄露**，
   因为 HTTPS 是端到端的，代理只能看到 SNI/域名、时间和流量大小等元数据。
   **这一条对用户的决策最关键，请特别确认。**

---

## 三、这个助手本轮已知的错误（供你判断其可靠性，并知道该往哪里挖）

**请假定还有没被发现的同类错误。**

1. **证据到手前就动手改。** 先读配置推断出三个"主因"并提交了改动，
   之后用户的观察推翻了其中一个（`maxIdleTimeout`）。顺序反了。
2. **时区没换算。** 日志时间戳是 UTC，用户在 UTC+8。把 `04:42 UTC` 当作
   "早上 4:42" 讲给用户，据此问用户是否在睡觉——实际是当地中午 12:42。
3. **用日志的断开次数去驳用户的亲身体验。** 用户说"就死了一次"，
   助手按原始计数说"断了四次"。用户是对的（见上方第 4 点）。
4. **生成的自签证书缺少 SAN。** 三个安装脚本用 `openssl req -x509 -subj "/CN=..."`
   但没有 `subjectAltName`。Go 自 1.15 起只认 SAN、忽略 CN，因此 sing-box
   一旦真正开启校验必然失败。文档却建议用户去做证书指纹固定——用户照做，
   客户端直接连不上。**已在分支上修复（加了 `-addext`），但服务器上现存的
   两张证书仍无 SAN。**

---

## 四、可独立验证的只读命令

```bash
export SYSTEMD_PAGER=cat

# 当前实际状态
grep -c '^ignoreClientBandwidth' /etc/hysteria/config.yaml
sysctl -n net.core.rmem_max
stat -c%a /etc/hysteria/config.yaml /etc/sing-box/config.json
systemctl is-active hysteria-server sing-box xray
ss -lntup; ss -ulnp | grep 24443

# 改动后新连接的 tx 应为 0（0 = BBR，18750000 = Brutal）
journalctl -u hysteria-server -n 20 --no-pager -o cat | grep -o '"tx": [0-9]*'

# 证书是否缺 SAN（预期：两张都缺）
for f in /etc/hysteria/cert.pem /etc/sing-box/cert.pem; do
  echo "$f: $(openssl x509 -in $f -noout -text | grep -c 'Subject Alternative Name')"
done

# 有没有入侵痕迹（此前核查结论：无）
journalctl -u ssh --since -30d --no-pager | grep -E 'Accepted (password|publickey)' \
  | grep -oE 'from [0-9.]+' | sort | uniq -c
wc -l < /root/.ssh/authorized_keys 2>/dev/null || echo 0
awk -F: '$3==0{print $1}' /etc/passwd
```

---

## 五、已知未处理项

| 项 | 现状 | 助手给的理由 |
|---|---|---|
| 两条入口客户端均 `insecure: true` / `skip-cert-verify: true` | 未处理 | 主动中间人可窃取 HY2 密码 / VLESS UUID 并读取元数据。修复需先重签带 SAN 的证书 |
| SSH root + 密码 + 22 端口 | 未处理 | 7 天内 1385 次失败爆破，fail2ban 已封 169 个 IP，无一次成功。用户纯手机运维，改密钥有锁死风险 |
| `net.core.rmem_max` = 212992 | 未处理 | 刻意押后，避免干扰当前对 `ignoreClientBandwidth` 的归因 |
| `quic.maxIdleTimeout` 未设 | 未处理 | 同上 |
| VPS 余额无到期提醒 | 未处理 | 项目文档称这是"不管它就一定会发生"的第一风险 |
| 节点真实 IP 存在于 git 历史 | 未处理 | 仓库为私有；转公开前必须清理 |

---

## 六、仓库里请重点看的文件

分支 `claude/node-connection-stability-r70aod`：

- `scripts/diagnose-hy2.sh` —— 只读诊断。**请确认它真的不做任何写操作。**
  含上述第 4 点那个"真故障 vs 换基站"的分类启发式
- `scripts/tune-hy2.sh` —— 会改配置。有备份、自测、失败回滚。
  **请检查回滚路径是否真的能在各种失败情形下复原**
- `scripts/add-tcp-entry.sh`、`scripts/install-hy2-official.sh`、`scripts/install-hy2.sh`
  —— 本轮修改过：证书 SAN、文件权限、临时文件清理、一处反了的证书复用条件
- `docs/paste-commands.md` —— 用户实际粘贴执行的命令（仓库未 clone 到服务器上）
- `docs/stability-and-security.md` —— 断线分析与安全审查
- `AGENTS.md` §0.1–§0.9 —— 实机结论记录

---

## 七、用户真正想知道的

> **"我敢用它登 Claude 吗？"**

请直接回答，并说明依据。如果结论是"可以"，请说清楚在什么前提下；
如果是"不可以"，请说明具体是哪一条风险、以及最低成本的修复方式。

**不要为了让用户安心而给出结论。** 用户已经因为过度自信的判断被误导过几次，
现在需要的是准确，而不是安慰。
