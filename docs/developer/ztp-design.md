# ZTP support in StratoWeave — design

Status: **draft for review**. A working prototype accompanies this document; the
prototype makes concrete choices everywhere this document lists alternatives,
and those choices are marked **[prototype]**.

## 1. Goal

Bring a factory-reset device to the point where StratoWeave can manage it over
NETCONF, with zero manual touches on the device:

1. Operator declares the device northbound (name, type, *serial number* — but
   typically **no IP address**, since the device does not have one yet).
2. Device boots factory-default, gets an address via DHCP and discovers its
   bootstrap source (DHCP options).
3. Device fetches day-0 bootstrap data from StratoWeave, which enables NETCONF
   and credentials, and (where supported) reports progress while doing so.
4. StratoWeave learns the device's address from the ZTP exchange, connects via
   NETCONF, discovers the modset, and the normal transform pipeline takes over.

Multiple ZTP mechanisms must be supported behind one framework; the initial
mechanisms are **SZTP (RFC 8572)** and **classic DHCP-option ZTP**
(IOS-XR/IOS-XE style). The framework should leave room for e.g. NETCONF Call
Home (RFC 8071) later without redesign.

## 2. Reality check: what the lab devices actually support

Summary of research against vendor documentation (June 2026), with consequences
for what we can demo:

