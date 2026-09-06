# 反向审计结果（自查，2026-09-06）

针对上一轮审计要求的逐项复核结论。分支 `claude/node-connection-stability-r70aod`。

---

## 最终结论：登录 claude.ai

**当前状态：可以登录。**
**修复 insecure / skip-cert-verify 之后：可以登录。**

理由：TLS 在用户手机与 Anthropic 服务器之间建立，代理只转发密文。
**代理层配置正确与否，不影响 Claude 登录凭据与对话正文的保密性。**

代理能看到的仅为元数据：目标 IP、SNI（域名明文）、时间、流量大小。
这部分元数据对用户当前正在使用的机场运营方本来就完全可见，
因此换用自建节点是净改善，不是新增风险。

MITM 风险的实际后果分层：

| 凭据 | 主动 MITM 下 | 后果 |
|---|---|---|
| HY2 密码 | 会泄露 | 节点被他人滥用 → IP 信誉受损 |
| VLESS UUID | 会泄露 | 同上 |
| **Claude 凭据 / 对话** | **不会泄露** | 受 HTTPS 保护，与代理层无关 |

---

## 一、已证实（有一手证据）

**`tx` 字段 = Brutal 拥塞控制生效。** hysteria 服务端源码是硬分支：

```go
if actualTx > 0 {
    congestion.UseBrutal(h.conn, actualTx, ...)
} else {
    congestion.UseConfigured(h.conn, h.config.CongestionConfig.Type, ...)
}
el.Connect(h.conn.RemoteAddr(), id, actualTx)   // 日志里的 tx 就是 actualTx
```

- `actualTx = min(服务端最大发送速率, 客户端上报接收能力)`，单位 bytes/s
- 实测 72 小时：234/235 条连接为 `tx: 18750000`（×8 = 150 Mbps，与客户端
  `down_mbps: 150` 相符）
- 已应用 `ignoreClientBandwidth: true`，新连接 `tx` 已变为 `0`

**注意一个前提**：`tx=0` 走 `UseConfigured`，用的是配置里的 `congestion.type`。
该节点配置无 `congestion` 块，故为默认 BBR。**"tx=0 即 BBR" 只在未自定义
拥塞控制时成立**，此前脚本里的表述略糙。

这是本轮唯一**已证实**的配置缺陷，也是唯一已修复的。

---

## 二、此前判断错误（三项，已更正）

### 1. `maxIdleTimeout`：只改服务端几乎无效

此前称"放宽到 60s 能吃掉绝大多数瞬断"。**错误，且有两层原因：**

- **RFC 9000 §10.1**：idle timeout 取两端 advertise 值的**最小值**。
  客户端默认 30s，故服务端改成 60s 后**实际生效仍是 30s**。
- **客户端默认 `keepAlivePeriod: 10s`**，QUIC 收到任何包都会重置 idle 计时器。
  因此只要客户端存活且包能到达，服务端 30s 永不触发。
  `no recent network activity` 的真实语义是**30 秒内一个包都没到达**
  （客户端被系统挂起，或路径丢包），**不是"用户闲置"**。

该项**未实际应用到服务器**（体检显示仍为"未设"），无损害。但脚本与文档中
的建议是错的。

### 2. `rmem_max`：是推测，不是诊断结论

此前把"默认值不理想"表述成了"断线原因之一"。**证据链只有一环**
（`net.core.rmem_max = 212992`），从未验证：

- 日志中是否出现 `failed to sufficiently increase receive buffer size` —— 未确认
- `nstat` 的 `UdpRcvbufErrors` 是否 > 0 —— 未确认

概念也混淆了：`rmem_max` 只是上限；quic-go 会 `setsockopt(SO_RCVBUF)` 索要
约 7MB，要不到则打印告警；缓冲区溢出才丢包；QUIC 自身还有 flow control，
是另一层。**上限低 ≠ 正在溢出。**

正确表述：不理想的默认值，值得改，**但无任何证据表明它导致了本次断线**。

### 3. `diagnose-hy2.sh` 并非完全只读

`nstat -az` 不带 `-s` 时会改写自身历史文件（`~/.nstat.uN`），影响之后其他
工具读取 nstat。**已改为 `-asz`。**

其余确认无写副作用：仅写 `mktemp` 临时文件并由 `trap` 清理；对配置只用
`grep`/`sed -n`/`stat` 读取；无 `systemctl start|stop|restart`、无
`sysctl -w`、无 `apt`。脚本中出现的 `systemctl`/`apt` 字样是打印给用户的
建议文本，非执行。另有一次对外请求 `curl https://api.ipify.org`。

---

## 三、`tune-hy2.sh` 的问题（建议暂不使用）

