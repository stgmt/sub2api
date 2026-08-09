# OpenAI OAuth `unsupported_country`

Use this reference when browser authorization for an OpenAI/Codex account shows:

```text
OpenAI's services are not available in your country.
error_code: unsupported_country
request_id: ...
```

## Scope

This error occurs before sub2api can use the OpenAI/Codex account. It is not
evidence of a broken model mapping, Headroom route, refresh token, or sub2api
database row. Preserve OAuth files and account state while diagnosing egress.

If the same account repeats the error in another browser with a different
`request_id`, browser-local cache is no longer the leading explanation. Verify:

1. The actual public egress used by `auth.openai.com`.
2. ASN/prefix classification, not only a consumer GeoIP country label.
3. The complete OAuth callback through the intended route.
4. Account and payment-method country if a clean supported-country egress still
   returns the same error.

## Optional router/VPS solution

For a self-hosted OpenWrt + VPS setup, route only these families through a
separate supported-country proxy:

- `openai.com`
- `chatgpt.com`
- `oaistatic.com`
- `oaiusercontent.com`

Keep normal sub2api, Headroom, games, and unrelated traffic on their existing
routes. A working design is:

```text
client -> OpenWrt mihomo OPENAI_WARP -> awg0
       -> VPS private SOCKS5 -> Cloudflare WARP -> OpenAI
```

The VPS proxy must bind only to its private tunnel address. The router must have
an explicit host route to that address through `awg0` when the tunnel interface
uses `/32`, `nohostroute=1`, or `route_allowed_ips=0`.

## HTTP/3 trap

A green TCP proxy trace does not prove the browser OAuth route. Chromium can
send `/api/accounts/session/select` over HTTP/3. Mihomo continues matching lower
rules when UDP selects a proxy with `udp: false`, so QUIC can skip an
OpenAI-specific TCP SOCKS outbound and fall through to the normal VPN.

Place domain-scoped `UDP/443` reject guards before the OpenAI TCP routes. The
browser then retries over TCP through the supported-country egress. Do not
block UDP globally: games and unrelated HTTP/3 traffic are outside this scope.

## Required proof order

1. VPS container is restart-safe and `healthy`.
2. `ip route get <private-proxy-ip>` on the router shows `dev awg0`.
3. Router-side SOCKS trace reports `warp=on` and an expected supported country.
4. The routing profile passes its own syntax check and safe apply.
5. `auth.openai.com/cdn-cgi/trace` through the router shows the new egress.
6. Live connections show no OpenAI QUIC flow through the ordinary outbound.
7. Account selection reaches consent and the OAuth callback is issued without
   `unsupported_country`.

Do not apply domain rules before steps 2 and 3. A dead private proxy makes
ChatGPT and Codex appear broadly offline because all OpenAI domains select the
same unavailable outbound.

The canonical implementation and rollback are maintained in
[`stgmt/claude-skill-router-vpn` skill 23](https://github.com/stgmt/claude-skill-router-vpn/tree/master/skills/23-openai-country-egress).

If the error remains after a proven supported-country OAuth callback, collect
the account email, auth method, timestamp/timezone, browser/OS, network details,
and all new `request_id` values for OpenAI support. Do not rotate sub2api OAuth
state as a substitute for account review.
