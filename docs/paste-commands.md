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

**它救不了的**：余额耗尽 / 实例被销毁 / IP 被封 / 运营商在网络层拦截。
其中只有余额是可以提前预防的，也是唯一"不管它就一定会发生"的。