用户只有手机、无救援控制台，以下按高严重度处理：

| 问题 | 说明 |
|---|---|
| **无配置语法预检** | hysteria 无 `check` 子命令，只能"重启后看 is-active + 端口 + 自测" |
| **rollback 失败无兜底** | 回滚后服务仍起不来时，仅打印一行警告，**服务留在停止状态** |
| **自测端口硬编码 10809** | 被占用则自测失败 → **触发假回滚**，把本来正确的配置退回去 |
| **会改全局 sysctl** | 写 `/etc/sysctl.d/` 并 `sysctl --system`，影响整台机器的内核参数，超出"调 hysteria"范围，此前未明说 |
| **密码含 YAML 特殊字符会生成非法配置** | 密码从旧配置解析后重新写入；安装脚本限制了字符集，手工设过密码则不保证 |
| 备份文件名精确到秒 | 同一秒内重复执行会覆盖。概率极低 |

**已确认不存在的风险**：不碰 SSH / 防火墙 / 网络接口，不会锁死；
不删除证书与密码；`set -e` 已实测不会截断配置生成
（`A && B` 失败不终止脚本）。

用户实际需要的那一项（`ignoreClientBandwidth`）已通过单独的安全粘贴命令
完成，未使用该脚本。

---

## 四、其他各项

| 项 | 结论 |
|---|---|
| **`disconnected` 计数** | 只能是 heuristic。手机切 Wi-Fi/蜂窝、4G/5G 切换、NAT 映射变化、基站切换、手机睡眠、路径变化，**全部产生逐字相同的 `timeout: no recent network activity`**，服务端无法区分。72 小时 235 次中判定 7 次为故障，其中 4 次在深夜（几乎肯定是手机深度睡眠误判），可信的仅白天 3 次。更可靠的证据只在客户端侧。时区已修（`--tz` 默认 +8） |
| **证书 SAN** | Go 1.15+ 确实只认 SAN、忽略 CN，已证实（用户按建议做指纹固定后客户端直接连不上）。分支已加 `-addext "subjectAltName=DNS:${SNI}"` 并验证生成的证书带 SAN。**遗留缺陷：`openssl req` 直接写目标路径，生成失败可能覆盖现有可用证书，尚未修复**。`add-tcp-entry.sh` 中判反的证书复用条件已修正。服务器上现存两张证书无 SAN，但不影响当前 `insecure: true` 的客户端 |
| **停用 Xray** | 安全，建议保留停用。无 systemd 依赖；停用并重启后 443 仍无人监听，两条入口均自动恢复。**未检查 iptables NAT 规则是否有引用**（`iptables -t nat -L -n` 可确认） |
| **sing-box 权限** | 正确。`systemctl show sing-box -p User` 实测为 `sing-box`，非 root 运行，故属主必须一并移交。且当场重启验证过——`chmod` 不影响已打开的文件句柄，配错要到下次重启才暴露 |
| **SSH** | 有风险但**建议暂不修改**。1385 次失败 / 0 次成功，fail2ban 已封 169 IP。无救援控制台时，改 SSH 的失败模式是永久失去服务器，不改的失败模式只是继续被无效爆破 |
| **VPS 本身** | 无入侵迹象：30 天 8 次成功登录全部来自本人 IP，`authorized_keys` 为空，无额外 UID=0 账号，`linuxuser` 密码已锁定且无密钥 |

---

## 五、服务器当前状态

已生效：`ignoreClientBandwidth: true`、xray 已停用且 443 空闲、
sing-box 配置 600 且属主正确、备份文件 600、系统已更新并重启、
两条入口开机自启正常。

**刻意未改**：`maxIdleTimeout`（未设）、`net.core.rmem_max`（212992）、
`obfs`（未启用）、SSH 策略、客户端 TLS 校验（仍 `insecure: true`）。

---

## 六、建议进一步复核的点

1. `tx=0 → UseConfigured → BBR` 的默认值链条（未配 `congestion` 块时的默认类型）
2. RFC 9000 idle timeout 取最小值的结论，及其对"只改服务端"的影响
3. `tune-hy2.sh` 的 rollback 失败兜底应该怎么设计才对无救援控制台的用户安全
4. 证书生成的原子性（先写临时文件再替换）
5. 上述 heuristic 是否存在更可靠的服务端侧替代方案

---

## 七、仍待观察的实验

只改了 `ignoreClientBandwidth` 一项。基线：改动前 72 小时内，用户醒着时段
判定为真实故障 3 次（09-05 15:33、09-06 12:34、09-06 14:55）。
需在 09-09 之后重跑统计对比。**在此期间不应再改动 HY2 配置，否则无法归因。**
