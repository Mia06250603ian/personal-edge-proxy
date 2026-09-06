# 可直接粘贴的运维命令

**为什么单独有这一份**:这台节点的仓库**没有 clone 到服务器上**,而且仓库是私有的
——在手机上折腾 git 凭据不值得。所以这里的每一段都是**自包含**的,复制粘贴进
SSH 终端就能跑,不依赖仓库、不依赖当前目录。

> 每次连上服务器,先跑这一句,否则 `journalctl` 会掉进 `less` 分页器,
> 在手机上看着像卡死:
>
> ```bash
> export SYSTEMD_PAGER=cat
> ```

---

## 1. 统计真正的故障次数(只读)

服务端日志有个陷阱:**手机换基站时,旧连接过期写的是
`timeout: no recent network activity`——和真故障逐字相同**,但客户端早就自己
接上了,用户毫无感觉。直接数 `disconnected` 会把 1 次故障说成几百次。

这段把两者分开,只报真正接不回来的,并换算成本地时间(默认 UTC+8):

```bash
U=hysteria-server; H=72; OFF=8
journalctl -u $U --since "-${H}h" --no-pager -o cat 2>/dev/null | awk '
 /client connected/{print $1,"C"} /client disconnected/{print $1,(/no recent network/?"T":"X")}' >/tmp/ev
: >/tmp/se; P=
while read -r t k; do e=$(date -u -d "$t" +%s 2>/dev/null)||continue
  if [ "$k" = C ]; then P=$e; elif [ -n "$P" ]; then echo "$P $e $((e-P)) $k">>/tmp/se; P=; fi
done </tmp/ev
N=$(date -u +%s); C=0
echo "==== 真正的故障（本地时间 UTC+$OFF）===="
while read -r s e d k; do
  [ "$k" = T ]||continue; [ "$d" -ge 300 ]||continue; [ $((N-e)) -ge 600 ]||continue
  R=0; while read -r a b c2 z; do [ "$a" -ge "$e" ]&&[ "$a" -lt $((e+600)) ]&&[ "$c2" -ge 180 ]&&R=1; done </tmp/se
  [ "$R" = 0 ]&&{ C=$((C+1)); echo "  ★ $(date -u -d @$((e+OFF*3600)) '+%m-%d %H:%M') 之前正常用了 $((d/60)) 分钟，然后接不回来"; }
done </tmp/se
[ "$C" = 0 ]&&echo "  这段时间没有真正的断线（其余 disconnected 都是换基站）"
echo "==== 断开总数 vs 真故障 ===="
echo "  日志里 disconnected: $(grep -c ' T\| X' /tmp/ev) 次    真正的故障: $C 次"
echo "==== tx（18750000=Brutal没关, 0=已关）===="
journalctl -u $U --since "-${H}h" --no-pager -o cat 2>/dev/null|grep -o '"tx": [0-9]*'|sort|uniq -c
rm -f /tmp/ev /tmp/se
```

**已知局限**:它分不清「真故障」和「手机深度睡眠后不再重连」。**深夜时段的结果
不要当真**,只看你醒着那几个小时的。

---

## 2. 关掉 Brutal(会改配置,有备份和回滚)

客户端配置里的 `down: "150 Mbps"` 会让**服务端**切到 Brutal 拥塞控制:按该速率
硬发,并且**故意无视丢包**。手机跑不到那个速率时,差额全变成丢包。

这段只加一个顶层键,其他一字不动;起不来会自动回滚:

