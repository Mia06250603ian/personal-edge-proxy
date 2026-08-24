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
   -> local WARP proxy
   -> Cloudflare egress
```

Do not make WARP the VPS system-wide default route in the baseline design.

Official reference:
<https://developers.cloudflare.com/cloudflare-one/team-and-resources/devices/cloudflare-one-client/configure/modes/>

## Xray source of truth

Prefer current official Xray documentation over copied blog configs:

- Hysteria inbound: <https://xtls.github.io/en/config/inbounds/hysteria.html>
- Hysteria transport: <https://xtls.github.io/en/config/transports/hysteria.html>
- VLESS / Vision: <https://xtls.github.io/en/config/inbounds/vless.html>
- REALITY: <https://xtls.github.io/en/config/transports/reality.html>
- Installer: <https://github.com/XTLS/Xray-install>

Current assumptions used by this repo:

- Hysteria version is 2.
- HY2 is the primary entry.
- VLESS uses `xtls-rprx-vision` for the REALITY backup entry.
- REALITY documentation currently uses `target`; older `dest` examples may appear in historical configs.

If upstream syntax changes, update README examples and any future example configs together.

## Production host is not the template

The maintainer has a production VPS that evolved through experiments. It may contain legacy paths, backups, watchdog scripts, or unused configuration.

Do not copy historical filesystem layout into new public examples merely because it exists on the server.

Prefer a clean tutorial layout:

```text
/usr/local/bin/xray
/usr/local/etc/xray/config.json
systemd-managed services
explicit firewall rules
minimal configs
```

## Secret handling

Never add live secrets to this repository.

Use placeholders only, for example:

```text
YOUR_SERVER_IP
YOUR_VLESS_UUID
YOUR_REALITY_PRIVATE_KEY
YOUR_REALITY_PUBLIC_KEY
YOUR_SHORT_ID
YOUR_HY2_PASSWORD
YOUR_DOMAIN
SOCKS_HOST
SOCKS_PORT
SOCKS_USERNAME
SOCKS_PASSWORD
```

Never commit SSH private keys, TLS private keys, Cloudflare tokens, production proxy credentials, or full production configs containing secrets.

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

Before suggesting firewall changes, preserve SSH access and remind the user that provider-side security groups may also exist.

## Editing rules

Before changing protocol examples:

1. verify current upstream syntax;
2. preserve placeholders;
3. keep tags readable;
4. explain whether a component is required or optional;
5. explain what failure mode it introduces;
6. include a validation/test step when possible;
7. never copy real production credentials.

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

`README.md` is for humans: explain why first, commands second.

`AGENTS.md` is for AI maintainers: preserve architecture, safety constraints, source-of-truth links, and secret hygiene.

The repository should remain understandable without any private production context.