| Platform | SZTP (RFC 8572) | Classic ZTP | Notes |
|---|---|---|---|
| c8000v (IOS-XE 17.15/17.18) | **No.** SZTP on IOS-XE is Catalyst 9300–9600 only (17.11.1+), and is anchored end-to-end in the hardware SUDI cert + Cisco MASA-issued ownership vouchers. No unsigned/test mode exists. c8000v has no SUDI. | **Yes** (since 17.4.1). DHCP option 67 → Python script runs in Guest Shell; script can `configurep` users, AAA, `netconf-yang`. Options 43 (PnP) and 143 outrank 67, so the DHCP scope must not send them. | Our vrnetlab images are the old console-bootstrap style; a factory-default boot requires skipping the console bootstrap and reworking the datapath (see §8.3). |
| XRd control-plane 24.1.1 / 25.3.1 | XR implements SZTP (7.3.1+, `ztp secure-mode enable`) but it validates Cisco-signed vouchers against the SUDI trust anchor — not workable for an XRd container without real vouchers. | **Yes — the sweet spot.** ZTP is built in but disabled by default; enable with env `XR_ZTP_ENABLE=1` (and drop containerlab's `snoop_v4,snoop_v6` mgmt flags). DHCP option 67 → one file: a config (first line `!! IOS XR`, applied as **replace**) or a script (`#!/usr/bin/python3` / bash). 25.3.x requires Python 3 scripts. | Native container networking — the DHCP exchange goes straight onto the containerlab network. |
| cRPD 24.4R1 | No | No (no DHCP client / ZTP / phone-home in cRPD at all) | Day-0 story is a mounted `/config/juniper.conf`. ZTP-shaped demo = orchestrator renders day-0 config at container creation; "discovery handoff" only. |
| OPI `sztp-agent` (container) | **Yes — full RFC 8572 client** incl. `report-progress` | n/a | This is how we exercise the SZTP server path end-to-end, including the progress stream, until real SZTP-capable hardware is available. |

Two structural consequences:

* **The SZTP server side is worth building now** — it is small (two RPCs +
  host-meta), it is the standards path that real hardware (XR, Junos, Cat9k,
  Nokia) implements, and we can verify it against the OPI agent. But no
  *virtual* device will do vendor-grade SZTP, because the trust chain requires
  manufacturer device identity (SUDI/IDevID) and manufacturer-signed ownership
  vouchers (Cisco MASA / Juniper JAL portals). Those are per-serial artifacts
  for physical boxes.
* **Classic ZTP is what onboards our actual lab routers** (XRd today, c8000v
  with image work). It shares everything with SZTP except the wire protocol:
  device identity matching, day-0 config rendering, address discovery,
  progress/lifecycle tracking. This is exactly the seam for the pluggable
  framework.

## 3. SZTP protocol essentials (what we must implement)

The bootstrap server surface is deliberately tiny (RFC 8572 §4.4):

```
GET  /.well-known/host-meta                 → XRD doc pointing at /restconf  (RFC 8040 §3.1)
POST /restconf/operations/ietf-sztp-bootstrap-server:get-bootstrapping-data  → 200 + output
POST /restconf/operations/ietf-sztp-bootstrap-server:report-progress         → 204 No Content
```

Media types `application/yang-data+json` / `+xml` (accept the legacy dotted
form `application/yang.data+xml` from buggy clients — it appears in the RFC's
own uncorrected examples).

* `get-bootstrapping-data` input: optional `signed-data-preferred`, `hw-model`,
  `os-name`, `os-version`, `nonce`. Output: `conveyed-information` (mandatory,
  base64 CMS), optional `owner-certificate` + `ownership-voucher` (only for
  signed data), optional `reporting-level` (minimal|verbose).
* `conveyed-information` is a DER CMS wrapping a JSON/XML document of module
  `ietf-sztp-conveyed-info`: either `redirect-information` (list of further
  bootstrap servers) or `onboarding-information` (`boot-image`,
  `configuration-handling` merge|replace, base64 `configuration`, pre/post
  scripts). Unsigned CMS = a plain ContentInfo with content type OID
  `id-ct-sztpConveyedInfoJSON` (1.2.840.113549.1.9.16.1.43) around an OCTET
  STRING — easy to emit ourselves; signing can be added later via `openssl cms
  -sign -nodetach` (this is what every existing implementation does).
* `report-progress`: 26 `progress-type` enum values (`bootstrap-initiated`,
  `parsing-*`, `boot-image-*`, `pre-script-*`, `config-*`, `post-script-*`,
  `bootstrap-warning/-error/-complete`, `informational`); `bootstrap-complete`
  may carry the device's **ssh-host-keys** — which we should store, since it
  lets us pin the host key for the subsequent NETCONF connection.
* Trust rules: a DHCP-discovered server is by definition *untrusted* → a
  compliant device only accepts **signed** onboarding info from us, and sends
  **no progress reports** to an untrusted server. Lab clients (OPI agent) don't
  enforce this. So: unsigned now [prototype], CMS signing + voucher handling as
  a later phase (§10).
* Transport is HTTPS-only per the RFC. Acton tip has both `net.TLSListener`
  and `http.TLSListener`, so a native HTTPS bootstrap endpoint is wiring work
  rather than a platform gap. The prototype serves plain HTTP (the OPI agent
  accepts http:// bootstrap URLs); adding the TLS listener (own port,
  configured cert/key) is phase 2 (§10).
* DHCP discovery: DHCPv4 option 143 / DHCPv6 option 136, content = list of
  `uint16 length + "https://host[:port]"` tuples. Kea has first-class support
  (`v4-sztp-redirect`) emitting the RFC-correct tuple encoding.

## 4. Where ZTP lives in StratoWeave

New platform package: `src/ztp/`. It is part of the platform (like
the device manager), not per-application code:

```
src/ztp/registry.act  -- ZtpRegistry actor + framework types (mechanism-agnostic)
src/ztp/sztp.act      -- SZTP bootstrap-server mechanism (RFC 8572 endpoints, CMS)
src/ztp/classic.act   -- classic ZTP mechanism (HTTP bootfile serving for opt 67)
```

```
                 northbound (RESTCONF /restconf/data)
                        │ device list config (incl. ztp container)
                        ▼
   CFS/RFS transforms ──► sw-rfs:device entries ──► TTT layer 2 ──► DeviceMgr.set_dmc()
                                                                       │
                                                                       │ dmc.ztp (serial, day-0 params)
                                                                       ▼
        ┌───────────────────────────────────► ZtpRegistry ◄──────────────────────────┐
        │                                   (actor, platform)                        │
        │   registers expected devices: serial ↔ device name ↔ day-0 intent          │
        │   tracks per-device ZTP state: phase, progress log, discovered address     │
        │                                                                            │
   HTTP routes (HttpServer)                                                 DeviceMgr/adapter
   /restconf/operations/ietf-sztp-...   (sztp.act)                 "discovered address" activation
   /ztp/v1/...                          (classic.act)
   /ztp, /device/{name}/ztp             (observability)
```

* **`ZtpRegistry`** (one per system, created in `stratoweave.main` alongside
  `DeviceRegistry`) holds, per device: the ZTP meta-config (from the device's
  dmc), lifecycle state, a progress log, and the discovered address. It exposes
  `match(serial | name) -> device`, `record_progress(...)`,
  `discovered(name, address)` to mechanisms.
* **Mechanisms** implement a small `ZtpMechanism` contract: install HTTP routes
  + react to per-device ZTP config. They never talk to `DeviceMgr` directly;
  everything flows through `ZtpRegistry`. A future Call Home mechanism is a
  listener that authenticates an inbound device and then calls the same
  `discovered()` — it fits without changes to the framework.
* **Identity matching**: SZTP identifies devices by serial number (TLS client
  cert on real gear; HTTP basic-auth username / `X-Serial` header for lab
  clients — same fallback google/open-sztp uses). Classic ZTP identifies by the
  per-device bootfile URL it was handed via DHCP (and we record the HTTP
  client's source address). The registry maps serial → device name from the
  `ztp/serial-number` leaf in device meta-config; if no serial is configured we
  fall back to device name = identity.

### Why in the platform and not a transform?

The bootstrap exchange is imperative request/response with side effects (HTTP
endpoints, protocol state machines) — the same category as the NETCONF adapter,
not a data transformation. The *intent* (which devices may ZTP, what day-0
looks like) is declarative and stays in the config model; the *state* it
produces (progress, discovered address) is operational data that we expose and
that transforms can consume (§6).

## 5. Data model

`stratoweave-rfs` (the platform device model in `src/swyang.act`)
gets a `ztp` container on the device list:

```yang
list device {
  ...
  container ztp {
    presence "Device may be zero-touch provisioned";
    leaf serial-number {
      type string;
      description "Device identity for ZTP matching (SZTP serial, etc.)";
    }
    leaf day0-config {
      type string;
      description
        "Override: verbatim day-0 bootstrap config. If unset, the day-0
         config is rendered from the device type's template.";
    }
    leaf format {
      // mechanism-agnostic: selects the day-0 template for both SZTP
      // onboarding-information and the classic bootfile
      type enumeration { enum xr-config; enum xe-python; enum raw; }
      default xr-config;
    }
    container sztp { leaf enabled { type boolean; default true; } }
    container classic { leaf enabled { type boolean; default true; } }
    container state {
      config false;
      leaf phase { type enumeration { enum waiting; enum bootstrapping; enum bootstrapped; enum connected; enum failed; } }
      leaf discovered-address { type inet:ip-address; }
      leaf serial-number { type string; }
      list progress {
        leaf timestamp ...; leaf source ...; leaf type ...; leaf message ...;
      }
    }
  }
}
```

Notes / review points:

* The `ztp` config rides on the existing device meta-config path
  (CFS transform → `o.device.create(...)` → `DeviceMgr.set_dmc`), so an
  application enables ZTP for a router by setting a few fields in its existing
  Router transform — no new wiring. `DeviceMgr` hands the ztp subtree to
  `ZtpRegistry` on every `set_dmc`.
* **Day-0 config is deliberately *not* the transform-produced target config.**
  At ZTP time the device has no modset, so RFS transforms cannot run yet; and
  day-0 wants native CLI/script, not the device-YANG payloads transforms
  produce. Day-0 is a minimal fixed-purpose artifact: credentials + enable
  NETCONF (+ keep DHCP on the mgmt interface). It is rendered from a per-device
  -type template (registered alongside `DeviceType`), with `day0-config` as a
  raw override. Everything beyond day-0 arrives via NETCONF afterwards — that
  separation is the whole point of the design.
* `ztp/state` is operational data. The prototype exposes it via the existing
  ad-hoc device HTTP endpoints (`/device/{name}/ztp`, `/ztp`); modeling it as
  proper `config false` data retrievable via RESTCONF (and subscribable by
  transforms) is the desired end state — see §6 and §10.

## 5.1 DHCP placement, prefix buckets, and the PE-side flow

This section captures the broader onboarding flow beyond the bootstrap server:
where DHCP lives, how the mode is chosen, and who renders the device config.
It generalizes the single "central Kea appliance" of §7 into one placement of
three. §7 now covers the two central placements in detail.

### Mechanism vs placement vs policy

Three independent axes; only the first is standardized:

* **Mechanism → DHCP option** is a pure standardized mapping StratoWeave
  derives: SZTP → opt 143 (v4) / 136 (v6); classic IOS-XR/XE ZTP → opt 67
  (+150 TFTP); Cisco PnP → opt 43. The option *value* is StratoWeave's own
  bootstrap URL, which it computes. Operators never hand-pick the option.
* **Placement** — central appliance vs inline-on-PE (server *or* relay) — is a
  topology fact the operator declares.
* **Policy** — pool layout, client-match, VRF, lease/temporal behaviour — is
  operator-supplied (with derived defaults where possible).

### The /31 makes the CPE address deterministic (no discovery needed)

The PE↔CPE link is a **/31** (or /30) that StratoWeave **allocates from a
pool**. The CPE necessarily receives the other end of that /31, so StratoWeave
**knows the CPE's management address at allocation time, before the CPE boots**
— it is assigned, not discovered. This dissolves the "we don't have the IP
early on" problem entirely: the device's meta-config gets its address from the
allocation up front. The classic-ZTP check-in (and any DHCP lease table) is
demoted from *address source of truth* to *liveness confirmation that the CPE
booted and took the lease*. (SZTP devices that learn their own address still
report it; for the /31 case we already know it.)

### Prefix buckets: choosing the mode without per-device DHCP config

Per-device DHCP customization is often impossible (the central DHCP server is
someone else's). Instead, pre-carve **prefix blocks where the block determines
the ZTP mode**: e.g. a /22 split into 1024 SZTP /31 links, a second block for
classic ZTP, etc. The DHCP server (managed or not) is statically configured to
serve the right option per block. The per-device choice "SZTP vs classic" then
becomes **"which pool do I allocate the /31 from"** — something StratoWeave
always controls, even when it cannot touch the DHCP server. This unifies:

* **Unmanaged central DHCP** — pre-provisioned bucket scopes; StratoWeave only
  allocates from the right block. No device config at all.
* **Managed central DHCP** (Kea we control) — StratoWeave renders buckets or
  per-device scopes.
* **Inline on PE** (server or relay) — an app transform renders the /31 +
  DHCP-server-scope or relay onto the PE.

The common spine in all cases: *allocate /31 from the mode's pool → configure
the PE interface → (maybe) server/relay config*. The mode lives in the prefix.

IOS-XR supports a local DHCP **server** (`Cisco-IOS-XR-ipv4-dhcpd-cfg`:
`mode server`, pools, `default-routers`, custom `option-codes`), so
inline-server-on-XR is viable; relay-to-central is the fallback where the
platform cannot run a server.

**Validated empirically** (probe, xrd-control-plane 25.3.1, 2026-06-12): a
factory XRd configured with `dhcp ipv4 / profile X server` + a DAPS `pool` bound
to a Gi data interface **does serve DHCP on that data port** — a Linux client on
the point-to-point link obtained a lease (`BOUND` in `show dhcp ipv4 server
binding`). Sending the **SZTP option 143** works as a generic option
(`option 143 hex <2-byte-len + URI>`), and the client received the exact RFC
8572 tuple. Caveat: **option 67 is reserved** in the generic option mechanism
(`'DHCP does not allow config for this DHCP option code'`); the classic-ZTP
bootfile is set via the dedicated `bootfile <name>` command in the server
profile instead. Net: inline DHCP server on an XR PE is real, with SZTP/opt-143
the clean path and classic/opt-67 via the bootfile command.

### Temporal ztp-mode (link lifecycle)

ZTP DHCP is transient. A per-link `ztp-mode` flips `on → off` driven by the ZTP
phase: while `on`, the PE interface carries the ZTP /31 + scope/relay; when the
CPE reaches `connected` (the registry tracks this), a transform flips
`ztp-mode=off` and either **releases the /31** to the pool or **keeps it as the
permanent management prefix** — per-link operator choice. This is the teardown
half of the reactive story (oper phase → transform re-run → PE config change),
using the same subscription pattern CFS transforms already use for telemetry.

### Division of labour: StratoWeave makes services, the app writes the config

StratoWeave does **not** produce concrete vendor DHCP/interface config — that is
entangled with the operator's network design (VRF, routing, pool layout,
server-vs-relay) and belongs in the app's transforms. The boundary:

* **Platform (StratoWeave core)**: the ZTP framework + bootstrap server; a pure
  **option/URL helper** (`mechanism → options + bootstrap URL`); the
  **lifecycle/phase** a transform can react to; and the small, uniform **CPE
  day-0** artifact (enable NETCONF + creds), already overridable.
* **App (operator transforms)**: the **PE-side network config** (interface /31,
  DHCP server scope or relay, VRF), the **pool/bucket model**, and the
  **ztp-mode lifecycle policy** — turned into a *service* StratoWeave drives.

To avoid every operator re-deriving "option 67 on IOS-XR", the platform may ship
**optional reference render helpers** per common vendor as a library the app
*may* call, but the transform and wiring stay app-owned (mirroring how the
platform provides the device adapter + RFS device model while `mini.rfs` is app
code).

## 5.2 StratoWeave ZTP-as-a-Service (driven by an upstream orchestrator)

A distinct deployment: StratoWeave-ZTP is *not* the orchestrator but a bounded
**onboarding service** an upstream system (e.g. Cisco NSO) calls. NSO owns the
device long-term; it asks StratoWeave to "zero-touch this device to day-0
ready", then takes over for day-1+ configuration. The reframe — request→result
with an ownership handoff, rather than "StratoWeave manages the device" — is the
healthier posture and resolves the two-orchestrator hazard.

### The contract

* **Onboarding request (NSO → StratoWeave)**: device identity (serial), placement
  (which PE/port, or central), the **day-0 intent** (ideally the access config
  NSO itself wants — the credentials/keys it will use), and the mechanism
  (sztp/classic). This *is* the `ztp-onboarding` service, reframed as a request
  API with NSO as the consumer. NSO speaks RESTCONF/NETCONF, so it can model
  StratoWeave as a device whose **config = onboarding requests** and whose
  **oper state = onboarding status** — native to both systems.
* **Onboarding result (StratoWeave → NSO)**: ready status, the device's
  **management address** (returned from the /31 allocation — no discovery), the
  **SSH host key** (captured from the SZTP `report-progress bootstrap-complete`)
  so NSO can pin it, and the provisioned identity. Exposed as `config false`
  oper state (subscribable/pollable); optionally pushed to NSO via a callout.

### Onboard-only ownership — forget the device once it is up (the load-bearing rule)

A SWZTPaaS device is **onboard-only**: StratoWeave serves it bootstrapping data,
tracks progress, and then **forgets it** — it never establishes a managing
NETCONF session and never reconciles the device's config. If StratoWeave kept a
managing session while NSO also configured the device, the two would fight
(drift, competing edits). Clean implementation: an `onboard-only` flag makes the
device manager keep a **NoAdapter** (the inert adapter) instead of building the
connecting NETCONF adapter, so the device registers for ZTP (the HTTP bootstrap
server + progress tracking need no adapter) but is never connected or managed.
The normal StratoWeave posture (own the full intended config) is the *other*
mode; `onboard-only` is the ZTPaaS one.

### Who defines "a certain level": NSO gives inputs, StratoWeave renders per-OS

NSO supplies day-0 **inputs** — the credentials/keys it wants on the device —
**not** the config text. StratoWeave computes the actual day-0 config, because
the correct config differs by device OS/version (an older OS needs different
commands); making NSO ship one config intent per OS would be backwards. So NSO =
parameters, StratoWeave = per-device-type rendering (the `_xr_config_body` /
`_xe_cli_lines` templates, parameterised by the supplied credentials). The
verbatim `day0-config` override remains an escape hatch, but the normal ZTPaaS
path is inputs-in, per-OS-config-out. Because NSO supplied the credentials, it
already holds them for the takeover.

### NSO needs no completion signal

NSO already has everything to detect readiness itself: it **allocated the /31**
(so it knows the device's management address) and it **supplied the credentials**
— so it simply polls the address and logs in when the device answers. StratoWeave
therefore does not need to push a handoff event. It **does** expose onboarding
status (phase, progress, captured SSH host key) as `config false` oper state; once
StratoWeave supports streaming telemetry, NSO (when it supports it) can subscribe
for progress instead of polling. No outbound callout to NSO is required.

(Note the IPAM ownership flips by deployment: in ZTPaaS **NSO owns IPAM** and
supplies the /31 / addresses in the request; standalone StratoWeave allocates
them itself. The `ztp-onboarding` request carries either explicit addresses
(NSO mode) or a link-index StratoWeave resolves (standalone mode).)

### Lifecycle

Request → in-progress → day-0-ready → forgotten. After day-0 the temporal
`ztp-mode` flips off (stop serving DHCP; release the /31 or keep it as the
now-NSO-managed management prefix). Onboarding status is the `ZtpRegistry` phase,
surfaced as oper state for NSO to read.

### What this adds to the prototype

Additive: an **onboard-only device mode** (NoAdapter — never connect/manage),
**day-0 credential inputs** in the onboarding request (flow into the device
credentials and thus the per-OS day-0 render), and an **onboarding-status oper
model** for NSO to read back (address + ssh-host-key + phase). The request side
already exists as the `ztp-onboarding` service.

## 6. The address problem — how a discovered IP activates the device

Today `NetconfDriver._connect()` simply waits when `dmc.address` is empty
(`"Not enough addressess :/"`), and any later `set_dmc` with an address
triggers a connect. That is exactly the right substrate: a device declared
without an address idles until ZTP learns one. The question is how the learned
address reaches the adapter. Three options considered:

**A. Direct activation (imperative shortcut).** `ZtpRegistry` calls
`DeviceMgr.set_discovered_address(addr)`; `DeviceMgr` keeps discovered
addresses as runtime state and, when building the adapter's effective dmc,
appends them *after* any configured addresses (configured always wins). The
config tree is untouched. **[prototype]**

**B. Reactive via oper-state subscription (StratoWeave-native).** ZTP state
(incl. discovered-address) is published as `config false` data; the
application's CFS Router transform subscribes (the exact pattern
`RouterTransform`/`BaseConfigTransform` already use for telemetry) and re-runs,
emitting `device/address[name='ztp']` as ordinary meta-config. The address then
*is* config, visible in the tree, diffable, persisted. This is the
architecturally honest version — "DHCP lease appears → transform reacts →
device connects" is precisely StratoWeave's reactive story.

**C. Platform writes config directly into the RFS layer** (the `RfsReconf`
precedent: `_rfs.edit_config(..., force=True)`). Rejected: it puts a platform
actor in the business of authoring user-visible config behind the transforms'
backs, and ownership/merge semantics get murky.

Recommendation: ship **A** as the built-in default (zero app-code burden,
config always overrides), and build **B** on top once ZTP oper state is
modeled, letting applications that want the address in the config tree opt in
via their own transform. A and B compose — B just makes A's fallback unused.
**Review point: does this match your taste?**

There is a second flavor of B worth discussing: subscribe to the **DHCP
server's lease table** instead of the ZTP exchange (the Kea device's oper
state). More general (works for devices that never speak to StratoWeave during
bootstrap, e.g. cRPD), but it couples address learning to managing the DHCP
server, and lease ≠ "device is ready". The ZTP exchange itself is the better
signal when it exists.

## 7. DHCP server: the central placements

§5.1 lists three DHCP placements: unmanaged central, managed central, and
inline on the PE. This section covers the two central ones. Inline-on-PE is the
`ztp-onboarding` service and uses no Kea.

A device onboards through exactly one placement. One deployment can mix
placements, because the prefix bucket selects the placement per link (§5.1).

### Kea findings

* **kea-netconf is no longer experimental** (Kea 3.0 LTS). It gives a true
  NETCONF/YANG-managed DHCP device (`kea-dhcp4-server` YANG through sysrepo).
  Setup complexity is high. No ISC package or container includes it, so a
  deployment needs a source build of Kea, libyang3 and sysrepo3. The NETCONF
  wire protocol also needs netopeer2. kea-netconf has no rollback and no
  operational datastore, so NETCONF cannot read the lease table.
* Each Kea daemon from version 2.7.2 has a native **HTTP control socket**. The
  official `docker.cloudsmith.io/isc/docker/kea-dhcp4` image needs no changes.
* Kea sends **RFC-correct option 143** from a comma-separated URI list
  (`"name": "v4-sztp-redirect"`). Options 66 and 67 need no special handling.

**Validated empirically** against `kea-dhcp4:3.0.3` (probe, 2026-08-19), driving
the control socket the way the adapter will:

* The **core** command set is 28 commands: `config-get`, `config-set`,
  `config-test`, `config-write`, `config-hash-get`, `status-get`, `version-get`,
  `statistic-get-all` and friends. `lease4-get-all` is **not** among them — it
  belongs to the `lease_cmds` hook library, and per-subnet pool utilisation
  (`stat-lease4-get`) to `stat_cmds`. The image ships every hook library under
  `/usr/lib/kea/hooks/`, so both are one `hooks-libraries` entry away, but a Kea
  that has not loaded them exposes no lease table at all. The lab config now
  loads `lease_cmds` and `stat_cmds`; without them `make kea-leases` fails.
* **`config-set` is the only write path** open source Kea offers for
  reservations. `reservation-add` answers `Host database not available, cannot
  add host.` unless a `hosts-database` backend is configured, and file-defined
  reservations never appear in `config-get`'s subnet entries once added that
  way. `subnet4-add`/`subnet4-update` (from `subnet_cmds`) do mutate the running
  config, so incremental subnet writes are available later as an optimisation —
  but they do not cover reservations, so they cannot be the primary path.
* **`config-set` replaces the whole configuration**, and omitting
  `control-sockets` from it succeeds and then **permanently locks the manager
  out** — the HTTP listener stops and only a process restart brings it back.
  This is what forces the read-modify-write ownership model in stage 2 below.
* `config-get` returns a **fully-defaulted** config: 51 top-level `Dhcp4` keys,
  with every unset leaf filled in. Any model of a subset must therefore know
  Kea's defaults, or every reconcile diffs against leaves it never set.
* Kea **rewrites some values it is given**: a pool range loses the padding
  around its separator (`10.0.0.1 - 10.0.0.9` reads back as
  `10.0.0.1-10.0.0.9`), and a `client-id` loses its colons (`01:02:03:04:05`
  reads back as `0102030405`). Both are list keys in the model, where a rewrite
  would read as a different entry, so the adapter canonicalises them.
* `config-hash-get` returns a SHA-256 of the running config, and an accepted
  `config-set` returns the new hash in its response. That is the device txid.
* The HTTP control channel takes **optional basic auth**
  (`control-sockets[].authentication`, `type: basic`, credentials from a
  password file). 3.0.3 serves an unauthenticated channel happily — verified on
  both the ISC image and an Alpine build — but an authenticated one answers 401
  without credentials, so the adapter has to send them from the device
  meta-config `credentials` and must not assume either mode.
* **Alpine packages the same Kea 3.0.3** (`alpine:3.24`: `kea-dhcp4` plus
  `kea-hook-lease-cmds` / `kea-hook-subnet-cmds` / `kea-hook-stat-cmds`) at the
  same `/usr/lib/kea/hooks/` path, which is how the c8000v ZTP test server in
  `vrnetlab` is built. It needs no third-party registry and pulls only the hooks
  the config loads, where the ISC image carries all twenty. Either works; the
  lab stays on the ISC image because it already has what it needs.

The model below was validated against both builds: rendered from the compiled
adata, transcoded, spliced into a live `config-get`, applied with
`config-test` + `config-set` through basic auth, and read back — subnets,
pools, options and reservations all round-trip, with `control-sockets` and
`hooks-libraries` untouched.

### Stage 1 — unmanaged central DHCP (shipped)

A Kea container in the containerlab topology reads a static config file.
StratoWeave does not configure Kea. The file holds the mgmt-subnet pool, an
`always-send` option 143 that points at the StratoWeave SZTP endpoint, and
per-device host reservations that carry option 67 bootfile URLs for classic ZTP.

The prototype lab uses this placement (§8).

### Stage 2 — managed central DHCP (built)

StratoWeave configures Kea as a device. Three parts:

1. **A `kea-dhcp4` YANG module** — `minisys/gen/yang/dev-kea/kea-dhcp4.yang`,
   the `kea` device type. **Built.**
2. **A `KeaAdapter(DeviceAdapter)`** — `src/adapters/kea.act`. **Built.**
3. **An app transform** that produces the DHCP config from the same intent
   that declares the routers, so declaring a ZTP-enabled router provisions
   that router's DHCP reservation and bootstrap options. **Built.**

Stage 2 also shows that `DeviceAdapter` is pluggable beyond NETCONF.
`build.act` used to hardcode `adapter_type=NetconfAdapter` for every generated
device type; it now takes an `AdapterRef` per type
(`DeviceType.from_dir(..., adapter=swbuild.kea_adapter())`), emits the import,
and names the class in the generated sysspec. NETCONF stays the default.

#### The model

`kea-dhcp4` models 9 of Kea's 51 top-level `Dhcp4` keys: `subnet4` (with
`pools`, `option-data`, `reservations` and `relay`), global `option-data`, and
the handful of global leaves ZTP touches. There is no config-false tree — see
"Operations as RPCs" below.