```bash
F=/etc/hysteria/config.yaml
B=$F.bak.$(date +%Y%m%d%H%M%S)
cp "$F" "$B" && chmod 600 "$B" && echo "已备份到 $B"
if grep -q '^ignoreClientBandwidth:' "$F"; then echo "已经设过了，无需改动"; else
  [ -n "$(tail -c1 "$F")" ] && echo "" >> "$F"
  printf '\n# 不听客户端自报带宽，服务端一律用 BBR（不再按 150Mbps 硬发且无视丢包）\nignoreClientBandwidth: true\n' >> "$F"
  echo "已写入 ignoreClientBandwidth: true"
fi
systemctl restart hysteria-server; sleep 3
OK=0; systemctl is-active --quiet hysteria-server && for i in 1 2 3 4 5; do
  ss -ulnp 2>/dev/null | grep -q ':24443[[:space:]]' && { OK=1; break; }; sleep 1; done
if [ "$OK" = 1 ]; then echo "✅ 服务正常，UDP 24443 在监听。改动生效。"; else
  echo "❌ 起不来，正在回滚"; cp "$B" "$F"; systemctl restart hysteria-server; sleep 2
  systemctl is-active --quiet hysteria-server && echo "已回滚，节点恢复原状" || echo "回滚后仍异常，请把这段输出发我"
fi
```

**验证**(先让梯子断开重连一次,再跑):

```bash
journalctl -u hysteria-server -n 5 --no-pager -o cat | grep -o '"tx": [0-9]*'
```

`"tx": 0` = 已改用 BBR。`"tx": 18750000` = 没生效。

**要退回**:`cp /etc/hysteria/config.yaml.bak.<那串数字> /etc/hysteria/config.yaml && systemctl restart hysteria-server`

---

## 3. 实测记录

改动一次只做一样,否则结果没法归因。

| 日期 | 改了什么 | 醒着时段的真故障 | tx |
|---|---|---|---|
| 2026-09-06 之前 | (基线,什么都没改) | **3 次 / 72 小时**<br>09-05 15:33、09-06 12:34、09-06 14:55 | 234 次 18750000<br>1 次 0 |
| 2026-09-06 | `ignoreClientBandwidth: true` | 待测(改后满 3 天再跑第 1 段) | 已确认变为 `0` ✅ |

**2026-09-06 同日一并完成的清理**(与断线无关,是体检查出来的):

| 项 | 处理 |
|---|---|
| `xray.service` 在 TCP 443 上 active + 开机自启,`access.log` 0 字节 | 已 `disable --now`,443 释放,日志目录删除 |
| `/etc/sing-box/config.json` 权限 644(含 VLESS UUID) | 已改 600,**并把属主交给 `sing-box` 用户**——该服务以非 root 运行 |
| 2 个备份文件非 600(含节点密码) | 已收紧 |
| `/tmp/tcp-entry-selftest.json`(含 UUID) | 重启时随 `/tmp` 清理带走 |
| 内核更新待重启 | 已重启,两条入口开机自启均正常回来 |

排查确认**未被入侵**:30 天内 8 次成功登录全部来自本人 IP,`authorized_keys` 为空,
无额外 UID=0 账号。`linuxuser` 是 Vultr 镜像自带,密码已锁定且无密钥,登不进来
(**别给它设密码**,那会凭空多一个可爆破入口)。SSH 7 天内 1385 次失败爆破、
fail2ban 已封 169 个 IP——数字属于开着密码登录的 22 端口的正常背景噪声。

> 基线里另有 4 次落在深夜(00:46、02:02、04:12、04:08),按上面的已知局限**不计入**。

**还没做、故意留着的**(一次只动一样):

- `quic.maxIdleTimeout` 30s → 60s。**它是检测器不是药**:包真停了,超时改长只是
  晚 30 秒发现,连不回来。优先级低。
- `net.core.rmem_max` 208KB → 16MB。quic-go 要 ~7.5MB,缓冲区满了内核直接丢 UDP 包。
  值得做,但会干扰当前这次归因,等 Brutal 这轮结论出来再说。
- `obfs` Salamander 混淆。**硬切换**,所有客户端要同步加同一个密码,
  动手前先切到 TCP 备用入口(8443),免得改到一半没网。

---

## 4. 架构体检:对照教程查差距(只读)

