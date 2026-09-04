# HTTP inspection API

StratoWeave orchestrators expose a small HTTP inspection API rooted at `/`.

This API is useful for inspecting devices, layer state, configuration queues,
and rendered southbound configuration.

## Conventions

You can call these endpoints against any StratoWeave orchestrator with a base
URL like this:

```sh
curl "$STRATOWEAVE_API_ORIGIN/device/AMS-CORE-1/running?format=xml"
```

A few conventions matter when you call these endpoints directly:

- Device names in `/device/<name>/...` are case-sensitive.
- The `/device/<name>/*` config endpoints select output format with the
  `format` query parameter.
- The `/layer/<idx>` endpoint does not use `?format=`. It selects output from
  the `Accept` header instead.
- For Acton adata output, both `/device/<name>/*` and `/layer/<idx>` support a
  `loose` query parameter. It defaults to `true`.

## SORESPO quicklab examples

SORESPO quicklab Makefiles use these inspection endpoints today:

- `GET /layer/<idx>`
- `GET /device/<name>/target?format=<fmt>`
- `GET /device/<name>/running?format=<fmt>`
- `GET /device/<name>/diff?format=<fmt>`
- `GET /device/<name>/resync`

Typical Make targets include:

```sh
make get-config0
make get-config-json2
make get-config-adata3
make get-target-ams-core-1
make get-running-ams-core-1
make get-diff-ams-core-1
make resync-ams-core-1
```

## Inspection API

### `GET /device`
Returns the list of managed device names as JSON.

Example response:

```json
{"devices":["AMS-CORE-1","FRA-CORE-1"]}
```

### `GET /device/<name>/info`
Returns device metadata and current orchestration state as JSON.

This includes:

- device name and configured type
- approval mode
- configured addresses
- configured username
- `has_running_config`
- `has_target_config`
- `queue_length`
- `pending_approvals`
- feature flags
- discovered module list

This is the best summary endpoint when you need to understand whether a device
is configured, queued, or missing data.

### `GET /device/<name>/capabilities`
Returns device capabilities as JSON.

Example response shape:

```json
{"capabilities":["urn:ietf:params:netconf:base:1.1"]}
```

### `GET /device/<name>/modules`
Returns the device module set as JSON.

Each module entry contains the module name, namespace, revision, and features.
This is useful when you need to confirm the live schema seen by the device
manager.

### `GET /device/<name>/running?format=<fmt>`
Returns the current running configuration known for the device.

Supported formats:

- `json`
- `xml`
- `gdata`
- `adata`

Example:

```sh
curl "$STRATOWEAVE_API_ORIGIN/device/AMS-CORE-1/running?format=xml"
```

If no running configuration is available, the endpoint returns a `200` with the
plain-text message `# No running configuration available`.

### `GET /device/<name>/target?format=<fmt>`
Returns StratoWeave's target configuration for the device: the config the
orchestrator wants the device to have.

Supported formats:

- `json`
- `xml`
- `gdata`
- `adata`

Example:

```sh
curl "$STRATOWEAVE_API_ORIGIN/device/AMS-CORE-1/target?format=xml"
```

If no target configuration is available, the endpoint returns a `200` with the
plain-text message `# No target configuration available`.

### `GET /device/<name>/diff?format=<fmt>`
Returns the difference between running and target configuration for the device.

Supported formats:

- `json`
- `xml`
- `gdata`
- `adata`

Example:

```sh
curl "$STRATOWEAVE_API_ORIGIN/device/AMS-CORE-1/diff?format=xml"
```

If there is no diff, the endpoint returns `# No differences`. If either side is
missing, it returns `# Configuration not available`.

### `GET /device/<name>/log?format=<fmt>`
Returns the device configuration event log as JSON.

Each log item contains:

- `timestamp`
- `event`
- `conf_diff`

Supported diff renderings inside the JSON payload:

- `json`
- `xml`
- `gdata`

`adata` is not implemented for this endpoint.

### `GET /device/<name>/q`
Returns the device's configuration queue as JSON.

The response is a map keyed by queue item id. Each value currently includes the
transaction id.

Example response shape:

```json
{
  "7": {"tid": "1234"},
  "8": {"tid": "1235"}
}
```

### `GET /device/<name>/q/<id>?format=<fmt>`
Returns one queue item in JSON, including the diff awaiting approval or
application.

Fields include:

- `tid`
- `config_diff`
- `device_txid`
- `format`

Supported diff formats for this endpoint are narrower than the device config
endpoints:

- `xml` (default)
- `gdata`
- `json` returns `# JSON diff not available`
- `adata` returns `# Adata diff not available`

### `POST /device/<name>/q/<id>/set_approval`
Sets approval for a queued device config item.

Request body:

```json
{"device_txid":"abc123","approved":true}
```

Response:

```json
{"status":"ok","approved":true}
```

This is the approval action behind configuration approval workflows such as the
SORESPO queue UI.

### `GET /config-queue`
Returns all pending approvals across all devices as JSON.

Each device entry contains:

- `device_id`
- `pending_count`
- `items`

Each item contains:

- `queue_id`
- `tid`
- `device_txid`
- `approved`

This is the best endpoint for a global approval queue view.

### `GET /device/<name>/resync`
Triggers a device resynchronization and returns a JSON acknowledgement.

Example:

```sh
curl "$STRATOWEAVE_API_ORIGIN/device/AMS-CORE-1/resync"
```

Response:

```json
{"status":"ok","message":"Resync initiated"}
```

## Browser terminal

### `GET /device/<name>/terminal` (WebSocket)
Opens an interactive SSH shell on the device and bridges it to the caller
over a WebSocket. This is what the Web UI's Terminal page uses.

