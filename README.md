# personal-edge-proxy

> A practical personal edge proxy: **Hysteria2 as the daily entry, VLESS + REALITY + Vision as the TCP backup, and multiple egress choices such as VPS direct, Cloudflare WARP, or an optional fixed SOCKS5.**

[AI / maintainer guide → `AGENTS.md`](./AGENTS.md)

## What this project is

This repository documents the architecture I actually use for a personal VPS proxy.

The important idea is simple:

> **Inbound and outbound are different problems.**
>
> - Inbound decides **how I reliably reach my VPS**.
> - Outbound decides **which network identity / route the VPS uses for a destination**.

My normal preference is:

- **Hysteria2 (HY2)** — daily driver. It uses UDP/QUIC and performs well on my network.
- **VLESS + REALITY + XTLS Vision** — backup entry. I keep it available for networks where UDP is poor, restricted, or simply behaving badly.
- **VLESS + WebSocket behind Cloudflare Tunnel** — optional emergency entry. This is not required for the basic setup.

The server can then choose a different outbound without changing the client entry protocol.

```text
Client
  |
  +-- Hysteria2 / UDP ------------ primary
  |
  +-- VLESS + REALITY + Vision --- backup
  |
  `-- VLESS + WS + CF Tunnel ----- optional emergency path
                 |
                 v
              Xray-core
                 |
        +--------+---------+----------------+
        |                  |                |
        v                  v                v
   VPS Direct        Cloudflare WARP   Fixed SOCKS5
   normal traffic     selected sites    selected services