```bash
echo "=================== 服务端体检（只读）==================="
C=/etc/hysteria/config.yaml; S=/etc/sing-box/config.json
p(){ printf '  %-30s %s\n' "$1" "$2"; }
echo "-- 教程 §3 装了什么 --"
F=$(systemctl is-active fail2ban 2>/dev/null|head -1); p "fail2ban" "${F:-未安装 ← 教程要求}"
U=$(systemctl is-enabled unattended-upgrades 2>/dev/null|head -1); p "unattended-upgrades" "${U:-未启用 ← 教程要求}"
p "BBR"                 "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"
p "私网 ACL"            "$(grep -q 'reject(10\.' $C 2>/dev/null && echo 有 || echo '没有 ← 教程要求')"
echo "-- 稳定性相关 --"
p "ignoreClientBandwidth" "$(grep -q '^ignoreClientBandwidth' $C 2>/dev/null && echo '已设 ✓' || echo 未设)"
p "maxIdleTimeout"      "$(grep -qE '^\s*maxIdleTimeout' $C 2>/dev/null && echo 已设 || echo '未设（默认30s）')"
p "obfs 混淆"           "$(grep -q '^obfs' $C 2>/dev/null && echo 已开 || echo 未开)"
p "net.core.rmem_max"   "$(R=$(sysctl -n net.core.rmem_max 2>/dev/null); [ "${R:-0}" -ge 7500000 ] && echo "$R ✓" || echo "$R ← quic-go 要 ~7500000")"
echo "-- 权限（钥匙别让全服务器可读）--"
p "hysteria 配置"       "$(stat -c%a $C 2>/dev/null)"
p "sing-box 配置"       "$(stat -c%a $S 2>/dev/null || echo 无) $( [ "$(stat -c%a $S 2>/dev/null)" = 600 ] || echo '← 含 UUID，应为 600')"
p "/tmp 里的残留 UUID"  "$(ls /tmp/tcp-entry-selftest.json 2>/dev/null || echo 无)"
p "含密码的备份数"      "$(ls $C.bak.* 2>/dev/null | wc -l) 个，其中非600: $(find /etc/hysteria /etc/sing-box -name '*.bak.*' ! -perm 600 2>/dev/null | wc -l)"
echo "-- SSH --"
p "PermitRootLogin"     "$(sshd -T 2>/dev/null | awk '/^permitrootlogin/{print $2}')"
p "密码登录"            "$(sshd -T 2>/dev/null | awk '/^passwordauthentication/{print $2}')"
p "已封禁爆破 IP"       "$(fail2ban-client status sshd 2>/dev/null | awk -F: '/Total banned/{print $2}' | tr -d ' ' || echo -)"
p "近期失败登录"        "$(journalctl -u ssh --since -7d --no-pager 2>/dev/null | grep -c 'Failed password')"
echo "-- 系统 --"
p "待安装更新"          "$(apt list --upgradable 2>/dev/null | grep -c upgradable)"
p "需要重启"            "$([ -f /var/run/reboot-required ] && echo 是 || echo 否)"
p "磁盘"                "$(df -h / | awk 'NR==2{print $5" 已用"}')"
p "本月流量"            "$(vnstat -m --oneline 2>/dev/null | cut -d';' -f11 || echo '未装 vnstat')"
echo "========================================================"
```

---

## 5. 收紧权限、清掉残留(会重启 sing-box 约 2 秒)

旧版 `add-tcp-entry.sh` 把 sing-box 配置留成 0644(里面是 VLESS UUID),
并把带 UUID 的自测配置留在 `/tmp` 且不删。仓库里已修,但服务器上跑的是旧版。

> ⚠️ 这段会重启 sing-box。**正在用 TCP 入口的话先切回 HY2**,或者等不用的时候再做。
> 收紧之后会真的重启验证一次,起不来会自动改回原权限——因为
> 「现在还能用」不等于「下次重启还能用」:进程已经打开的文件不受 chmod 影响,
> 权限设错要到下次重启才爆,那种雷最难查。

