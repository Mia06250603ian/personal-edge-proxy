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

## Deployment resource contract

When an AI is asked to deploy this project from zero, distinguish **required resources** from **optional enhancements**. Do not invent missing resources or silently substitute them.

### Required for the baseline HY2 + REALITY deployment

The user must have:

1. **A VPS or equivalent Linux host they control**
   - root or sudo access;
   - a supported Linux distribution such as Ubuntu 24.04 LTS or Debian 12+;
   - provider policy that permits the intended personal VPN/proxy use.
2. **A publicly reachable server address**
   - normally one public IPv4; IPv6 is not required;
   - the chosen TCP and UDP ports must be reachable through both provider-side security groups and the host firewall.
3. **TCP and UDP connectivity**
   - baseline examples use TCP 443 for REALITY and UDP 24443 for HY2;
   - equivalent user-selected ports are acceptable if client/server configs match.
4. **A compatible client device and client software**
   - for example v2rayN, sing-box, Xray or Mihomo depending on the example being used.
5. **Freshly generated protocol credentials**
   - VLESS UUID;
   - REALITY X25519 private/public key pair;
   - REALITY short ID;
   - HY2 authentication password.
6. **TLS material for Hysteria2**
   - HY2 requires a certificate/key pair accepted by the client;
   - this can come from a normal ACME/public-certificate path, or another explicitly chosen certificate strategy;
   - do not assume that a domain is mandatory for REALITY itself.
7. **Normal outbound Internet access from the VPS**
   - the VPS must be able to reach the destinations that its selected outbounds require.

Before deployment, ask for or resolve these values explicitly:

```text
SERVER_IP_OR_HOSTNAME
SSH_ACCESS_METHOD
REALITY_TCP_PORT
HY2_UDP_PORT
HY2_TLS_CERTIFICATE_STRATEGY
CLIENT_TYPE
```

Generate secrets during deployment unless the user already has them. Never fabricate credentials.

### Optional / not required for the baseline

The following are **not required** merely to run HY2 + REALITY:

- a residential IP;
- a fixed SOCKS5 upstream;
- Cloudflare WARP;
- Cloudflare Tunnel;
- a second VPS;
- IPv6;
- a domain name for REALITY itself.

They become conditionally required only when the user chooses the corresponding feature:

| Resource | Required only when |
|---|---|
| Domain + DNS control | using an ACME/public-certificate flow that needs them, or other domain-based features |
| Cloudflare WARP client/account state | enabling the WARP outbound |
| Fixed SOCKS5 host/port/credentials | enabling a fixed-egress route |
| Cloudflare account/token/domain | enabling the optional Cloudflare Tunnel emergency entry |
| Provider console / security-group access | the VPS provider has an external firewall that must be changed |

If an optional resource is missing, omit that feature and keep the baseline deployment functional. Do not block a basic HY2 + REALITY deployment because WARP, SOCKS5, or Cloudflare Tunnel is unavailable.

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

### Watchdog policy — no cron/systemd ambiguity

There are two different supervision problems:

```text
Xray process supervision       -> systemd service
WARP real-egress health check  -> connectivity watchdog
```

For **Xray**, use systemd process supervision. Do not use a recurring cron job as the baseline way to keep Xray alive.

For the **WARP connectivity watchdog**, a scheduler is needed because `warp-svc` can be alive while the proxy path is unusable. Public/new-deployment documentation should **prefer a systemd timer** for that watchdog. A cron entry may be mentioned only as:

- a historical production implementation; or
- an explicitly labelled alternative for simple environments.

Do not present cron and systemd timer as two conflicting default recommendations. In every case, the watchdog must test real egress connectivity through the local WARP proxy, not merely daemon/process state.

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

## Repository file map and synchronization rules

Current public files have distinct responsibilities:

```text
README.md                              Chinese human-facing architecture and usage
AGENTS.md                              AI maintainer contract and invariants
examples/xray-server.example.jsonc     server-side Xray schema example
examples/v2rayn-hysteria2.example.md   audited v2rayN / sing-box HY2 client example
examples/v2rayn-reality-vision.example.md
                                       v2rayN / Xray REALITY client example
docs/warp-outbound.md                  WARP egress behavior and validation
docs/static-socks.md                   optional fixed SOCKS5 egress behavior
```

When changing a protocol/schema, update all files that expose the same assumption:

- Xray inbound/outbound schema change -> server example + README references + affected docs + AGENTS assumptions.
- v2rayN/sing-box HY2 field change -> HY2 client example + affected README/client notes.
- REALITY client field change -> REALITY client example + affected README/client notes.
- WARP policy/CLI change -> WARP doc + server example if schema changes + AGENTS policy if architecture changes.
- fixed SOCKS5 schema/policy change -> static SOCKS doc + server example + AGENTS if the safety boundary changes.

Do not update one example while leaving contradictory field names in another file.

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

Xray lifecycle supervision must use systemd in the baseline design.

A separate WARP connectivity watchdog is allowed because a daemon may be alive while its local proxy path is unusable. For new/public deployments, prefer a systemd timer; cron is only a labelled alternative or historical production note.

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

## AI deployment self-check

Before telling the user a deployment is complete, verify as much as the environment permits:

1. Xray configuration test passes.
2. Expected TCP/UDP listeners are present.
3. HY2 and REALITY credentials are consistent between server/client examples.
4. Direct egress works.
5. If WARP is enabled, the request through the local proxy reaches the intended WARP egress.
6. If fixed SOCKS5 is enabled, its route reaches the intended fixed egress and does not silently fall back.
7. Firewall/provider security-group rules still permit SSH and the intended proxy ports.
8. No real secrets were written into this repository, logs, issues or chat output.

Do not claim successful end-to-end client operation if the client side was not actually tested.

## Documentation style

`README.md` is for Chinese-speaking humans: explain why first, commands second.

`AGENTS.md` is for AI maintainers: preserve architecture, safety constraints, source-of-truth links, resource prerequisites, and secret hygiene.

The repository should remain understandable without any private production context.