```

---

## Why I keep both HY2 and REALITY

I do **not** treat Hysteria2 and REALITY as competitors.

They are two independent ways to enter the same VPS:

| Entry | Transport | My role for it |
|---|---|---|
| Hysteria2 | UDP / QUIC | Primary |
| VLESS + REALITY + Vision | TCP + REALITY | Backup |
| VLESS + WS + Cloudflare Tunnel | TCP/HTTPS path | Optional emergency path |

I normally use HY2 because it has been fast and stable for me. The REALITY entry exists so that a bad UDP network does not become a single point of failure.

Xray currently implements Hysteria2 as a Hysteria protocol plus Hysteria transport, and supports VLESS with `xtls-rprx-vision` over TCP + TLS/REALITY. See the official Xray docs:

- Hysteria inbound: <https://xtls.github.io/en/config/inbounds/hysteria.html>
- Hysteria transport: <https://xtls.github.io/en/config/transports/hysteria.html>
- VLESS / Vision: <https://xtls.github.io/en/config/inbounds/vless.html>
- REALITY: <https://xtls.github.io/en/config/transports/reality.html>

---

# 1. VPS requirements

A small VPS is enough for this design.

Recommended minimum:

```text
1 vCPU
1 GB RAM
Ubuntu 24.04 LTS or Debian 12+
1 public IPv4
TCP + UDP allowed
```

For a personal proxy, **route quality matters more than the advertised port number**. A stable 200 Mbps optimized route can be more useful than an overloaded shared 1 Gbps port.

Before buying, if the provider offers a test IP / Looking Glass, test it from the network you will actually use:

```powershell
ping TEST_IP -n 50
tracert -d TEST_IP
```

Look for:

- packet loss;
- latency variance;
- evening peak-hour behavior;
- obviously bad detours;
- whether UDP is allowed;
- whether the provider permits private VPN/proxy use.

Do not assume a review from another ISP or another city represents your route.

---

# 2. Clean server baseline

SSH to the VPS:

```bash
ssh root@YOUR_SERVER_IP
```

Update packages and install a few basic tools:

```bash
apt update && apt upgrade -y
apt install -y curl ca-certificates openssl ufw unzip
```

Check the machine:

```bash
uname -a
free -h
df -h
ip -br addr
ip route
```

For long-term use, configure SSH key authentication before disabling password login.

---

# 3. Firewall

A minimal example for the two main entries:

```text
TCP 22      SSH
TCP 443     VLESS + REALITY + Vision
UDP 24443   Hysteria2
```

Example UFW policy:

```bash
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp
ufw allow 443/tcp
ufw allow 24443/udp
ufw enable
ufw status verbose
```

If your VPS provider has a separate cloud firewall / security group, open the same ports there too.

> If you change the SSH port, change the firewall rule first and verify a second SSH session before closing the first one.

---

# 4. Install Xray-core

Use the official Xray install script:

```bash
bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
```

Check it:

```bash
xray version
systemctl status xray
```

The standard install uses systemd. Prefer that over custom `nohup` + cron watchdog loops for a clean deployment.

Useful paths are typically:

```text
/usr/local/bin/xray
/usr/local/etc/xray/
/etc/systemd/system/xray.service
```

---

# 5. VLESS + REALITY + Vision backup entry

Generate a VLESS UUID:

```bash
xray uuid
```

Generate a REALITY X25519 key pair:

```bash
xray x25519
```

Generate a short ID:

```bash
openssl rand -hex 8
```

Keep these rules in mind:

```text
REALITY private key -> server only
REALITY public key  -> client
VLESS UUID          -> server + your client
shortId             -> server + your client
```

A simplified server inbound looks like this:

```jsonc
{
  "tag": "reality-in",
  "listen": "0.0.0.0",
  "port": 443,
  "protocol": "vless",
  "settings": {
    "clients": [
      {
        "id": "YOUR_VLESS_UUID",
        "flow": "xtls-rprx-vision"
      }
    ],
    "decryption": "none"
  },
  "streamSettings": {
    "network": "raw",
    "security": "reality",
    "realitySettings": {
      "target": "YOUR_REALITY_TARGET:443",
      "serverNames": ["YOUR_REALITY_SERVER_NAME"],
      "privateKey": "YOUR_REALITY_PRIVATE_KEY",
      "shortIds": ["YOUR_SHORT_ID"]
    }
  }
}
```

The Xray documentation currently uses `target`; older examples may use `dest`, which is retained as an alias.

### Choosing a REALITY target

Do not blindly copy a random domain from a tutorial. Choose a reachable TLS site and test it from your VPS. Xray provides:

```bash
xray tls ping YOUR_REALITY_TARGET
```

Read the REALITY documentation carefully before exposing it publicly. Failed REALITY authentication can be forwarded to the configured target, so target choice and fronting design matter.

---

# 6. Hysteria2 primary entry

I normally use HY2 as my primary entry.

Generate an authentication secret:

```bash
openssl rand -base64 32
```

Xray's current Hysteria2 model separates the Hysteria proxy protocol from the Hysteria transport. A simplified inbound skeleton is:

```jsonc
{
  "tag": "hy2-in",
  "listen": "0.0.0.0",
  "port": 24443,
  "protocol": "hysteria",
  "settings": {
    "version": 2,
    "users": [
      {
        "auth": "YOUR_HY2_PASSWORD",
        "email": "personal"
      }
    ]
  },
  "streamSettings": {
    "method": "hysteria",
    "security": "tls",
    "hysteriaSettings": {
      "version": 2,
      "udpIdleTimeout": 60
    },
    "tlsSettings": {
      "certificates": [
        {
          "certificateFile": "/etc/xray/certs/fullchain.pem",
          "keyFile": "/etc/xray/certs/private.key"
        }
      ]
    }
  }
}
```

For long-term deployment, use a valid TLS certificate and automate renewal. Never commit its private key to Git.

Before restarting Xray, always test the configuration:

```bash
xray run -test -config /usr/local/etc/xray/config.json
```

Then:

```bash
systemctl restart xray
systemctl enable xray
systemctl status xray
ss -lntup
```

Expected main listeners:

```text
TCP :443
UDP :24443
```

---

# 7. Outbound design: direct, WARP, and optional fixed SOCKS5

This is the part that makes the setup more than a single proxy tunnel.

I use **different egress paths for different purposes**.

A practical policy can look like this:

```text
ordinary traffic / large downloads -> VPS direct
selected AI/web services            -> Cloudflare WARP
services requiring a fixed egress   -> fixed upstream SOCKS5
```

This is an example policy, not a universal rule. Test your own routes and service requirements.

## Why use WARP for selected sites?

A VPS normally exits from a data-center ASN. Some websites — especially account-heavy, anti-abuse-sensitive, or AI services — can behave differently on data-center IP ranges, and availability can also depend on region.

WARP gives selected traffic a **Cloudflare egress path** instead of exposing the VPS's raw public IP to that destination.

Important limitations:

- WARP is **not** a residential IP.
- WARP does **not** guarantee that an account or service will accept the resulting IP.
- It should be treated as another egress option, not as a magic "clean IP" button.

I prefer **Local Proxy / WarpProxy mode**, so WARP does not replace the VPS's system-wide default route.

Conceptually:

```text
Xray routing rule
      |
      v
SOCKS5 127.0.0.1:40000
      |
      v
Cloudflare WARP client
      |
      v
Cloudflare egress
```

The VPS itself still keeps its normal default route.

Cloudflare documents Local proxy mode as `WarpProxy`, with port `40000` as the standard example, and modern Proxy mode uses MASQUE:

- <https://developers.cloudflare.com/cloudflare-one/team-and-resources/devices/cloudflare-one-client/configure/modes/>

This makes debugging much easier than forcing the entire host through WARP.

---

# 8. How I route Claude

In my own setup, **Claude / Anthropic traffic uses a separate fixed upstream SOCKS5 egress** rather than the generic VPS direct path.

Why?

I want the service to see a **stable, intentionally chosen egress** instead of whichever data-center/WARP IP happens to be active.

The shape is:

```text
Client
  |
  v
HY2 or REALITY
  |
  v
Xray on VPS
  |
  +-- claude.ai / anthropic.com
          |
          v
     fixed SOCKS5 outbound
          |
          v
       Internet