```bash
S=/etc/sing-box/config.json
echo "-- 收紧 sing-box 配置权限（里面是 VLESS UUID）--"
if [ -f "$S" ]; then
  OLD=$(stat -c%a "$S"); SU=$(systemctl show sing-box -p User --value 2>/dev/null | head -1)
  chmod 600 "$S"
  if [ -n "$SU" ] && [ "$SU" != root ] && id "$SU" >/dev/null 2>&1; then chown "$SU" "$S"; echo "  属主交给 $SU"; fi
  systemctl restart sing-box; sleep 2
  if systemctl is-active --quiet sing-box; then echo "  ✅ $OLD -> $(stat -c%a "$S")，服务正常"
  else chmod "$OLD" "$S"; systemctl restart sing-box; echo "  ❌ 收紧后起不来，已改回 $OLD"; fi
else echo "  没找到 $S"; fi
echo "-- 收紧含密码/UUID 的备份文件 --"
N=$(find /etc/hysteria /etc/sing-box -name '*.bak.*' ! -perm 600 2>/dev/null | wc -l)
find /etc/hysteria /etc/sing-box -name '*.bak.*' -exec chmod 600 {} \; 2>/dev/null
echo "  收紧了 $N 个"
echo "-- 清掉 /tmp 里带 UUID 的残留 --"
for f in /tmp/tcp-entry-selftest.json /tmp/sb-selftest.log /tmp/sb-check.log /tmp/xray-test.log; do
  [ -e "$f" ] && { rm -f "$f"; echo "  删除 $f"; }
done
echo "-- 两条入口都还活着吗 --"
printf '  hysteria-server: %s\n  sing-box:        %s\n' "$(systemctl is-active hysteria-server 2>/dev/null)" "$(systemctl is-active sing-box 2>/dev/null)"
```

---

## 6. 对照教程的差距清单(2026-09-06)

| 教程要求 | 实际 | 处理 |
|---|---|---|
| §8.1 余额提醒 —— 「不管它就一定会发生」 | 没设 | 🔴 手机日历,每月重复 |
| §3.1 真证书 | 两条入口都自签 + 关闭校验 | 🔴 证书指纹固定,见 stability-and-security.md |
| §2.1 SSH 密钥 | root + 密码 + 22 | 🔴 先验证密钥能登录再关密码 |
| §8.4 密码轮换靠脚本 | 仓库不在服务器上 | 🟠 要轮换时先 clone |
| §8.5 例行 apt upgrade | 19 个更新待装,需重启 | 🟠 找个不用网的时候做 |
| §6.4 UDP 缓冲区 | 208KB,要 7.5MB | 🟠 **故意押后**,别干扰当前实验 |

**客户端侧只能自己看**(教程 §5 / 交接单 §5):

- DNS 的 `detour` 必须指 selector,不能指 `proxy` —— 否则切到 tcp 之后 DNS 还在往 HY2 那条死路发
- selector / proxy-group 里不能有 `DIRECT` —— iOS 没有系统级 kill switch
- mihomo 的「UDP 兜底」选最严格那档

---

## 7. 一键恢复 `/fix`（已部署 2026-09-06）

**背景**：用户纯手机运维。Vultr 面板的网页控制台（View Console）能打开，
但**手机上打字非常困难**——所以退路是存在的，只是"难用到关键时刻用不上"。

解法是把恢复操作压缩成 6 个字符。服务器上已部署：

```text
/root/good/hysteria.yaml    已知良好的 HY2 配置快照
/root/good/singbox.json     已知良好的 sing-box 配置快照
/fix                        恢复脚本
```

**已在真机验证**（2026-09-06）：`sh /fix` 实跑通过，两服务重启后 active、端口正常监听。

