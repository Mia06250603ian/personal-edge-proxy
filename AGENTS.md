# AGENTS.md — AI maintainer guide

Read this file before editing or deploying the repository.

## Project model

Keep the architecture separated into two layers:

```text
Inbound  = how the client reaches the VPS
Outbound = how the VPS reaches a destination
```

Preferred inbound roles:

```text
Hysteria2                    primary daily entry
VLESS + REALITY + Vision     optional TCP backup entry
VLESS + WS + CF Tunnel       optional emergency entry
```

Preferred outbound roles:

```text
VPS direct       normal traffic
WARP             optional selected-destination egress
fixed SOCKS5     optional fixed-egress destinations
block            explicit deny / fail-closed routes
```

Do not collapse the design into one global tunnel.

## Deployment profiles — do not overbuild by default

The repository documents several layers, but they are not all mandatory.

Use the smallest profile that satisfies the user's goal.

### Profile A — minimal / lazy path

```text
Client
  -> Hysteria2
  -> VPS
  -> Direct
```

This is a complete valid deployment.

If HY2 is stable on the user's network, the AI may stop here. Do **not** force deployment of REALITY, WARP, fixed SOCKS5, Cloudflare Tunnel, a second VPS, or extra routing layers merely because examples exist in this repository.

### Profile B — resilient inbound

```text
HY2 primary
+
VLESS + REALITY + Vision backup
```

Use when the user wants a TCP fallback for networks where UDP is poor or restricted.

### Profile C — selected WARP egress

Add WARP Local Proxy only when the user wants selected destinations to leave through a separate Cloudflare egress.

### Profile D — fixed egress

Add a trusted fixed SOCKS5 only when the user explicitly wants a stable final egress for selected destinations.

### Profile E — emergency Cloudflare Tunnel entry

Optional. Add only when the user wants another emergency inbound path.

The rule is:

> Start minimal. Add one layer at a time. Stop when the user's actual goal is satisfied.

## Human SSH bootstrap boundary

An AI must not assume it can safely access a fresh VPS just because the user has an IP address and password.

Before autonomous or semi-autonomous SSH deployment, require a one-time **human bootstrap** unless secure key-based access already exists.

Recommended flow:

```text
Human logs in once using provider password / console
        ↓
Human generates an SSH key pair on the local computer
        ↓
Only the public key is installed on the VPS
        ↓
Human verifies key-based SSH login works
        ↓
Local AI/Agent may use the already-working ssh command / SSH agent / SSH config
```

Rules:

1. The SSH private key stays on the user's local machine.
2. Only the `.pub` key goes into server `authorized_keys`.
3. Do not ask the user to paste a root password or SSH private key into chat, GitHub, Issues, logs, or prompts.
4. If the local AI environment can invoke the user's existing `ssh`, SSH agent, or `~/.ssh/config`, use that instead of reading/exporting the private key.
5. Do not disable password login until key-based login has been tested successfully.
6. Preserve provider-console recovery access when possible.
7. If secure SSH access cannot be established, stop and ask the human to complete the bootstrap rather than inventing credentials or weakening SSH security.

For Windows, a normal bootstrap may be:

```powershell
ssh-keygen -t ed25519
Get-Content $env:USERPROFILE\.ssh\id_ed25519.pub | ssh root@SERVER_IP "umask 077; mkdir -p ~/.ssh; cat >> ~/.ssh/authorized_keys"
ssh root@SERVER_IP
```

The final `ssh` must succeed using the local private key before the AI continues with unattended changes.

## Deployment resource contract

Distinguish **required resources for the selected profile** from **optional enhancements**. Do not invent missing resources or silently substitute them.

### Required for Profile A — HY2 only

The user needs:

1. **A VPS or equivalent Linux host they control**
   - root or sudo access;
   - supported Linux such as Ubuntu 24.04 LTS or Debian 12+;
   - provider policy permitting the intended personal VPN/proxy use.
2. **A publicly reachable server address**
   - normally one public IPv4 is sufficient;
   - IPv6 is optional.
3. **UDP reachability for the chosen HY2 port**
   - repository examples use UDP 24443;
   - another port is fine if client and server agree.
4. **A compatible client device and client software**
   - e.g. v2rayN/sing-box/Mihomo as appropriate.
5. **HY2 authentication material**
   - freshly generated password/auth value.
6. **TLS material accepted by the HY2 client**
   - public/ACME certificate path or another explicitly chosen certificate strategy.
7. **Normal outbound Internet access from the VPS.**
8. **Verified SSH key-based administration path before AI-controlled deployment**, unless an equally secure pre-existing access method is already configured.

Resolve before changing the server:

```text
SERVER_IP_OR_HOSTNAME
SSH_ACCESS_METHOD
HY2_UDP_PORT
HY2_TLS_CERTIFICATE_STRATEGY
CLIENT_TYPE
```