Three decisions follow directly from the findings above.

**Ownership is per top-level key, and the adapter reads before it writes.**
Since `config-set` replaces everything and dropping `control-sockets` locks us
out, the adapter never sends the model as the whole config. It reads the
running config, replaces the keys the model defines, and sends the result back.
A key the model defines is StratoWeave-owned — the model is authoritative, so
an absent entry is a deletion. Every other key — `control-sockets`,
`hooks-libraries`, `lease-database`, `interfaces-config`, `loggers`,
`client-classes`, `option-def` — is device-owned and passes through untouched.
So the operator keeps the server's plumbing, and a `client-class` the model
references may be defined in the operator's own configuration.

**Under `Dhcp4` the node names are Kea's JSON keys verbatim.** The rendered
gdata is already Kea JSON except for two rules: drop the `kea-dhcp4:` module
prefix from the root, and turn a reservation's `identifier-type`/`identifier`
pair into the single Kea identifier leaf it names. The pair exists because Kea
identifies a host by whichever of `hw-address`/`client-id`/`circuit-id`/`duid`/
`flex-id` the entry carries, which YANG cannot key on — naming the identifier
makes "exactly one" hold structurally instead of by `must`. `option-data` keys
on `(space, code)`, Kea's own identity for an option, and deliberately does not
model the `name` Kea derives from the code: it would be absent from every
target and present in every running config.