**出事时**（SSH 进不去，只能用 Vultr 网页控制台）：

```sh
sh /fix
```

它会把两份配置从快照还原、修正权限与属主、重启两个服务、打印状态。

**维护**：以后确认节点状态良好时，重新取一次快照：

```bash
cp /etc/hysteria/config.yaml /root/good/hysteria.yaml
cp /etc/sing-box/config.json /root/good/singbox.json
chmod 600 /root/good/*
```

⚠️ **绝不要在配置已经坏掉的时候更新快照**，那会把坏配置存成"良好"。

**手机进控制台的坑**：那是 `vultr login:` 登录界面，不是已登录的终端——要先输
`root` 和密码才有 shell。而且 iOS 键盘会自动大写首字母（`sh` 被打成 `SH`，
Linux 区分大小写，必然失败），密码栏又完全不回显，看不出被改成了什么。
**先去「设置 → 通用 → 键盘」关掉自动大写和自动更正。**

**它救不了的**：余额耗尽 / 实例被销毁 / IP 被封 / 运营商在网络层拦截。
其中只有余额是可以提前预防的，也是唯一"不管它就一定会发生"的。

---

## 8. 重签一张带 SAN 的证书（做证书指纹固定的前提）

**为什么需要**：早期脚本生成的自签证书只有 `-subj "/CN=..."`，没有
`subjectAltName`。Go 从 1.15 起**只认 SAN、完全忽略 CN**，所以那种证书在任何
真正开启校验的客户端上都用不了——按文档去做证书指纹固定，客户端必然连不上。

**这一步不会影响现有客户端**：客户端还是 `insecure: true` / `skip-cert-verify: true`
时根本不验证证书，所以换证书对它没有影响。只会让 sing-box 重启约 2 秒。

> ⚠️ 正在用 TCP 入口的话，先切回 HY2 再做。

```bash
D=/etc/sing-box; SNI=www.bing.com; T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
B=$D/backup-$(date +%Y%m%d%H%M%S); mkdir -p "$B"
cp "$D/cert.pem" "$D/key.pem" "$B/" && chmod 600 "$B"/* && echo "已备份旧证书到 $B"
openssl req -x509 -nodes -newkey ec:<(openssl ecparam -name prime256v1) \
  -keyout "$T/key.pem" -out "$T/cert.pem" -subj "/CN=$SNI" \
  -addext "subjectAltName=DNS:$SNI" -days 3650 >/dev/null 2>&1
if ! openssl x509 -in "$T/cert.pem" -noout -text 2>/dev/null | grep -q "DNS:$SNI"; then
  echo "❌ 新证书生成失败或缺 SAN，原证书未动，退出"; exit 1
fi
echo "✅ 新证书已生成并含 SAN，开始替换"
mv "$T/cert.pem" "$D/cert.pem"; mv "$T/key.pem" "$D/key.pem"
chmod 644 "$D/cert.pem"; chmod 600 "$D/key.pem"
SU=$(systemctl show sing-box -p User --value 2>/dev/null | head -1)
[ -n "$SU" ] && [ "$SU" != root ] && id "$SU" >/dev/null 2>&1 && chown "$SU" "$D/cert.pem" "$D/key.pem" && echo "  属主交给 $SU"
systemctl restart sing-box; sleep 3
OK=0; systemctl is-active --quiet sing-box && ss -lntup 2>/dev/null | grep -q ':8443' && OK=1
if [ "$OK" != 1 ]; then
  echo "❌ 起不来，回滚旧证书"; cp "$B/cert.pem" "$B/key.pem" "$D/"
  chmod 644 "$D/cert.pem"; chmod 600 "$D/key.pem"
  [ -n "$SU" ] && chown "$SU" "$D/cert.pem" "$D/key.pem" 2>/dev/null
  systemctl restart sing-box; sleep 2
  systemctl is-active --quiet sing-box && echo "已回滚，TCP 入口恢复原状" || echo "回滚后仍异常"
  exit 1
fi
echo "✅ sing-box 正常，TCP 8443 在监听"
echo; echo "===== 新指纹（Clash/mihomo 用）====="
openssl x509 -in "$D/cert.pem" -noout -fingerprint -sha256 | sed 's/.*=//; s/://g' | tr 'A-F' 'a-f'
echo; echo "===== sing-box 用的 certificate 数组 ====="
awk '{a[NR]=$0} END{print "\"certificate\": ["; for(i=1;i<=NR;i++) printf "  \"%s\"%s\n",a[i],(i<NR?",":""); print "]"}' "$D/cert.pem"
```