Generate secrets during deployment unless the user already has them. Never fabricate credentials.

### Additional resources only if REALITY is selected

Required only for the REALITY backup entry:

```text
VLESS UUID
REALITY X25519 private/public key pair
REALITY short ID
chosen REALITY serverName/target strategy
reachable TCP port (example: 443)
```

A domain name is **not inherently required for REALITY itself**.

### Optional / not required for Profile A

The following are not required for a working HY2-only deployment:

- VLESS + REALITY + Vision;
- residential IP;
- fixed SOCKS5 upstream;
- Cloudflare WARP;
- Cloudflare Tunnel;
- second VPS;
- IPv6;
- domain name for REALITY.

They become conditionally required only when the selected feature needs them:

| Resource | Required only when |
|---|---|
| Domain + DNS control | using an ACME/public-certificate flow that requires it, or other domain-based features |
| REALITY UUID/key pair/short ID | enabling REALITY backup inbound |
| Cloudflare WARP client/account state | enabling WARP outbound |
| Fixed SOCKS5 host/port/credentials | enabling fixed-egress routing |
| Cloudflare account/token/domain | enabling optional Cloudflare Tunnel entry |
| Provider console / security-group access | provider has an external firewall or recovery step that must be managed |

If an optional resource is missing, omit the feature and keep the simpler profile functional.

## Human workflow to preserve

README should keep these points obvious:

1. HY2 alone is enough for many users.
2. The maintainer normally uses HY2.
3. REALITY + Vision is a backup, not a mandatory second protocol.
4. The client chooses an inbound protocol.
5. Xray on the VPS chooses outbound paths when advanced routing is enabled.
6. WARP is optional per-destination egress, not a host-wide default route.
7. Fixed SOCKS5 is optional and only for deliberate stable-egress use.
8. Before letting an AI operate a fresh VPS, a human should establish and verify SSH public-key access.

## Audited client reality

The current Windows client was read-only audited as:

```text
v2rayN 7.24.2
HY2 active       -> sing-box 1.13.14
REALITY profile  -> Xray core
TUN + Rule mode
```

Do not describe v2rayN itself as “the Xray core”. It is a GUI/configuration manager that can launch different cores.

Observed behavior:

```text
GUI metadata + global preferences
              ↓
        v2rayN generates
              ↓
core-specific runtime configuration
```

Therefore sing-box, Xray and Mihomo examples must keep their field names separate.

## Example routing policy

A documented advanced example may use:

```text
ordinary traffic                 -> direct
selected AI/account-heavy sites  -> WARP
Claude / Anthropic               -> optional fixed SOCKS5
```

Treat this as an example policy, not a universal service requirement.

Do not claim that:

- WARP is a residential IP;
- WARP guarantees access to any service;
- a particular AI provider always requires a residential IP.

Preferred explanation: some services may behave differently across regions or data-center IP ranges, so a separate explicitly selected egress can make routing and identity more predictable.

## WARP rule

Prefer WARP Local Proxy / `WarpProxy` mode, with Xray sending only selected traffic to the local proxy.

```text
Xray routing
   -> local WARP proxy (127.0.0.1:40000)
   -> Cloudflare egress
```

Do not make WARP the VPS system-wide default route in the baseline design.

Official references:

- Linux client: <https://developers.cloudflare.com/warp-client/get-started/linux/>
- WARP modes: <https://developers.cloudflare.com/warp-client/warp-modes/>

Cloudflare CLI syntax changes. Prefer current official docs plus local `warp-cli --help` over historical blog commands.

### Watchdog policy

There are two separate supervision problems:

```text
Xray process supervision       -> systemd service
WARP real-egress health check  -> connectivity watchdog
```

For Xray, use systemd process supervision.

For WARP connectivity health, prefer a systemd timer in new/public deployments. Cron may be mentioned only as a historical implementation or explicitly labelled simpler alternative.

The watchdog must test real egress through the local WARP proxy, not merely process state.

## Xray source of truth

Prefer current official Xray documentation over copied blog configs or remembered production aliases:

- Hysteria inbound: <https://xtls.github.io/config/inbounds/hysteria.html>
- Hysteria transport: <https://xtls.github.io/config/transports/hysteria.html>
- VLESS / Vision: <https://xtls.github.io/config/inbounds/vless.html>
- REALITY: <https://xtls.github.io/config/transports/reality.html>
- RAW: <https://xtls.github.io/config/transports/raw.html>
- SOCKS outbound: <https://xtls.github.io/config/outbounds/socks.html>
- Installer: <https://github.com/XTLS/Xray-install>

Current assumptions:

- Xray supports Hysteria2 in current official documentation.
- Hysteria version is 2.
- HY2 is the primary entry.
- REALITY/Vision is optional backup.
- VLESS uses `xtls-rprx-vision` in the documented REALITY profile.
- Current transport docs use `streamSettings.method`; historical configs may use older fields/aliases.
- REALITY server-side docs currently use `target`; historical configs may use `dest`.
- Current SOCKS outbound docs use flat `settings.address`, `settings.port`, optional `settings.user` and `settings.pass`; production history may contain older shapes.

