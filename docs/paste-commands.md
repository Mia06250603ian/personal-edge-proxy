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
| 2026-09-06 | `ignoreClientBandwidth: true` | 待测(改后满 3 天再跑第 1 段) | 待确认应为 0 |

> 基线里另有 4 次落在深夜(00:46、02:02、04:12、04:08),按上面的已知局限**不计入**。

**还没做、故意留着的**(一次只动一样):

- `quic.maxIdleTimeout` 30s → 60s。**它是检测器不是药**:包真停了,超时改长只是
  晚 30 秒发现,连不回来。优先级低。
- `net.core.rmem_max` 208KB → 16MB。quic-go 要 ~7.5MB,缓冲区满了内核直接丢 UDP 包。
  值得做,但会干扰当前这次归因,等 Brutal 这轮结论出来再说。
- `obfs` Salamander 混淆。**硬切换**,所有客户端要同步加同一个密码,
  动手前先切到 TCP 备用入口(8443),免得改到一半没网。