**先验证一次**（`OK` 说明校验真的能过；旧的无 SAN 证书在这一步会失败）：

```bash
openssl verify -CAfile /etc/sing-box/cert.pem \
  -verify_hostname www.bing.com /etc/sing-box/cert.pem
```

### 客户端怎么写

**sing-box**：把 `"insecure": true` 换成上面输出的 `"certificate": [...]` 整段。

**Clash / mihomo**：

```yaml
    skip-cert-verify: false
    fingerprint: <上面输出的那 64 位十六进制>
```

⚠️ **`fingerprint` 和 `client-fingerprint` 是两回事**：前者是证书指纹固定，
后者是 uTLS 浏览器指纹伪装。写错了固定不生效，还以为配好了。

⚠️ mihomo 若连不上，可试把 `skip-cert-verify` 改回 `true` 但**保留
`fingerprint`**——它一旦设了就走指纹校验，保护仍在。（sing-box 那边已实测；
mihomo 的内部行为未同等验证。）

**固定之后服务器再换证书 = 所有客户端立刻连不上**，重签后务必同步更新客户端。

---

## 9. 两条入口**同时**挂掉：共因排查（只读）

`docs/stability-and-security.md` 那条判断反过来用，就是这一节的全部依据：

> 「TCP 8443 一直稳定 → 服务器宕机、服务崩溃、流量超额、磁盘满、机房路由、
> 密码错——全部排除，**这些会让两条一起挂**」

两条入口同机器、同出口 IP，只差 UDP/TCP。**两条一起死 = 故障在它们的共用部分**。
所以下面这些一律**不用查**，它们最多只能干掉一条：

| 已排除 | 因为它只影响 |
|---|---|
| 运营商/中间设备拦 UDP、Brutal、`maxIdleTimeout`、`rmem_max` | 只有 HY2（UDP 24443） |
| 证书重签、`fingerprint` 指纹固定不同步 | 只有 TCP 8443（sing-box） |
| obfs 密码没同步 | 只有 HY2 |

剩下的共因只有六类：**机器没了 / 两个服务没起来 / 磁盘满 / 出网断了 /
防火墙或 IP 被整体封 / 客户端与所处网络本身**。

### 9.1 先用 SSH 分层——这一步比任何日志都快

SSH 走 TCP 22，**不经过代理**。它通不通，直接把故障切成两半：

```text
手机 SSH 连 22 端口
├─ 通 ────────────► 机器活着、IP 没被整体封 → 跑 9.2 的体检
└─ 不通 ──► 换一个网络再试（蜂窝 ↔ Wi-Fi，同一台手机，只换网络）
    ├─ 换了就通 ──► 是你刚才那个网络在拦，服务器没事
    └─ 都不通 ──► 开服务商网页控制台（Vultr: View Console）
        ├─ 能进，机器活着 ──► IP 被封 / 防火墙把自己关外面了
        │                     先 `sh /fix` 恢复服务（§7），仍不通则考虑换 IP
        └─ 进不去 / 实例 suspended、destroyed ──► 余额或被服务商停机（教程 §8.1）
```

⚠️ **在确定是哪一层之前，一行客户端配置都别改。** 两条入口一起挂时改客户端，
等于在一个本来就不通的路径上叠新变量，之后没法归因。