**Every default matches Kea's.** `config-get` fills in what it was not given,
so the adapter drops running leaves equal to their schema default before
diffing, reading the defaults out of the compiled schema rather than a
hardcoded table. This works for a leaf with a fixed default. It does not work
for `subnet4/valid-lifetime`, which Kea inherits from the global scope and then
reports as the subnet's own value; the adapter cannot tell an inherited value
from one the operator set to the same number, so the model's description tells
the caller to set it. That is the only inherited leaf in the model.

#### Operations as RPCs

Kea has no operational datastore. Everything the ZTP flow reads — the lease
table, pool utilisation, server health — comes from a control-channel command,
and the useful ones take parameters (`lease4-get-by-hw-address`,
`stat-lease4-get` by `subnet-id`). A config-false tree cannot express a
parameter, so the model declares one `rpc` per command instead: the RPC name is
the Kea command, the input leaves are the keys of the Kea `arguments` object.

This is the same shape as JUNOS, where much of the state is reachable only by
RPC, so it is the case a device-adapter framework has to handle anyway rather
than a Kea peculiarity. `acton-yang` already generates the machinery: typed
input and output adata classes plus an `rpc_root` actor per module, wired
through `TreeProvider.rpc` → `DeviceMgr` → the adapter.

Two consequences:

