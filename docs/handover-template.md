# 交接手册模板

节点搭好之后，**这套东西的实际状态没有任何地方记录**。教程告诉你「怎么搭」，
但三周后你回来排错时需要的是「我这台到底是什么状态」。

这份模板就是补这个缺口。**复制一份填好，存在你自己能找到的地方**
（备忘录、密码管理器、私有仓库）。

## ⚠️ 填好的那份不要提交到公开仓库

里面有 IP 和密码。放进 Git 就等于公开了，而且历史记录删不干净。
这份模板本身用占位符，可以放仓库；填好的那份不行。

也不要截图发给任何人，包括 AI 助手——**要粘贴排错信息时，先把密码涂掉。**

---

# 我的节点 · 交接手册

> 最后更新：`YYYY-MM-DD`

## 1. 一句话架构

```text
手机 / 平板
  ↓ Hysteria2 (UDP)
VPS（服务商 / 地区）
  ↓ Direct
Internet
```

对应仓库 README 的 **Profile A**。故意没有装 WARP、REALITY、固定 SOCKS5——
目标是「单一、稳定、不变的独享出口」，加层数只会让排错变难。

## 2. 关键参数

| 项目 | 值 |
|---|---|
| 服务商 / 地区 | `例：Vultr / Singapore` |
| 实例规格 / 月费 | `例：1 vCPU 1GB / $5` |
| **IP** | `YOUR_SERVER_IP` |
| **端口** | `24443 (UDP)` |
| 协议 | Hysteria2（官方服务端，非 Xray） |
| SNI / 伪装域名 | `www.bing.com` |
| 证书 | 自签，客户端必须 `insecure` / `skip-cert-verify` |
| **节点密码** | `存密码管理器，不要写在这里` |
| SSH | `root` + 密码，端口 22 |
| 系统 | `例：Ubuntu 24.04 LTS x64` |

**IP 信誉基线**（换 IP 后重新记一次）：

| 检测站 | 分数 | 日期 |
|---|---|---|
| Scamalytics | `例：0 / Low Risk` | |
| ping0.cc | `例：23% 纯净` | |
| IPPure | `例：64%`（机房 IP 天然偏高，正常） | |

## 3. 服务端装了什么、改过什么

- [ ] Hysteria2 官方服务端（`install-hy2-official.sh`）
- [ ] 私网 ACL（禁止经隧道访问机房内网 / 回环）
- [ ] fail2ban（SSH 爆破自动封禁）
- [ ] unattended-upgrades（自动安全补丁）
- [ ] BBR
- [ ] 密码轮换记录：`YYYY-MM-DD 换过一次`

**没有做的（以及为什么）：**

- SSH 密钥登录 —— 有 fail2ban 挡着，且手机端配密钥的锁死风险大于收益
- 关闭 SSH 密码登录 —— 同上，**密钥没验证成功前绝对不要关**
- 备用入口 —— 待办，见第 7 节

## 4. 客户端

| 设备 | App | 配置位置 |
|---|---|---|
| `例：iPad` | `例：Clash by Hako` | 配置 → `名称` → 编辑源码 |
| `例：iPhone` | | |

配置模板见 `docs/mobile-quickstart.md` §4.0.5（Clash / mihomo）和
§4.0.6（sing-box）。

**换密码时要改的地方**：每个客户端配置里的 `password` 那一行，**只改这一行**。

## 5. 泄露自查结果

最后一次全量检查：`YYYY-MM-DD`

- [ ] 出口 IP 正确
- [ ] 无 IPv6（`ipv6: false` / `"strategy": "ipv4_only"`）
- [ ] WebRTC：`browserleaks.com/webrtc` 显示 No Leak
- [ ] DNS：`browserleaks.com/dns` 检测到的服务器全部归属 VPS 服务商
- [ ] UDP 兜底设为最严格档
- [ ] proxy-group 里没有 `DIRECT`
- [ ] **断线实测**：停掉服务后网页打不开（做法见 §4.2）

> 换客户端、换配置之后，**断线实测要重跑**。

## 6. 常用命令

```bash
# 状态
systemctl status hysteria-server
ss -ulnp | grep 24443              # 端口真的在监听吗（排错第一步）
journalctl -u hysteria-server -n 50

# 重启
systemctl restart hysteria-server

# 换密码（随机生成并应用，不用自己想）
cd ~ && NEWPASS=$(openssl rand -hex 12) && bash hy2.sh --password "$NEWPASS"

# 被封禁的爆破 IP
fail2ban-client status sshd
```

## 7. 待办

- [ ] **每月查一次服务商余额** —— 归零会销毁实例并永久回收 IP
- [ ] **退掉旧线路之前**，加一条 TCP 备用入口（VLESS + REALITY / 443）
- [ ] 其他：

## 8. 这套东西踩过的坑（排错先看这里）

| 症状 | 真正的原因 |
|---|---|
| 客户端连不上，但服务 `active`、日志无报错 | **端口根本没监听**。先 `ss -ulnp`，别动客户端 |
| 服务起来又立刻退出 | 配置文件属主不对，`hysteria` 用户读不了自己的配置 |
| SSH 报 `unknown node or service` | 主机名里混进了多余字符（复制 IP 时带上的） |
| SSH 密码怎么输都不对 | iOS 键盘的自动大写 / 智能标点改写了密码 |
| 客户端报 `required GeoIP geodata` | 该客户端强制要这个数据文件，**且 VPN 开着时下不了** |
| 客户端报「不是有效的 YAML」 | 配置贴到了文件末尾，`proxies` 出现两次；或列表缩进不一致 |
| 速度偏慢 | hysteria2 没设 `up` / `down` 带宽 |

完整版见 `docs/mobile-quickstart.md` §6。

## 9. 如果一切都没了，怎么重建

1. 开一台新 VPS（同一地区，**别换国家**）
2. 拿到 IP 先去 `scamalytics.com/ip/<IP>` 验，不合格就销毁重开
3. SSH 上去跑 `install-hy2-official.sh`，再跑 `harden-server.sh`
4. 把输出的分享链接导入客户端
5. 按 `docs/mobile-quickstart.md` §5 的流程平滑迁移，**不要当天就切**

**从零到能用约 30 分钟**，前提是这份手册和那两个脚本还在。