⚠️ 换网络测试时**手机不要换**。教程 §0.5 记过：一次改两个变量
（iPhone-5G vs iPad-WiFi）得出的结论不成立。

### 9.2 服务器上的共因体检（只读，自包含）

SSH 或网页控制台进去之后跑这一段。它不改任何东西：

```bash
export SYSTEMD_PAGER=cat
p(){ printf '  %-26s %s\n' "$1" "$2"; }
echo "============ 两条入口同时挂：共因体检（只读）============"
echo "-- 1 机器本身（磁盘满会同时干掉两个服务）--"
p "开机多久"     "$(uptime -p 2>/dev/null)"
p "磁盘 /"       "$(df -h / | awk 'NR==2{print $5" 已用，剩 "$4}')"
p "inode"        "$(df -i / | awk 'NR==2{print $5" 已用"}')"
p "内存"         "$(free -m | awk '/Mem:/{print $3"/"$2" MB"}')"
p "本月流量"     "$(vnstat -m --oneline 2>/dev/null | cut -d';' -f11 || echo '未装 vnstat')"
echo "-- 2 两个服务 --"
for u in hysteria-server sing-box; do
  A=$(systemctl is-active "$u" 2>/dev/null); E=$(systemctl is-enabled "$u" 2>/dev/null)
  p "$u" "${A:-查不到} / 自启 ${E:-查不到}"
done
echo "-- 3 端口真在监听吗（active ≠ 监听，见教程 §6.1.5）--"
p "UDP 24443"    "$(ss -ulnp 2>/dev/null | grep -c ':24443[[:space:]]') 个监听"
p "TCP 8443"     "$(ss -lntp 2>/dev/null | grep -c ':8443[[:space:]]') 个监听"
echo "-- 4 机器自己还能出网吗 --"
p "出口 IP"      "$(curl -4 -m 8 -s https://api.ipify.org || echo '取不到 ← 机器出网就断了')"
echo "-- 5 防火墙（会一次挡掉两条）--"
ufw status 2>/dev/null | head -8
echo "-- 6 两个服务最后说了什么 --"
journalctl -u hysteria-server -n 12 --no-pager -o cat 2>/dev/null
echo "  ---"
journalctl -u sing-box -n 12 --no-pager -o cat 2>/dev/null
echo "-- 7 最近动过什么（共因往往是最后一次改动）--"
journalctl --list-boots --no-pager 2>/dev/null | tail -3
grep -E ' (install|upgrade|remove) ' /var/log/dpkg.log 2>/dev/null | tail -5
ls -lt /etc/hysteria/ /etc/sing-box/ 2>/dev/null | head -12
echo "========================================================"
```

怎么读：

| 体检结果 | 结论 | 下一步 |
|---|---|---|
| 磁盘 100% 或 inode 满 | 共因找到了 | 清日志（教程 §0.9 记过 xray `error.log` 无轮转涨到撑爆盘） |
| 两个服务都不是 active | 配置或环境坏了 | `sh /fix`（§7）从已知良好快照恢复 |
| 服务 active 但两个端口都没监听 | 端口被抢 / 绑定失败 | 看第 6 段日志，`ss -lntup` 查谁占了 |
| 服务和端口都正常、出口 IP 也拿得到 | **服务器完全健康** | 故障在路径或客户端 → 回 9.1 用 SSH 分层 |
| 出口 IP 取不到 | 机房网络或路由 | 服务商面板 / 工单 |
| 第 7 段显示刚 upgrade 或刚重启过 | 最后一次改动就是嫌疑人 | 按那次改动回滚 |

### 9.3 服务器全健康、SSH 也通，两条却都连不上

这种组合只剩客户端侧的共用因素——**两条入口在客户端也共用东西**：