* **No subscriptions on a Kea device.** The reactive transform path
  (`SubscriptionManager` → `declare_subscriptions`) runs over the oper tree, and
  there is no oper tree. `KeaAdapter.declare_subscriptions` reports that
  plainly rather than failing silently. Nothing in the ZTP flow subscribes to
  Kea today — the `ztp-mode` teardown of §5.1 triggers off the registry phase,
  not the lease table. Should a subscriber appear, a small polled state tree
  can be added back alongside the RPCs.
* **The RPC transport is gdata.** `DeviceAdapter.rpc` takes and returns
  `ygdata.Node`. The call is a container that holds one child, named by the
  namespace and the name of the RPC, and that child holds the input. A JSON
  device needs no envelope around that: the RFC 7951 encoding of the input is
  the Kea `arguments` object, so a `uint32` reaches Kea as a number and not as
  a string. The adapter reshapes only the three replies below. A NETCONF
  device renders the same two trees to XML and back, which is where an
  envelope belongs.

Eleven commands are modelled: six reads (`lease4-get-all`, `lease4-get`,
`lease4-get-by-hw-address`, `stat-lease4-get`, `status-get`, `version-get`) and
five writes (`dhcp-disable`, `dhcp-enable`, `lease4-wipe`, `leases-reclaim`,
`config-write`). Three replies do not follow "output equals arguments" and the
adapter holds all three: `lease4-get` returns the lease fields unwrapped,
`version-get` puts the version in the reply's `text` field, and
`stat-lease4-get` answers with a `columns`/`rows` table that YANG cannot
express, so the adapter joins each row to the column names.

