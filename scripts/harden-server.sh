#!/usr/bin/env bash
#
# harden-server.sh — 节点服务器的基础加固
#
# 做三件事，都不会影响正在运行的代理服务：
#
#   1. fail2ban          自动封禁反复猜 SSH 密码的 IP
#   2. unattended-upgrades  自动安装系统安全更新
#   3. BBR               改善服务器到目标网站的 TCP 吞吐
#
# 刻意【不做】的事：
#
#   - 不关闭 SSH 密码登录。密钥没配好就关，等于把自己锁在服务器外面。
#     配好密钥并验证能登录之后，再手动关闭（脚本末尾有说明）。
#   - 不改 SSH 端口。换端口只能挡掉无差别扫描，挡不住针对性攻击，
#     却会让你自己每次连接都要多记一个数字。fail2ban 更有效。
#
# 用法（在 VPS 上以 root 执行）：
#
#   bash harden-server.sh
#
set -euo pipefail

log()  { printf '\033[32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\033[31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "请用 root 执行：sudo bash $0"
command -v apt-get >/dev/null 2>&1 || die "这个脚本只支持 Ubuntu / Debian"

export DEBIAN_FRONTEND=noninteractive

# ---------------------------------------------------------------- 1. fail2ban

log "安装 fail2ban（自动封禁爆破 SSH 的 IP）"
apt-get update -qq
apt-get install -y -qq fail2ban >/dev/null

# Ubuntu 24.04 默认没有 /var/log/auth.log，SSH 日志只进 systemd journal，
# 所以必须显式指定 backend = systemd，否则 jail 起不来或抓不到东西。
cat > /etc/fail2ban/jail.local <<'EOF'
[DEFAULT]
backend = systemd
# 10 分钟内失败 5 次，封 1 小时
findtime = 10m
maxretry = 5
bantime  = 1h

[sshd]
enabled = true
EOF

systemctl enable fail2ban >/dev/null 2>&1 || true
systemctl restart fail2ban
sleep 2

if systemctl is-active --quiet fail2ban; then
  log "fail2ban 运行中 ✓"
else
  journalctl -u fail2ban -n 20 --no-pager >&2 || true
  warn "fail2ban 未能启动（不影响代理服务，但这项加固没生效）"
fi

# ---------------------------------------------------------------- 2. 自动安全更新

log "开启自动安全更新"
apt-get install -y -qq unattended-upgrades >/dev/null

cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF

systemctl enable --now unattended-upgrades >/dev/null 2>&1 || true
log "自动安全更新已开启 ✓"

# ---------------------------------------------------------------- 3. BBR

# 说明：HY2 隧道本身走 QUIC/UDP，BBR 管不到它。BBR 影响的是服务器
# 【出去访问目标网站】那一段 TCP。所以有帮助，但别指望翻倍。

log "开启 BBR 拥塞控制"
cat > /etc/sysctl.d/99-bbr.conf <<'EOF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF

sysctl --system >/dev/null 2>&1 || true

CURRENT_CC="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo unknown)"
if [ "$CURRENT_CC" = "bbr" ]; then
  log "BBR 已生效 ✓"
else
  warn "当前拥塞控制算法是 ${CURRENT_CC}，BBR 未生效（内核可能不支持，不影响使用）"
fi

# ---------------------------------------------------------------- 4. 状态汇总

echo
echo "================= 加固完成 ================="
echo
printf '  fail2ban        %s\n' "$(systemctl is-active fail2ban 2>/dev/null || echo inactive)"
printf '  自动安全更新    %s\n' "$(systemctl is-enabled unattended-upgrades 2>/dev/null || echo unknown)"
printf '  拥塞控制        %s\n' "$CURRENT_CC"
printf '  代理服务        %s  <- 必须还是 active\n' "$(systemctl is-active hysteria-server 2>/dev/null || echo '未安装')"
echo
echo "  查看被封禁的 IP：fail2ban-client status sshd"
echo
echo "============================================"
echo
cat <<'EOF'
下一步（可选，等你方便时再做）：改用 SSH 密钥登录

  1. 在 Termius 里生成一个 Ed25519 密钥，复制它的【公钥】
  2. 在服务器上执行（把 <公钥> 换成复制的内容）：

       mkdir -p ~/.ssh && chmod 700 ~/.ssh
       echo "<公钥>" >> ~/.ssh/authorized_keys
       chmod 600 ~/.ssh/authorized_keys

  3. 在 Termius 里把这个密钥绑到主机上，【先验证能登录成功】
  4. 确认成功之后，再关闭密码登录：

       sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
       systemctl restart ssh

  第 3 步没验证成功之前，绝对不要执行第 4 步——会把自己锁在服务器外面。
EOF
