# AGENTS.md — AI maintainer / deployer guide

Read this file before editing or deploying the repository.

## 0. Start here — field-verified findings that override older guidance

The rest of this file describes the intended architecture. These items come from
an end-to-end deployment on real hardware and **take precedence where they
conflict**. Read them before proposing a plan.

### 0.1 Do not deploy Hysteria2 via Xray

`§9` still lists "current Xray supports Hysteria2" among its assumptions. Xray
26.3.27 does advertise a `hysteria` inbound, but on a clean Ubuntu 24.04 host it
does not work, and it fails in the way that costs the most time:

```text
xray run -test          → passes
systemctl is-active     → active
journalctl -u xray      → clean startup, no error at all
ss -ulnp | grep <port>  → nothing
```

The service is alive and never binds the port. Upstream has open defects here
(XTLS/Xray-core #5921, #5619). Because this presents as "the client can't
connect", it gets chased on the client side for a long time.

**Deploy Hysteria2 with the upstream hysteria.network server instead**
(`scripts/install-hy2-official.sh`). `scripts/install-hy2.sh` is retained as the
Xray-native reference in case upstream fixes this; it now refuses to report
success when the port is unbound.

### 0.2 An active unit is not evidence a port is bound

Generalised from the above. For any "client cannot connect" report, **check the
listener first**, before touching client config:

```bash
ss -ulnp | grep <port>
```

Both install scripts poll `ss` after start and fail loudly if nothing is
listening. Preserve that behaviour in anything you add.

### 0.3 Profile A is the right default for a stable-exit goal

`§2` presents Profile C/D (WARP, fixed SOCKS5) as the preferred AI profile. That
holds when the goal is *changing* egress identity per service. When the stated
goal is **one stable, unshared exit** — the common case for account continuity —
Profile A is correct and WARP is counterproductive: its exit pool is shared and
rotates, which is exactly what such a user is leaving behind.

Ask which goal applies before recommending a profile.

### 0.4 Client-side reality on iOS

- iOS has **no user-accessible kill switch**. Always-on VPN is Android-only;
  on-demand only surfaces for IKEv2/IPsec profiles. Do not send a user hunting
  for a toggle. Use config (no `DIRECT` in the proxy group), prefer a client
  that implements `strict_route` (sing-box does, Clash by Hako does not), and
  **verify by stopping the server and observing whether pages still load**.
- Neither mihomo nor sing-box clients accept `hysteria2://` share links. They
  need a config; reference configs are in `docs/mobile-quickstart.md` §4.0.5
  and §4.0.6.
- A phone-only operator has no working recovery console. Never propose
  disabling SSH password auth, and treat lockout risk as higher than it looks.

### 0.5 A healthy server is not a working path — and phone terminals lie

From a live "the node suddenly died" incident where the server turned out to be
entirely healthy. Establish these four before touching any config:

```bash
systemctl is-active hysteria-server                 # active
ss -ulnp | grep <port>                              # bound  (see 0.2)
curl -4 -m 8 https://api.ipify.org; echo            # egress works, IP unchanged
journalctl -u hysteria-server -n 30 --no-pager -o cat
```

Then read the log, because it names the failing layer directly:

- `client connected` present → the packets arrive and auth succeeds. The config
  is not the problem; the UDP path is. `no recent network activity` is quic-go's
  idle timeout, i.e. the client's datagrams stopped arriving. Remedies in cost
  order: change port → Salamander obfs → TCP inbound (§0.6).
- no recent `client connected` at all → packets never arrive; port or protocol
  is blocked upstream.

Two traps specific to phone-only operators, both of which cost real time:

1. **`systemctl status` / `journalctl` page through `less`.** On a phone this
   looks like a hung server, and a stray `h` lands in the less help screen.
   Open every session with `export SYSTEMD_PAGER=cat`, and always pass
   `--no-pager -o cat` — the default log prefix alone is wider than the screen,
   so the actual error is scrolled off to the right.
2. **`curl` prints no trailing newline**, so a successful probe is swallowed by
   the next prompt and reads as failure. Always append `; echo`.

**Do not conclude "the carrier is blocking UDP" from a test that changed two
variables** (e.g. iPhone-on-5G vs iPad-on-Wi-Fi). Hold the device constant and
change only the network, or say the result is inconclusive.

Also: when a user is running their working proxy through an *old provider*,
testing their self-built node means switching egress IP on a live session.
That is a real cost to them, not a trivial one — see `docs/mobile-quickstart.md`
§5. Prefer diagnosis that needs no client switch, and prefer additive
server-side work (`scripts/add-tcp-entry.sh`) that disturbs nothing.

### 0.6 Xray could not serve a TCP inbound here; sing-box did

Second field failure of the same implementation on the same host, after §0.1.
On Ubuntu 24.04 with Xray 26.3.27 and 26.7.28, both a REALITY inbound and a
plain VLESS+TLS inbound rejected every connection. Excluded before giving up:
public key (re-derived from the server's own private key), shortId, serverName,
clock sync, transport field name (`method`/`raw` and `network`/`tcp`), target
site (four candidates, all TLS 1.3 + H2), six uTLS fingerprints, Vision flow on
and off, certificate readability by the service user, and an upgrade across four
months of releases. Xray's own same-version client, run on the box against its
own inbound over loopback, failed identically. The only diagnostic Xray ever
emits is `handshake did not complete successfully`.

The same VLESS+TLS inbound on **sing-box** worked first try
(`scripts/add-tcp-entry.sh`). Prefer sing-box for new server-side inbounds here:
it is also what the clients run, so field names correspond, and its errors name
causes. Keep Hysteria2 on the upstream hysteria server (§0.1).

Two rules this incident earned:

1. **A listening port is not a working entrance.** `add-reality.sh` reported
   "deployment complete" on a bound socket, which sent the user to configure two
   mobile clients against an inbound that never worked. Any script that adds an
   inbound must proxy a real request through it before claiming success, and
   roll back otherwise — `add-tcp-entry.sh` does this, and it is the difference
   between a five-minute failure and an hour of cross-device guessing.
2. **When a protocol's only error message names no cause, stop bisecting it.**
   Each further guess costs a full round trip and returns the same sentence.
   Switch implementations and keep the goal.

Default the TCP inbound to **8443**, not 443: a self-signed certificate on 443
is a strong proxy signature on the most-scanned port there is. 443 is worth
using once a domain and a real certificate exist.

### 0.7 Where things live now

| Need | File |
|---|---|
| Deploy (recommended) | `scripts/install-hy2-official.sh` |
| Deploy (Xray, see 0.1) | `scripts/install-hy2.sh` |
| Add a TCP backup inbound | `scripts/add-tcp-entry.sh` (sing-box; verified) |
| Same, REALITY (see §0.6) | `scripts/add-reality.sh` (did not work on hardware) |
| Server hardening | `scripts/harden-server.sh` |
| Phone-only walkthrough, troubleshooting | `docs/mobile-quickstart.md` |
| Record a specific deployment | `docs/handover-template.md` |

**If a user has a filled-in handover doc, ask for it before diagnosing
anything.** It carries their IP, what was installed, what was deliberately
skipped, and which failures were already ruled out. It is deliberately not in
this repo — it contains secrets.

## 1. Core model

Keep the architecture separated into two independent layers:

```text
Inbound  = how the client reaches the VPS
Outbound = how the VPS reaches a destination
```

Do not confuse inbound redundancy with outbound identity/reputation.

Typical inbound roles:

```text
Hysteria2                    primary daily entry
VLESS + REALITY + Vision     optional TCP backup
VLESS + WS + CF Tunnel       optional emergency entry
```

Typical outbound roles:

```text
VPS direct       ordinary traffic
WARP             preferred selected-AI egress
fixed SOCKS5     optional stable egress for selected services
block            explicit deny / fail-closed
```

---

## 2. Deployment profiles — recommended interpretation

Profiles are not strictly cumulative. Use the profile that matches the user's real goal.

### Profile A — minimum viable

```text
Client -> HY2 -> VPS -> Direct
```

Use when the user only wants a simple working personal node.

Trade-off: AI services see the VPS data-center egress directly. On low-reputation or heavily reused data-center ranges, users may encounter more availability challenges, CAPTCHAs, regional mismatches, or account-security checks.

Do **not** claim that this guarantees account suspension or that data-center IPs are universally unusable.

### Profile B — inbound-resilient direct egress

```text
HY2 primary
+
REALITY backup
+
VPS Direct egress
```

This reduces **inbound protocol failure risk** when UDP is poor or unavailable.

It does **not** materially improve the final egress identity versus Profile A, because destinations still see the VPS Direct IP.

### Profile C — WARP-selected AI egress

```text
HY2 -> VPS
        |- ordinary traffic -> Direct
        `- selected AI      -> WARP Local Proxy
```

Use when the user wants to reduce dependence on the VPS's raw data-center egress for AI/SaaS traffic.

This is the preferred starting profile for an AI-heavy use case.

REALITY is optional here; do not force it if HY2 is stable.

### Profile D — recommended practical AI profile

```text
HY2 -> VPS
        |- ordinary traffic          -> Direct
        |- OpenAI / ChatGPT / Codex  -> WARP
        |- Gemini / Google AI        -> WARP
        `- Claude / Anthropic        -> trusted fixed SOCKS5 (optional by policy)
```

This is the repository maintainer's **preferred practical profile** when the user primarily uses AI services and also wants a deliberately stable Claude/Anthropic egress.

Reasons:

- HY2 keeps the client side simple and fast when UDP is healthy.
- WARP decouples selected AI traffic from the VPS's raw data-center IP.
- A fixed SOCKS5 can keep selected services on a stable final egress when the user explicitly wants that property.
- Direct remains available for normal traffic and as a clean network baseline.

Do not claim:

- that WARP is residential;
- that Claude requires residential IPs;
- that this profile guarantees avoiding bans or risk checks;
- that any service must use these exact routes.

### Profile E — extra inbound resilience / icing on the cake

Start from Profile D, then optionally add:

```text
VLESS + REALITY + Vision
Cloudflare Tunnel / VLESS WS
```

Use only when the user actually wants more inbound fallback paths.

This is an **availability enhancement**, not an egress-reputation enhancement.

### Default deployment rule

If the user says only "set this up for AI use" and provides no contrary preference:

1. prefer **Profile C** as the default balanced target;
2. upgrade to **Profile D** if the user has/provides a trusted fixed egress and wants Claude/Anthropic pinned to it;
3. add REALITY only when the user wants TCP fallback or the network has real UDP problems;
4. add Cloudflare Tunnel only as an extra emergency entry.

Do not overbuild simply because example files exist.

---

## 3. Human SSH bootstrap boundary

An AI must not assume it can safely operate a fresh VPS merely because the user knows its IP/password.

Before autonomous or semi-autonomous deployment, require a one-time human bootstrap unless secure key-based access already exists.

Recommended flow:

```text
Human logs in once using provider password / console
        ↓
Human generates SSH key pair locally
        ↓
Only the public key is installed on the VPS
        ↓
Human verifies key-based SSH login
        ↓
Local AI/Agent uses the already-working ssh / SSH agent / SSH config
```

Rules:

1. SSH private keys remain on the user's local device.
2. Only the `.pub` key goes to `authorized_keys`.
3. Never ask the user to paste a root password or private key into chat, GitHub, Issues, logs, or prompts.
4. Prefer invoking the user's existing local `ssh`, SSH Agent, or `~/.ssh/config` over reading/exporting private keys.
5. Do not disable password login until key-based login is proven to work.
6. Preserve provider-console recovery where possible.
7. If secure SSH access cannot be established, stop and ask the human to complete bootstrap.

Windows example:

```powershell
ssh-keygen -t ed25519
Get-Content $env:USERPROFILE\.ssh\id_ed25519.pub | ssh root@SERVER_IP "umask 077; mkdir -p ~/.ssh; cat >> ~/.ssh/authorized_keys"
ssh root@SERVER_IP
```

The final `ssh` must succeed before unattended changes continue.

---

## 4. Resource contract

Distinguish **required for the selected profile** from **optional enhancements**.

### Required for HY2 baseline

- VPS / Linux host controlled by the user;
- root or sudo access;
- provider policy permitting intended personal VPN/proxy use;
- public server address;
- UDP reachability on selected HY2 port;
- compatible client;
- HY2 password/auth material;
- TLS material accepted by the HY2 client;
- normal VPS outbound Internet access;
- verified SSH key-based administration path before AI-controlled deployment, unless an equally secure path already exists.

Resolve first:

```text
SERVER_IP_OR_HOSTNAME
SSH_ACCESS_METHOD
HY2_UDP_PORT
HY2_TLS_CERTIFICATE_STRATEGY
CLIENT_TYPE
```

### Additional resources for WARP

Only if WARP is selected:

```text
Cloudflare WARP Linux client / account state
local proxy mode support
chosen local proxy port (repo example: 127.0.0.1:40000)
```

Do not make WARP the host-wide default route in this project.

### Additional resources for fixed SOCKS5

Only if a fixed egress is selected:

```text
SOCKS_HOST
SOCKS_PORT
SOCKS_USERNAME (if required)
SOCKS_PASSWORD (if required)
```

The upstream must be trusted and legitimately usable by the user.

### Additional resources for REALITY

Only if REALITY backup inbound is selected:

```text
VLESS UUID
REALITY X25519 private/public key pair
REALITY short ID
serverName/target strategy
reachable TCP port
```

A domain is not inherently required for REALITY itself.

### Additional resources for Cloudflare Tunnel

Only if the emergency Tunnel entry is selected:

```text
Cloudflare account
appropriate domain / tunnel configuration
secret/token handling path
```

### Not universally required

Do not require these merely to run the project:

- residential IP;
- fixed SOCKS5;
- WARP;
- REALITY;
- Cloudflare Tunnel;
- second VPS;
- IPv6.

---

## 5. Routing policy semantics

Repository example policy may use:

```text
ordinary traffic                 -> direct
OpenAI / ChatGPT / Codex         -> WARP
Gemini / Google AI               -> WARP
Claude / Anthropic               -> optional fixed SOCKS5
```

Treat this as a maintainer preference / example policy, not a universal service requirement.

Use wording such as:

> Some services may behave differently across regions or data-center IP ranges. A separate explicitly selected egress can make routing, troubleshooting, and egress stability more predictable.

Avoid unsupported claims such as:

- "this prevents bans";
- "this IP can never be blocked";
- "Claude requires residential IP";
- "WARP is a residential IP".

---

## 6. WARP architecture rule

Prefer **WARP Local Proxy / WarpProxy mode**:

```text
Linux default route -> VPS native network

Xray selected route
   -> 127.0.0.1:40000
   -> warp-svc
   -> Cloudflare WARP
```

Never make global WARP routing the baseline design.

Why:

- keeps SSH/system updates on native route;
- prevents fixed SOCKS upstream connections from accidentally traversing WARP;
- keeps Direct as a clean baseline;
- limits WARP failure impact to the routes that explicitly use it.

Official references:

- <https://developers.cloudflare.com/warp-client/get-started/linux/>
- <https://developers.cloudflare.com/warp-client/warp-modes/>

Cloudflare CLI syntax changes. Always prefer current docs plus local `warp-cli --help` over historical commands.

### Watchdog policy

Two separate concerns:

```text
Xray lifecycle             -> systemd service
WARP real-egress health    -> connectivity watchdog
```

For WARP health, test real requests through the local proxy. A live `warp-svc` process is not sufficient evidence.

Prefer a systemd timer for new/public deployments. Cron may be mentioned only as a historical/simple alternative.

---

## 7. Fixed SOCKS5 boundary

SOCKS5 itself does not provide transport encryption.

When documenting a remote fixed SOCKS5:

- state that SOCKS itself is not an encrypted VPN;
- note HTTPS still protects HTTPS application payloads end-to-end;
- if stronger link confidentiality is required, use a controlled encrypted/private path or provider that supplies one.

Do not equate "fixed/residential IP" with "encrypted" or "safer transport".

For deliberately pinned destinations, prefer fail-closed behavior unless the user explicitly requests fallback.

Do not silently reroute fixed-egress traffic to Direct when the upstream fails.

---

## 8. Audited client reality

Current Windows audit:

```text
v2rayN 7.24.2
HY2 active       -> sing-box 1.13.14
REALITY profile  -> Xray core
TUN + Rule mode
```

v2rayN is a GUI/config manager, not one specific core.

Observed model:

```text
GUI metadata + global preferences
              ↓
        v2rayN generates
              ↓
core-specific runtime config
```

Keep sing-box, Xray and Mihomo field names separate.

---

## 9. Xray source of truth

Prefer current official Xray docs over copied blog configs or remembered production aliases:

- Hysteria inbound: <https://xtls.github.io/config/inbounds/hysteria.html>
- Hysteria transport: <https://xtls.github.io/config/transports/hysteria.html>
- VLESS / Vision: <https://xtls.github.io/config/inbounds/vless.html>
- REALITY: <https://xtls.github.io/config/transports/reality.html>
- RAW: <https://xtls.github.io/config/transports/raw.html>
- SOCKS outbound: <https://xtls.github.io/config/outbounds/socks.html>
- Installer: <https://github.com/XTLS/Xray-install>

Current assumptions:

- current Xray documents a Hysteria2 inbound, but see §0.1 — it does not work
  in practice on 26.3.27; deploy HY2 with the upstream server instead;
- Hysteria version is 2;
- HY2 is the primary entry;
- REALITY/Vision is optional backup;
- current docs may use fields that differ from historical production aliases;
- REALITY current server-side docs use `target`; historical configs may show `dest`;
- current SOCKS outbound docs use flat address/port/user/pass fields; old configs may use older shapes.

If upstream schema changes, update every affected example/doc together.

---

## 10. Repository file map

```text
README.md                              Chinese human-facing architecture and profile guidance
AGENTS.md                              AI deployment/maintenance contract
examples/xray-server.example.jsonc     server-side Xray schema example
examples/v2rayn-hysteria2.example.md   audited v2rayN / sing-box HY2 client example
examples/v2rayn-reality-vision.example.md
                                       v2rayN / Xray REALITY client example
docs/warp-outbound.md                  WARP egress behavior and validation
docs/static-socks.md                   fixed SOCKS5 egress behavior
docs/mobile-quickstart.md              phone-only Profile A walkthrough + troubleshooting
docs/handover-template.md              template for recording a specific deployment
scripts/install-hy2-official.sh        recommended HY2 deploy (upstream server)
scripts/install-hy2.sh                 Xray-native HY2 deploy (see §0.1 before using)
scripts/add-tcp-entry.sh               additive VLESS+TLS TCP inbound on sing-box (verified)
scripts/add-reality.sh                 same on Xray REALITY (see §0.6 — did not work here)
scripts/test-reality.sh                loopback self-test for a REALITY inbound
scripts/harden-server.sh               fail2ban / unattended-upgrades / BBR
```

Synchronization rules:

- Xray schema change -> server example + README references + affected docs + AGENTS.
- HY2 client field change -> HY2 client example + relevant README notes.
- REALITY client field change -> REALITY example + relevant README notes.
- WARP policy/CLI change -> WARP doc + server example if needed + AGENTS.
- SOCKS schema/policy change -> static SOCKS doc + server example + AGENTS if safety boundary changes.

Never leave contradictory assumptions across files.

---

## 11. Production host is not the template

Production evolved through experiments and may contain legacy paths/backups/compatibility fields.

Public examples should follow:

```text
working production behavior
        ↓
read-only audit
        ↓
current upstream documentation
        ↓
remove secrets + legacy/dead config
        ↓
clean public example
```

Prefer clean layouts such as:

```text
/usr/local/bin/xray
/usr/local/etc/xray/config.json
systemd-managed services
explicit firewall rules
minimal configs
```

---

## 12. Secret handling

Never commit or paste live secrets.

Placeholders only:

```text
YOUR_SERVER_IP
YOUR_UUID
YOUR_REALITY_PRIVATE_KEY
YOUR_REALITY_PUBLIC_KEY
YOUR_SHORT_ID
YOUR_HY2_PASSWORD
YOUR_DOMAIN
YOUR_SERVER_NAME
YOUR_SOCKS_HOST
YOUR_SOCKS_USERNAME
YOUR_SOCKS_PASSWORD
```

Never expose:

- SSH private keys;
- root/VPS passwords;
- TLS private keys;
- Cloudflare tokens;
- production proxy credentials;
- subscription URLs;
- full production configs containing secrets.

---

## 13. Firewall / listeners

Open only selected-feature ports.

Example full profile:

```text
TCP 22      SSH
TCP 443     REALITY
UDP 24443   HY2
```

A HY2 + WARP + fixed-SOCKS Profile D does not need REALITY TCP 443 unless REALITY is actually enabled.

Preserve SSH access before firewall changes. Remember provider-side security groups may exist independently of host firewall.

---

## 14. Testing philosophy

Change one variable at a time.

Prefer checking:

- connection success rate;
- latency / variance;
- timeouts;
- peak-hour behavior;
- sustained transfer stability;
- long-lived connection behavior;
- final egress IP for each route.

Do not call a path healthy from one speed test.

### AI deployment self-check

Before saying deployment is complete, verify the features actually selected:

1. SSH key-based administration still works.
2. Server config validation passes.
3. Expected listeners are present and unnecessary example ports are closed.
4. HY2 client/server credentials match.
5. Direct egress works.
6. If WARP is enabled, a request through the local proxy reaches the intended WARP egress.
7. If fixed SOCKS5 is enabled, selected traffic reaches that fixed egress and does not silently fall back.
8. If REALITY is enabled, client/server UUID/key/short-ID/serverName parameters match.
9. Firewall/provider rules permit only the intended management/proxy ports.
10. No real secrets were written to repository, logs, Issues, or chat output.

Do not claim end-to-end client success unless the client path was actually tested.

---

## 15. Documentation style

`README.md` is for Chinese-speaking humans: explain the practical recommendation first.

`AGENTS.md` is for AI maintainers/deployers: preserve architecture, profile semantics, SSH bootstrap boundary, resource prerequisites, safety boundaries, source-of-truth links and secret hygiene.

The repository must remain understandable without private production context.