The two hook-backed command groups are YANG features — `lease-commands` and
`statistics-commands`. The adapter reads `list-commands` at connect and reports
the features it found in the `ModCap`, so a caller can tell "the hook is not
loaded" from "there are no leases".

#### The adapter

`src/adapters/kea.act` follows the `NetconfAdapter` shape: a `KeaAdapter`
facade over a `KeaDriver` actor that owns the HTTP channel. The driver keeps
one command in flight and queues the rest, because Kea matches replies to
requests in order and the control channel carries little traffic.

* `fetch_config` → `config-get` + `config-hash-get`, projected onto the model,
  with the hash as the device txid.
* `configure` → `config-get`, splice, `config-test`, `config-set`, then read
  back. `config-test` failure maps to `ConfigError` so DeviceMgr stops instead
  of retrying a configuration Kea has already refused.
* Result code 3 is success with no data (`lease4-get-all` on an empty table),
  code 2 is an unsupported command (usually a hook that is not loaded), code 4
  is a transient conflict.
* Basic auth comes from the device meta-config credentials and is optional, so
  the adapter works against both an open and an authenticated control channel.

`minisys/src/test_mini_kea.act` covers the transcoding against the real
compiled schema. `minisys/src/test_mini_kea_live.act` drives the whole adapter
against a Kea container (`acton test --tag kea`): read, two writes with a
content change between them, read back, then the RPCs. It asserts that the
second read still answers, which is the check that the splice kept
`control-sockets`.

#### The transform

The transform is app code, not platform code — §5.1 puts the vendor DHCP
config on the app side. It is in `minisys`, and it has two halves that meet
at the device.

**The server and its scopes.** A new CFS list `netinfra/dhcp-server` declares
a managed DHCP server: its management address, its credentials, and a `scope`
list. `mini.cfs.DhcpServer` turns each server into a StratoWeave device of
type `kea` and each scope into one `dhcp-scope` RFS service. `mini.rfs.DhcpScope`
renders that service into `Dhcp4/subnet4`: the prefix, the pool, the default
router, and — when the scope enables it — the SZTP redirect as an
`always-send` option 143. A scope is a prefix bucket in the sense of §5.1, so
every router that onboards through it gets the same subnet-wide options.

**The routers and their reservations.** A ZTP router adds a `ztp-dhcp`
presence container that names the server, the scope, the router's hardware
address and the address to reserve. `mini.cfs.Router` then emits one
`dhcp-reservation` RFS service against the *server's* RFS, and
`mini.rfs.DhcpReservation` renders it into `subnet4/reservations`. The boot
file of classic ZTP is per router, because the URL carries the router name,
so it belongs on the reservation and not on the scope.

Two results follow from this shape.