If upstream syntax changes, update every affected example/doc together.

## Repository file map and synchronization rules

```text
README.md                              Chinese human-facing architecture and usage
AGENTS.md                              AI deployment/maintenance contract
examples/xray-server.example.jsonc     server-side Xray schema example
examples/v2rayn-hysteria2.example.md   audited v2rayN / sing-box HY2 client example
examples/v2rayn-reality-vision.example.md
                                       v2rayN / Xray REALITY client example
docs/warp-outbound.md                  optional WARP egress behavior
docs/static-socks.md                   optional fixed SOCKS5 egress behavior
```

Synchronization rules:

- Xray schema change -> server example + README references + affected docs + AGENTS assumptions.
- v2rayN/sing-box HY2 field change -> HY2 client example + affected README/client notes.
- REALITY client field change -> REALITY client example + affected README/client notes.
- WARP policy/CLI change -> WARP doc + server example if necessary + AGENTS policy if architecture changes.
- fixed SOCKS5 schema/policy change -> static SOCKS doc + server example + AGENTS if safety boundary changes.

Do not leave contradictory field names or deployment requirements across files.

## Production host is not the template

The production VPS evolved through experiments and may contain legacy paths, backups, watchdog scripts, compatibility fields or unused configuration.

Do not copy historical filesystem layout merely because it exists.

Prefer clean public layouts such as:

```text
/usr/local/bin/xray
/usr/local/etc/xray/config.json
systemd-managed services
explicit firewall rules
minimal configs
```

Derive public examples through:

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

## Secret handling

Never add live secrets to this repository.

Use placeholders only:

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

Never commit or paste:

- SSH private keys;
- root/VPS passwords;
- TLS private keys;
- Cloudflare tokens;
- production proxy credentials;
- subscription URLs;
- full production configs containing secrets.

## Remote SOCKS5 security boundary

SOCKS5 itself does not provide transport encryption.

When documenting a remote fixed SOCKS5 over the public Internet, state that:

- the SOCKS tunnel is not itself an encrypted VPN;
- HTTPS still protects HTTPS application content end-to-end;
- stronger transport confidentiality requires a private/encrypted path or provider that supplies one.

Do not equate “fixed/residential IP” with “encrypted or safer transport”.

## Routing safety

Keep specific routing rules before broad catch-all rules.

For destinations deliberately bound to a fixed egress, document fail-closed behavior unless the user explicitly requests fallback.

Do not silently change a fixed-egress route to VPS direct when its upstream is unavailable.

## Firewall and service management

Only open ports for features actually selected.

Typical full-profile listeners:

```text
TCP 22      SSH
TCP 443     REALITY
UDP 24443   HY2
```

For HY2-only Profile A, REALITY TCP 443 does not need to be exposed merely because the repository contains a REALITY example.

Preserve SSH access before firewall changes and remember provider-side security groups may also exist.

## Editing rules

Before changing protocol examples:

1. verify current upstream syntax;
2. preserve placeholders;
3. keep tags readable;
4. mark each component required vs optional;
5. explain the failure mode introduced by each extra layer;
6. include a validation/test step when possible;
7. never copy real production credentials;
8. distinguish historical working fields from current recommended fields;
9. preserve the HY2-only minimal path.

Useful Xray validation command:

```bash
xray run -test -config /usr/local/etc/xray/config.json
```

## Testing philosophy

Do not call a path good based on one speed test.

Prefer checking:

- connection success rate;
- latency and variance;
- timeouts;
- peak-hour behavior;
- sustained small transfers;
- long-lived connection stability;
- final intended egress IP.

Test one path at a time and change one variable at a time.

## AI deployment self-check

Before telling the user deployment is complete, verify only the features that were actually selected:

1. SSH key-based administration still works.
2. Xray/server configuration test passes.
3. Expected listeners are present — and no unnecessary example ports were opened.
4. HY2 client/server credentials match if HY2 is deployed.
5. REALITY client/server credentials match if REALITY is deployed.
6. Direct egress works.
7. If WARP is enabled, traffic through the local proxy reaches the intended WARP egress.
8. If fixed SOCKS5 is enabled, the intended route reaches the fixed egress and does not silently fall back.
9. Firewall/provider security-group rules still permit SSH and selected proxy ports.
10. No real secrets were written to repository, logs, issues or chat output.

Do not claim successful end-to-end client operation if the client side was not actually tested.

## Documentation style

`README.md` is for Chinese-speaking humans: explain why first, commands second.

`AGENTS.md` is for AI maintainers/deployers: preserve architecture, SSH bootstrap boundary, minimal deployment path, safety constraints, source-of-truth links and secret hygiene.

The repository must remain understandable without private production context.