# AGENTS.md — AI maintainer guide

Read this file before editing the repository.

## Project model

Keep the architecture separated into two layers:

```text
Inbound  = how the client reaches the VPS
Outbound = how the VPS reaches a destination
```

Preferred inbound roles:

```text
Hysteria2                    primary daily entry
VLESS + REALITY + Vision     TCP backup entry
VLESS + WS + CF Tunnel       optional emergency entry
```

Preferred outbound roles:

```text
VPS direct       normal traffic
WARP             selected destinations
fixed SOCKS5     optional fixed-egress destinations
block            explicit deny / fail-closed routes
```

Do not collapse the design into one global tunnel.

## Human workflow to preserve

The README should keep the following story clear:

1. The maintainer normally uses HY2.
2. REALITY + Vision is kept as a backup when UDP is poor or unavailable.
3. The client chooses an inbound protocol.
4. Xray on the VPS chooses the outbound path by routing policy.
5. WARP is an optional per-destination egress, not a host-wide default route.
6. A fixed upstream SOCKS5 is optional and is used when a deliberately stable egress is desired.

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

Therefore examples for sing-box, Xray and Mihomo must keep their field names separate.

## Example routing policy

A documented example may use:

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

Preferred explanation: some services may behave differently across regions or data-center IP ranges, so a separate, explicitly chosen egress can make routing and identity more predictable.

## WARP rule

Documentation should prefer WARP Local Proxy / `WarpProxy` mode, with Xray sending only selected traffic to the local proxy.

Conceptual layout:

```text
Xray routing
   -> local WARP proxy (127.0.0.1:40000)
   -> Cloudflare egress
```

Do not make WARP the VPS system-wide default route in the baseline design.

Official references:

- Linux client: <https://developers.cloudflare.com/warp-client/get-started/linux/>
- WARP modes: <https://developers.cloudflare.com/warp-client/warp-modes/>

Cloudflare CLI syntax changes over time. When documenting commands, prefer current official docs plus `warp-cli --help` over copied historical blog commands.

## Xray source of truth

Prefer current official Xray documentation over copied blog configs or remembered production aliases:

- Hysteria inbound: <https://xtls.github.io/config/inbounds/hysteria.html>
- Hysteria transport: <https://xtls.github.io/config/transports/hysteria.html>
- VLESS / Vision: <https://xtls.github.io/config/inbounds/vless.html>
- REALITY: <https://xtls.github.io/config/transports/reality.html>
- RAW: <https://xtls.github.io/config/transports/raw.html>
- SOCKS outbound: <https://xtls.github.io/config/outbounds/socks.html>
- Installer: <https://github.com/XTLS/Xray-install>

Current assumptions used by this repo:

- Xray **does support Hysteria2** in current official documentation. Do not repeat the obsolete/incorrect claim that Xray never supports Hysteria2.
- Hysteria version is 2.
- HY2 is the primary entry.
- VLESS uses `xtls-rprx-vision` for the REALITY backup entry.
- Current transport docs use `streamSettings.method`; historical configs may use older field names/aliases.
- REALITY server-side docs currently use `target`; older `dest` examples may appear in historical configs.
- Current SOCKS outbound docs use flat `settings.address`, `settings.port`, optional `settings.user`, and `settings.pass`. Historical production configs may use an older `servers: []` shape.

If upstream syntax changes, update README examples and all affected example/docs files together.

## Production host is not the template

The maintainer has a production VPS that evolved through experiments. It may contain legacy paths, backups, watchdog scripts, compatibility fields, or unused configuration.

Do not copy historical filesystem layout into new public examples merely because it exists on the server.

Prefer a clean tutorial layout:

```text
/usr/local/bin/xray
/usr/local/etc/xray/config.json
systemd-managed services
explicit firewall rules
minimal configs
```

The public examples should be derived using this pipeline:

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

Use generic example ports rather than copying a private upstream port when it is not necessary to teach the configuration.

Never commit SSH private keys, TLS private keys, Cloudflare tokens, production proxy credentials, subscription URLs, or full production configs containing secrets.

## Remote SOCKS5 security boundary

SOCKS5 itself does not provide transport encryption.

When documenting a remote fixed SOCKS5 over the public Internet, explicitly state that:

- the SOCKS tunnel is not itself an encrypted VPN;
- HTTPS still protects HTTPS application content end-to-end;
- users needing encrypted transport to the upstream should use a private/encrypted path or a provider that explicitly supplies one.

Do not equate “fixed/residential IP” with “encrypted or safer transport”.

## Routing safety

Keep specific routing rules before broad catch-all rules.

For destinations intentionally bound to a fixed egress, document fail-closed behavior unless the maintainer explicitly asks for fallback.

Do not silently change a fixed-egress route to VPS direct when its upstream is unavailable.

## Firewall and service management

Public examples should use an explicit firewall and standard service management.

Baseline listeners are normally:

```text
TCP 22      SSH
TCP 443     REALITY
UDP 24443   HY2
```

Prefer systemd for Xray instead of recurring cron watchdogs.

A separate connectivity watchdog can still be reasonable for WARP because a daemon may be alive while its local proxy path is unusable; such watchdogs must test real egress connectivity, not merely process state.

Before suggesting firewall changes, preserve SSH access and remind the user that provider-side security groups may also exist.

## Editing rules

Before changing protocol examples:

1. verify current upstream syntax;
2. preserve placeholders;
3. keep tags readable;
4. explain whether a component is required or optional;
5. explain what failure mode it introduces;
6. include a validation/test step when possible;
7. never copy real production credentials;
8. distinguish production-compatible historical fields from current recommended fields.

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

## Documentation style

`README.md` is for Chinese-speaking humans: explain why first, commands second.

`AGENTS.md` is for AI maintainers: preserve architecture, safety constraints, source-of-truth links, and secret hygiene.

The repository should remain understandable without any private production context.