* **The services merge into one scope.** `DhcpScope` writes
  `subnet4[id]` with the prefix and the pool, `DhcpReservation` writes
  `subnet4[id]` with one reservation, and the RFS layer merges them. So a
  router joins a scope by declaring itself, and no transform rewrites the
  whole server. Removing the router removes its reservation, which the
  adapter's ownership rule turns into a deletion on the server.
* **The reservation gives StratoWeave the management address.** The router's
  device meta-config takes its address from `ztp-dhcp/address`. This is the
  central-DHCP form of the /31 argument in §5.1: the address is assigned, not
  discovered, so StratoWeave knows where to reach the router before the router
  boots. The bootstrap check-in confirms that the router took the lease.

A ZTP router enables both mechanisms today, because the device meta-config
defaults `ztp/sztp/enabled` and `ztp/classic/enabled` to true and the CFS
router model has no switch. So a reservation carries a boot file and the
scope sends the redirect. Option 143 outranks option 67 on the platforms that
read both, so such a router takes the SZTP path.

`minisys/src/test_mini.act::_test_managed_dhcp` snapshots the Kea device
configuration that one server plus two ZTP routers produce.
`_test_managed_dhcp_removal` then removes the `ztp-dhcp` container from one
router. It shows that the router's reservation disappears, and that the scope
and the other reservation stay. The live test writes the rendered
configuration to a real Kea container, which covers the whole path from the
northbound intent to the server.

The quicklab-ztp lab still uses the stage 1 static file. Moving it to the
managed placement needs per-router hardware addresses, and containerlab does
not pin the MAC of a node on the management network, so the reservations
would not match. A lab on a point-to-point topology, where the MACs are
declared, can use the managed placement as it stands.

kea-netconf stays an option for later. The stage 2 YANG intent is a strict
subset of what `kea-dhcp4-server` expresses — the tree differs, since it
mirrors Kea's JSON rather than ISC's YANG — so a later move from the REST
adapter to plain NETCONF would remap the device model but would not change the
application model above it.

**Review point:** is an in-tree Kea adapter the right scope for stage 2? The
alternative keeps the StratoWeave southbound NETCONF-only and runs kea-netconf.

## 8. Test environment (containerlab)

New testenv `minisys/test/quicklab-ztp/`, following the existing quicklab
pattern (same clab.mk / quicklab.mk machinery):

```
mgmt network "ztpnet" (explicit subnet, e.g. 172.31.255.0/24, clab assigns .2-.99)
├── sweave        minisys image; HTTP :80 (RESTCONF NB + SZTP + classic ZTP)
├── kea           docker.cloudsmith.io/isc/docker/kea-dhcp4:3.0.3; pool .100-.199
│                 opt 143 → http(s)://<sweave>; per-host opt 67 → http://<sweave>/ztp/v1/...
├── xrd1          xrd-control-plane:25.3.1, XR_ZTP_ENABLE=1, no snoop flags,
│                 no first-boot config → ZTP: DHCP on Mgmt → fetch !! IOS XR config → netconf
├── sztp-dev1     ghcr.io/opiproject/sztp-agent: full RFC 8572 client incl. report-progress
└── (stretch) c8000v in ZTP mode (§8.3), crpd day-0 (§8.4)
```

**Placement:** this lab uses stage 1 of §7, unmanaged central DHCP. Kea reads a
static config file and StratoWeave does not configure it. The lab has no PE and
no /31: xrd1 runs DHCP on its management port over the shared clab bridge.

The inline-on-PE placement of §5.1 has no lab. It exists as the
`ztp-onboarding` CFS service plus the `ztp_onboarding` snapshot test in
`test_mini`, which checks the rendered PE config without booting a device.

Demo script (the acceptance test):

1. `make start run-bg` — lab up, mini running with a startup config that
   declares `xrd1` (type, serial, ztp enabled) but **no address**.
2. XRd boots factory-default, DHCPs, fetches its day-0 config, comes up with
   NETCONF + credentials. StratoWeave sees the bootfile fetch (and/or SZTP
   progress for sztp-dev1), records the address, connects, discovers modset,
   RFS reconf pushes config.
3. `curl .../device/xrd1/ztp` shows the progress log; for sztp-dev1 the full
   RFC 8572 report-progress stream is visible.
4. `curl -X PATCH .../restconf/data` changing the router's hostname — applied
   via NETCONF: **the "good result" from the task statement.**

### 8.1 DHCP addressing detail

containerlab assigns container IPs on its mgmt bridge via docker IPAM —
that is fine: docker bridges run no DHCP server, so Kea (a normal container on
the same bridge) answers the XRd/c8000v DHCP broadcasts. We give the lab an
explicit subnet and let Kea lease from a high range to avoid colliding with
docker-assigned addresses.

### 8.2 TLS

SZTP mandates HTTPS. The OPI agent and the prototype run plain HTTP/insecure
mode where possible; if the agent insists, an nginx sidecar terminates TLS
(self-signed) and proxies to sweave:80, forwarding the client-cert serial as a
header. Real device support needs a native TLS listener in Acton (§10).

### 8.3 c8000v (stretch)

Our `vr-c8000v` images are old-style vrnetlab: at runtime the launcher types a
bootstrap config over the serial console (no config ISO at runtime — good), the
mgmt NIC is QEMU slirp user-mode networking (DHCP answered inside QEMU — bad),
and data NICs are TCP-socket netdevs (vr-xcon style, not containerlab veths —
bad). To ZTP a c8000v we build a lab-local derived image (reusing the qcow2
from the existing image, which is already serial-console-enabled by the install
phase):

* skip the console bootstrap entirely (no console input — input kills day-0),
* readiness = watching for PnP/ZTP console messages instead of config-done,
* mgmt NIC as a tap bridged to `eth0` (the hellt/vrnetlab "passthrough"
  pattern) so the DHCP broadcast reaches the lab network,
* DHCP scope for it must send option 67 only (no 43/143, which outrank 67).

The day-0 artifact is a Python script (Guest Shell): configure user, AAA,
`netconf-yang`, `ip address dhcp` on Gi1, `write memory`. This is genuinely a
day of fiddly work and is kept out of the core prototype.

### 8.4 cRPD (stretch)