- **DNS 的 `detour` 指到了具体节点而不是 selector**。切换节点后 DNS 还往旧的那条
  死路发，两条看起来就都不通（§6 的客户端清单里记过这一条）。
- **selector / proxy-group 整个被禁用或选到了空节点**。
- **手机装了两个 VPN 类 App，另一个抢走了 tun**。iOS 同时只允许一个。
- **服务器 IP 被所在网络整体封锁**——此时 SSH 从这个网络也连不上，
  9.1 已经把它分出去了。

排查顺序：先在**另一个网络**上用**同一台手机**试；再用**另一台设备**试同一份配置。
两台都不通 = 配置或服务器；只有一台不通 = 那台设备。

### 9.4 关于 `/fix` 救不了的四件事

`sh /fix`（§7）只还原配置并重启服务。**余额耗尽 / 实例被销毁 / IP 被封 /
运营商在网络层拦截**，它一样救不了。其中只有余额是可以提前挡掉的，
也是教程 §8.1 说的那件「不管它就一定会发生」的事——**没设日历提醒就现在设**。

---

## 10. 2026-09-06 晚：这次到底改了什么、量到了什么

留档，免得下次从头推一遍。

### 服务端改动（两项，都已生效）

| 改动 | 状态 | 怎么退回 |
|---|---|---|
| **开 Salamander 混淆** | 已开。所有客户端必须配同一个混淆密码 | `sed -i '/^obfs:/,+3d' /etc/hysteria/config.yaml` 然后重启 |
| **UDP 缓冲区 208KB → 16MB** | 已生效（`/etc/sysctl.d/99-hy2.conf`） | `rm /etc/sysctl.d/99-hy2.conf; sysctl --system` 然后重启 |

缓冲区那一项**有可见效果**：上传从个位数变成 48 Mbps。它治的是「你 → 服务器」
这个方向，这一项不必回退。

### 量到的数据（iPad / Wi-Fi / 23:00 北京时间）

```text
下载  5.74 Mbps      上传 48.4 Mbps
延迟  358 ms         抖动 226 ms
丢包  50 %
sing-box 节点测速：proxy-obfs 2058ms   tcp 1941ms
```

对照（手机 / 5G / 旧机场 / 同一时段）：延迟 142ms、抖动 51ms、丢包 2.1%。
⚠️ 这两组换了设备也换了网络，**不是严格对照**，只能当参考。

### 逐项排除（每条都有实测支撑，别再重复查）

| 怀疑 | 排除依据 |
|---|---|
| 服务器负载 | `load average 0.00` |
| 机房出口 | `ping 1.1.1.1` → 0.96ms，0% 丢包 |
| Brutal 拥塞控制 | 日志 `tx: 0`（BBR 在跑） |
| UDP 接收缓冲区 | 已 16MB，上传 48 Mbps 即其效果 |
| 混淆开销 | `tcp` 入口不走混淆，同一时刻同样 1941ms |
| 协议（UDP vs TCP） | 两条几乎一样慢 |
| 配置损坏 | 完整读过一遍，干净 |

剩下的是**「中国 ↔ 这台服务器」的回程线路**。上传快、下载丢一半，方向性也对得上。

### 还缺的那一块

**只在 23:00（深夜高峰）测过一次。** 缺白天的对照：

- 白天正常 → 是高峰拥塞，接受它，或换中国优化线路的商家
- 白天一样差 → 线路本身不行，换机房；别再在配置上花时间

**拿到白天的数字之前，不要再改任何配置。**

### 顺带发现、尚未处理

- 整份 `config.yaml` **没有 `quic:` 段**，所以 `maxIdleTimeout` 仍是默认 30s。
  与速度无关，与手机断线有关（见 `AGENTS.md` §0.8）。
- 手机（蜂窝）两条入口都不通的问题**仍未解决**，混淆开了但**从未在手机上验证过**
  —— 客户端那边还没配。见 `AGENTS.md` §0.10。