The endpoint is off by default. Enable it with the `terminal_enabled` system
setting (`--terminal-enabled` on the command line,
`STRATOWEAVE_TERMINAL_ENABLED=true` in the environment, or
`terminal_enabled = True` in a settings file). Without it, the path is not
served and returns `404`.

The request must be a WebSocket upgrade (`Connection: Upgrade`,
`Upgrade: websocket`, `Sec-WebSocket-Version: 13`, `Sec-WebSocket-Key`). A
plain `GET` returns `404`. Optional query parameters `cols` and `rows` set the
initial PTY size (default 80x24, clamped to 1..512).

The `Origin` header is required and its host must equal the host in the
`Host` header (ports are ignored, so a dev server on `localhost:5173` that
proxies to `localhost:3000` works). Other origins get `403` unless listed in
the `terminal_allowed_origins` setting (comma-separated, exact origins such as
`https://ops.example.com`). Non-browser clients must send an `Origin` header.

The SSH session uses the device's stored `credentials/username` and
`credentials/password`, the first entry in `address/`, the transport settings
from `ssh/`, and the port from `terminal/port` (default 22, independent of the
NETCONF port in `address/port`). Host keys are accepted without verification,
as for the NETCONF adapter.

Handshake failures are ordinary HTTP responses with a JSON body:

- `400` invalid upgrade headers
- `403` origin not allowed
- `404` terminal disabled, unknown device, or not an upgrade request
- `409` device has no address, no password, or an invalid `ssh/` config

Wire protocol after the upgrade:

- Binary frames carry raw terminal bytes in both directions (keystrokes to
  the device, PTY output to the client).
- Text frames carry JSON control messages. The client may send
  `{"type":"resize","cols":120,"rows":40}`; it is accepted but not applied
  yet (the SSH library has no window-change binding). The server sends
  `{"type":"status","state":"connecting"|"connected"|"closed","message":"..."}`
  and `{"type":"error","message":"..."}`.
- Closing the WebSocket ends the SSH session; the SSH session or shell ending
  closes the WebSocket (code 1000 after a normal shell exit, 1011 when the
  connection or shell request failed).

Example with [websocat](https://github.com/vi/websocat):

```sh
websocat -b -H 'Origin: http://localhost' \
  "ws://localhost:3000/device/AMS-CORE-1/terminal?cols=120&rows=40"
```

There is no authentication on the HTTP API, so enabling the terminal exposes
a device shell to anyone who can reach the port. Keep it off outside of lab
setups until HTTP authentication exists.

## Layer inspection

### `GET /layer/<idx>`
Returns the stored configuration for one StratoWeave layer.

Unlike the device config endpoints, serialization is selected with the
`Accept` header:

- `application/yang-data+xml`
- `application/yang-data+json`
- `application/yang-data+acton-adata`

Examples:

```sh
curl -H "Accept: application/yang-data+xml" \
  "$STRATOWEAVE_API_ORIGIN/layer/0"

curl -H "Accept: application/yang-data+json" \
  "$STRATOWEAVE_API_ORIGIN/layer/2"

curl -H "Accept: application/yang-data+acton-adata" \
  "$STRATOWEAVE_API_ORIGIN/layer/3?loose=true"
```

The meaning of each layer index depends on the system specification.

For example, in SORESPO the layer numbers are:

- `0`: CFS
- `1`: Inter
- `2`: RFS
- `3`: Device

If the index is out of range, the endpoint returns `404`.

## Choosing the right endpoint

Use `/layer/<idx>` when you want to inspect StratoWeave's stored state at a
specific transform layer. Use `/device/<name>/target` and
`/device/<name>/running` when you want to compare the orchestrator's intended
southbound device config with the device's current running config. Use
`/device/<name>/diff` and `/config-queue` when you are diagnosing rollout or
approval behavior.

## Embedded static assets (web UI)

Applications can embed a built web UI (or any set of text files) into their
binary and have the HTTP server serve it alongside the APIs. Pass a
`static_assets` map (URL path -> file content) to `stratoweave.main()`; it is
forwarded to `HttpServer` and installed by the `static_assets` module.

Behavior:

- Every asset is served on `GET <path>` on the same listener and port as the
  APIs. `GET /` serves `/index.html` when present. Assets are served by a
  catch-all `GET /*path` route that the router ranks below every static or
  parameterized route, so registered API routes always take precedence and can
  never be shadowed by an asset. Installing fails if the application already
  registered its own root-level `GET` wildcard.
- Assets under `/_app/immutable/` (content-hashed filenames) are served with
  `Cache-Control: public, max-age=31536000, immutable`; everything else with
  `no-cache`.
- SPA fallback: a `GET` request that matches no route and carries an `Accept`
  header that explicitly allows `text/html` (a browser navigation) receives
  `/index.html`, so
  client-side routed pages survive a browser refresh. Requests without such an
  `Accept` header — API clients, curl — keep receiving a plain `404`, and
  registered API routes always win over the fallback.
- The flip side of route precedence: an asset whose path an existing GET
  route already matches — including parameterized and wildcard routes such as
  `/device/{name}/info` or `/restconf/data/*` — is unreachable. Keep asset
  paths (`/index.html`, `/_app/...`) out of the API namespace.

Limitations:

- Only text assets can be served (response bodies are UTF-8 strings). Binary
  files such as images or fonts must be inlined by the frontend build, e.g. as
  data URIs.
- `HEAD` is not supported by the HTTP server; use `curl -sD- -o /dev/null`
  rather than `curl -I` when inspecting response headers.