No ZTP client exists in cRPD; "zero-touch" means the *environment* mounts a
day-0 `juniper.conf` (exactly what containerlab does). The honest StratoWeave
demo: declare the cRPD device with credentials matching the day-0 file, let the
lab mount render from StratoWeave's classic-ZTP endpoint at deploy time
(`curl .../ztp/v1/device/crpd1/bootfile > juniper.conf` in the Makefile), and
onboard over NETCONF once it boots. ZTP-shaped, but the "fetch" is done by the
lab tooling, not the device.

## 9. Prototype scope (what is being built now)

* `stratoweave.ztp` package: `ZtpRegistry`, mechanism contract, SZTP mechanism
  (both RPCs, JSON encoding, unsigned CMS conveyed-info, progress capture,
  ssh-host-key capture), classic mechanism (per-device bootfile endpoint,
  XR config + XE python templates, fetch tracking).
* `ztp` container in `stratoweave-rfs` YANG + regenerated
  `device_meta_config.act`; `DeviceMgr` → `ZtpRegistry` wiring; discovered-
  address activation (option A); `/ztp` + `/device/{name}/ztp` observability
  endpoints.
* `quicklab-ztp` testenv: sweave + Kea (static config) + XRd-ZTP + OPI
  sztp-agent; Makefile targets mirroring the existing quicklabs; demo flow of
  §8 scripted.
* Actor-level tests: SZTP RPC handlers (request → response golden tests),
  classic bootfile rendering, registry matching/lifecycle.

Explicitly out of prototype scope, designed-for: CMS signing and vouchers, TLS
listener, the Kea adapter (stage 2 of §7), c8000v image work, and DHCPv6 /
option 136. The option 136 encoder is shared with option 143, but the v6 lab
plumbing does not exist.

## 9.1 Prototype findings (what the lab taught us)

The quicklab-ztp environment (sweave + Kea + factory-default XRd 25.3.1 +
OPI sztp-agent) runs the §8 demo end to end: XRd onboards from factory
state to NETCONF-managed, and a hostname change made through the normal
northbound lands on the device. Things learned by running it:

* **IOS-XR ZTP probes the bootfile with `HEAD` before `GET`.** A bootstrap
  server that only routes GET returns 404 to the probe and XR gives up
  (and retries forever). We serve both.
* **A ZTP script cannot commit `ipv4 address dhcp` on the management
  interface** while bootstrap is running: XR's ipv4-ma rejects it
  ('Interface is already configured by other type of client') because
  ZTP's own DHCP client holds the interface, and the whole commit rolls
  back atomically. The day-0 script instead reads the leased
  address/prefix/gateway from the Linux network state and persists them
  as *static* config — which also guarantees the address survives ZTP
  releasing its lease at exit.
* **The OPI sztp-agent is stricter than the RFC in one direction and
  looser in another**: it rejects unknown fields in the RPC output (so we
  omit `reporting-level`, which is RFC-correct anyway for an untrusted
  transport) and it expects 200 for report-progress where RFC 8572
  mandates 204 (it logs an error and continues; we stay RFC-correct).
* **XRd identifies itself in DHCP option 61** with its serial (e.g.
  `VSN-GW673EG`) — usable later for per-serial Kea host reservations
  instead of the pool-wide option 67 the lab uses.
* **In-memory ZTP state does not survive a StratoWeave restart** (phase,
  progress log, discovered address). The discovered address is re-learned
  on the next device check-in / bootstrap retry, but this strengthens the
  case for modeling ZTP state as proper oper data (§6 option B).
* The XRd lab state (`clab-*/xr-storage`, root-owned) breaks `docker
  build` contexts and occasionally acton's project scan; the lab dir
  carries a `.dockerignore` and the Makefile copies the prebuilt binary.

## 10. Future work

1. **HTTPS for the SZTP endpoints** — `http.TLSListener` exists in acton tip;
   serve the bootstrap routes on a dedicated TLS port with a configured
   cert/key, and extract the device serial from the TLS client certificate.
2. **Signed conveyed-info**: `openssl cms -sign -nodetach -econtent_type
   1.2.840.113549.1.9.16.1.43` via the `process` module, with
   owner-cert/voucher storage modeled per device (matches what Cisco
   XR/Juniper require; vouchers come from MASA/JAL per serial). Then real
   hardware works against this server unmodified.
3. **ZTP oper state as modeled `config false` data** + transform
   subscriptions (option B of §6); device `state` container is the natural
   home.
4. **Managed DHCP follow-ups** — stage 2 (§7) is built end to end.
   What remains is smaller: move the quicklab-ztp lab from the static file to
   the managed placement, which needs a topology that pins each router's
   hardware address; `subnet4-add`/`subnet4-update` from the `subnet_cmds`
   hook as an incremental write path for subnets (it does not cover
   reservations, so `config-set` stays the primary path); and kea-netconf as
   an alternative southbound.
5. **NETCONF Call Home (RFC 8071)** as a third mechanism — the natural
   onboarding path for devices behind NAT; pairs well with SZTP's
   `bootstrap-complete` ssh-host-key pinning.
6. **Image/boot-image serving** in onboarding-information (os upgrades during
   bootstrap) — model exists in conveyed-info; needs an artifact store.

## 11. References

* RFC 8572 (SZTP), RFC 8040 §3.1/§3.6 (RESTCONF root discovery, operations),
  RFC 8071 (Call Home), RFC 8366 (vouchers), RFC 9646 (SZTP CSR).
* IOS-XE Programmability Guide 17.15/17.18, ZTP chapter (SZTP platform matrix;
  classic ZTP mechanics; option precedence 43/143 > 67 > autoinstall).
* Cisco 8000 Setup Guide, classic ZTP chapter (option 67, `!! IOS XR`
  config-vs-script detection, ztp.ini); xrd-tools `launch-xrd`
  (`XR_ZTP_ENABLE`); xrdocs XRd knobs tutorial.
* Kea ARM: control channel (`config-set`), YANG/NETCONF integration chapter;
  Kea `std_option_defs.h` (`v4-sztp-redirect`, 2-byte tuple lengths).
* Existing SZTP servers studied: Watsen `sztpd` (reference, non-prod license),
  google/open-sztp (Go, header-based serial, pkcs7 signing),
  opiproject/sztp (agent + dockerized sztpd + ISC dhcpd option-143 example).