```

This is optional. If you do not have a legitimate private upstream SOCKS5, simply omit this module and use direct or WARP according to your own tests.

A simplified Xray SOCKS outbound:

```jsonc
{
  "tag": "fixed-socks",
  "protocol": "socks",
  "settings": {
    "servers": [
      {
        "address": "SOCKS_HOST",
        "port": 12345,
        "users": [
          {
            "user": "SOCKS_USERNAME",
            "pass": "SOCKS_PASSWORD"
          }
        ]
      }
    ]
  }
}
```

And a routing rule can send the relevant domains to that outbound:

```jsonc
{
  "type": "field",
  "domain": [
    "domain:anthropic.com",
    "domain:claude.ai"
  ],
  "outboundTag": "fixed-socks"
}
```

Do not copy your real SOCKS credentials into a public repository.

---

# 9. Example routing philosophy

A readable rule order is:

```text
1. block private / invalid destinations that should never leave the VPS
2. fixed-egress services -> fixed SOCKS5
3. selected AI / web services -> WARP
4. explicitly direct services -> VPS direct
5. final fallback -> chosen default
```

Xray evaluates routing rules in order, so **specific rules should appear before broad catch-all rules**.

For sensitive fixed-egress rules, I prefer **fail closed**:

```text
fixed upstream unavailable
        |
        v
connection fails
```

rather than silently falling back to the VPS public IP.

---

# 10. Client strategy

On the client, keep both entry protocols available.

For Mihomo / Clash-compatible clients, the idea is:

```yaml
proxy-groups:
  - name: VPS-ENTRY
    type: select
    proxies:
      - JP-HY2
      - JP-Reality
```

Daily use:

```text
JP-HY2
```

If UDP is poor:

```text
JP-Reality
```

The client only needs to decide **how to reach the VPS**. The VPS can still perform destination-based egress routing after the connection arrives.

---

# 11. Optional emergency entry: Cloudflare Tunnel

A third entry can be built with VLESS + WebSocket bound only to localhost, with `cloudflared` forwarding traffic to it.

Example shape:

```text
Internet
   |
Cloudflare Tunnel
   |
127.0.0.1:18080
   |
VLESS + WebSocket inbound
   |
Xray
```

This is an optional recovery path, not part of the minimal installation.

If you use a Tunnel token, store it in a root-readable file or secret manager. Never commit it.

---

# 12. Secrets that must never enter Git

Never commit:

```text
VLESS UUID used in production
REALITY private key
HY2 password
TLS private key
Cloudflare Tunnel token
WARP enrollment / organization secrets
SOCKS5 username/password
SSH private key
production config containing any of the above
```

This repository should only contain placeholders such as:

```text
YOUR_SERVER_IP
YOUR_VLESS_UUID
YOUR_REALITY_PRIVATE_KEY
YOUR_REALITY_PUBLIC_KEY
YOUR_SHORT_ID
YOUR_HY2_PASSWORD
YOUR_DOMAIN
SOCKS_HOST
SOCKS_USERNAME
SOCKS_PASSWORD
```

---

# 13. Recommended deployment order

Do not install everything at once.

```text
1. Test VPS route
2. Secure SSH + firewall
3. Install Xray
4. Bring up REALITY and verify it
5. Bring up HY2 and verify it
6. Test both client entries
7. Add WARP as a local-proxy outbound
8. Add optional fixed SOCKS5 outbound
9. Add routing rules one group at a time
10. Add optional Cloudflare Tunnel emergency entry
11. Observe before removing old nodes
```

One variable at a time makes troubleshooting dramatically easier.

---

# 14. Verification checklist

Server:

```bash
xray run -test -config /usr/local/etc/xray/config.json
systemctl status xray
ss -lntup
journalctl -u xray -n 100 --no-pager
```

Then test each path independently:

```text
HY2 -> VPS direct
REALITY -> VPS direct
HY2 -> WARP
REALITY -> WARP
HY2/REALITY -> optional fixed SOCKS5
```

Measure more than a speed-test screenshot:

- connection success rate;
- latency and variance;
- packet loss / timeouts;
- evening peak-hour behavior;
- long-lived connection stability;
- whether the final egress IP is the one you intended.

---

# 15. A note on production vs. tutorial configuration

This repository describes a **clean rebuild**, not a byte-for-byte copy of an old production server.

A server that evolved through experiments may contain old backup files, dead outbounds, cron watchdogs, or legacy scripts. For a new deployment, prefer:

- standard systemd services;
- explicit firewall rules;
- minimal configs;
- placeholders for secrets;
- one tested route change at a time.

That makes the system easier for both humans and AI coding agents to maintain.

---

## Disclaimer

This repository is for personal networking, remote access, development/testing, and learning.

Follow the laws that apply to you, your VPS provider's Acceptable Use Policy, and the terms of the services you access. Do not run an unauthenticated public proxy.

## License

MIT.
