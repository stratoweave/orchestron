# Software upgrades in StratoWeave

Status: draft. This document describes the current implementation and the work
still needed before software upgrades are safe to run without manual recovery.

The current implementation supports an IOS XE upgrade with two NETCONF RPCs:
copy the image to bootflash, then install it with `one-shot=true`. It checks the
running release before starting, waits for the device to return on the requested
release, publishes basic operational state, and resyncs the device schema.

CI runs the same path against an in-process NETCONF mock. A live-device run is
still required before release because the mock cannot reproduce IOS XE reload,
resource, and transport failures.

## 1. Scope

`SoftwareManager` owns the sequence for one device. `SoftwareAdapter` implements
the platform operations. The manager is declarative: configuration says which
release the device should run, and the manager moves the device toward it.

Software is treated as one release string per device. Platforms with separately
versioned components are not supported by this API.

The current manager implements:

```text
check -> already running? -> up-to-date
  |
  +-> prepare -> install -> check -> resync -> succeeded
          |          |
          +----------+-> failed
```

The following parts of the model and API are not implemented yet:

- early staging controlled by `allow-staging`;
- pre-install and post-install checks;
- rollback, abort, and cleanup;
- per-job progress and timestamps;
- retry and recovery after a process restart;
- fleet scheduling and maintenance-window capacity.

The IOS XE implementation therefore needs an operator who can recover a device
when installation fails or the device returns with broken services.

## 2. Current manager behavior

Every `DeviceMgr` owns one `SoftwareManager`. A device type supplies a
`SoftwareAdapter`; device types without one use `NoSoftwareAdapter`, which
reports unsupported operations.

The current reconcile rules are:

1. If no `target-release` is set, do nothing.
2. If any veto exists, do nothing. The veto currently blocks the initial read,
   staging, and installation.
3. Read the running release with `check`.
4. If the adapter says the running and requested releases match, publish
   `up-to-date` and stop.
5. If the read fails, log the error and continue. A failed read is not treated
   as evidence that the device is already up to date.
6. Publish `in-progress`, call `prepare`, then call `install`.
7. After `install` succeeds, read the release again, resync the device, and
   publish `succeeded`.
8. A `prepare` or `install` error publishes `failed`.

The manager sets `busy` before the initial read and clears it after the final
read or an error. Repeated configuration while a run is active does not start a
second sequence.

`upgrade-campaign` and `allow-staging` are stored but do not affect the current
sequence. In particular, `target-release` alone is enough to start work.

Run state is held in memory. After a process restart, restored configuration can
start a new reconcile. A later write to any part of the device meta
configuration can also call `set_config` again. A failed run is not sticky: if
the target still differs, a later reconcile can try again. These behaviors need
to be made explicit and safe before automatic fleet use.

### 2.1 Release comparison

The manager delegates version equality to `SoftwareAdapter.matches_release`.
The default is an exact string match. IOS XE compares numeric components so
zero padding does not matter:

```text
requested: 17.18.03a
reported:  17.18.3a
```

Without this comparison, an already-correct device can be copied, installed,
and reloaded only to return to the same release. IOS XE can report such a no-op
as successful, so the check must happen before the impacting RPC.

## 3. Configuration and operational state

Software configuration is under `stratoweave-rfs:device/software`.

| Node | Current use |
|---|---|
| `upgrade-campaign` | records which campaign owns the device; not used to gate the current reconcile |
| `target-release` | release the device should run; its presence starts reconciliation |
| `image-url` | URL IOS XE uses as `xcopy/source-path` |
| `allow-staging` | reserved for scheduling `prepare` ahead of the maintenance window; currently ignored |
| `veto[holder]` | blocks the whole current reconcile while any entry exists |

`image-url` is a full URL because the device pulls the image. The final path
component becomes the bootflash filename. IOS XE supports SCP, FTP, HTTP, and
HTTPS for this operation.

SCP and FTP URLs may embed credentials. The leaf is readable anywhere device
configuration is readable. Generic device and RPC debug logging also serializes
configuration and RPC input today, so adapter-level URL redaction is not enough.
Do not treat an embedded password as protected until the configuration and
logging paths are changed.

### 3.1 Published state

Operational state is published under:

```text
stratoweave-rfs:device=<name>/software/state
```

`SoftwareManager` sends a `SoftwareState` copy to `DeviceMgr` whenever `status`
or `running-release` changes. `DeviceMgr` merges it into the device entry's
operational tree and calls the TTT device node's `update_oper`. Registration
replays the current state, so a device node created after a state change still
gets the latest value.

The manager currently populates:

| Node | Value |
|---|---|
| `status` | `unknown`, `up-to-date`, `in-progress`, `succeeded`, or `failed` |
| `running-release` | last release returned by `check`, using the device's spelling |

The YANG model also contains `upgrade-needed`, `rolled-back`, `job`, `precheck`,
and `postcheck`. The current manager does not publish those values.

Operational reads return the current state. `update_oper` does not trigger a
TTT recompute, so a northbound subscription does not receive these changes yet.
State is not persisted and returns to `unknown` when the process restarts.

## 4. Software adapter API

The platform interface is defined in `src/device.act`.

| Method | Contract |
|---|---|
| `supports_mocking()` | whether the adapter can use the device NETCONF mock |
| `check(done)` | read the running release |
| `matches_release(running, target)` | compare the device's release spelling with requested intent |
| `prepare(done, release)` | stage and verify the image without activating it |
| `install(done, release)` | perform the impacting activation and reboot |
| `rollback(done, previous)` | return to the previous release |
| `cleanup(done)` | remove superseded images |
| `estimate(staged)` | estimated install time in seconds |

Jobs are asynchronous and report through callbacks. `install` must call
`done(None)` only after the device is reachable again and the requested release
has been confirmed running.

The intended contract says `install` rechecks its preparation because an image
staged earlier may have been removed. The current manager always calls
`prepare` immediately before `install`, and the IOS XE `install` method assumes
that copy is still present. The adapter needs to verify bootflash and repeat
staging when necessary.

`IosXeSoftwareAdapter` is a class with no mutable run state. It forwards work to
`IosXeSoftwareDriver`, an actor that owns the active phase, UUID, poll count,
release, filename, and completion callback. This keeps mutable state behind one
actor mailbox even though the adapter class can be referenced from more than one
actor.

## 5. Current IOS XE implementation

The adapter uses two operations:

| Manager step | IOS XE operation | Impacting |
|---|---|---|
| `prepare` | `xcopy` the image to bootflash | no |
| `install` | `install` with `one-shot=true` | yes |

With `one-shot=true`, IOS XE adds the image, activates it, commits it, and
reloads. The adapter does not send separate `activate` or `install-commit` RPCs.

### 5.1 Staging

`prepare` sends:

```xml
<xcopy xmlns="http://cisco.com/ns/yang/Cisco-IOS-XE-xcopy-rpc">
  <uuid>swi-stage-17.18.03a-1787894090-91366</uuid>
  <source-path>https://images.example/c8000v.17.18.03a.bin</source-path>
  <destination-path>c8000v.17.18.03a.bin</destination-path>
</xcopy>
```

`source-path` is `image-url` verbatim. `destination-path` is only the filename;
IOS XE prepends bootflash itself.

The `xcopy` reply contains an echoed UUID but no completion result. After the
RPC is accepted, the adapter polls `install-oper-data` for records with its UUID.
Staging succeeds only when a completed successful record contains
`install-txn-download`.

### 5.2 Installation

`install` sends:

```xml
<install xmlns="http://cisco.com/ns/yang/Cisco-IOS-XE-install-rpc">
  <uuid>swi-install-17.18.03a-1787894412-27718</uuid>
  <one-shot>true</one-shot>
  <path>bootflash:c8000v.17.18.03a.bin</path>
</install>
```

The install RPC has no output. `<ok/>` means IOS XE accepted the request; it
does not mean the installation completed.

After acceptance, the device reloads. Reads and connections fail during this
period and are not treated as job failures. The adapter polls
`device-system-data/software-version` until it can read a release equivalent to
the target. Only then does `install` report success to the manager.

The manager performs one final `check` to refresh `running-release`, then calls
`DeviceMgr.resync` because the new release may expose a different module set.
A failure of this final read is logged but does not undo an installation that
the adapter already confirmed.

### 5.3 Operation records

IOS XE keeps active and finished operations in sibling lists:

```text
Cisco-IOS-XE-install-oper:install-oper-data
  install-oper
    op-uuid, op-id, op-status, op-done
    install-txn-summary-op
      txn-cmd, txn-status
  install-oper-hist
    op-uuid, op-id, op-status, op-done
    install-txn-sum-op-hist
      txn-cmd, txn-status
```

One RPC can create several records with the same UUID. `op-id` restarts for each
operation, so the adapter correlates by UUID and checks all matching records.
A record moves from the active list to history when it finishes, and that move
can happen between polls.

`install-op-marked-succ` means IOS XE had nothing to do. It is not an error, but
it is not proof that requested work happened. `op-done=op-reverted` is another
terminal value in the vendor model; the current adapter handles only
`op-complete` and must be extended before rollback is implemented.

### 5.4 Filters

The version read selects only `software-version`. Operation polling selects the
complete `install-oper` and `install-oper-hist` lists while excluding large
siblings such as `install-packages`.

Leaf selection inside these keyless lists is broken in the pinned
`acton-yang`: every entry has the same empty key and filtering collapses them.
Selecting an empty list with leaf children can also discard a matching sibling.
The complete-list filter avoids both paths.

TODO: Select only the required record leaves after `acton-yang` preserves all
keyless-list entries and an empty selected list no longer drops matching sibling
data. Measure the IOS XE reply size again after changing the filter.

### 5.5 Time bounds and estimates

The driver counts polls and fails after `MAX_POLLS`. Current defaults are ten
seconds for operation records and twenty seconds while waiting for a reload.
The limit allows roughly 30 minutes for staging and 60 minutes for installation.

Current estimates are based on a c8000v and a roughly 1 GB image:

| Work | Estimate |
|---|---|
| transfer | 150 seconds |
| install and reload | 390 seconds |

The adapter does not retry and does not send an abort when polling expires.

## 6. IOS XE constraints

These behaviors were observed on c8000v releases in the 17.11 to 17.18 range and
are reflected in the adapter and mock.

- Install RPCs return `<ok/>` within a second and continue working for minutes.
- The device pulls the image and therefore needs network reachability to the
  image server.
- Progress is reported in active and historical operation records keyed by a
  caller-supplied UUID.
- The NETCONF session drops during installation. Several reconnect attempts can
  occur before reads work again.
- Port 830 can accept TCP before the NETCONF server sends a hello. A failed read
  during reload is not a final result.
- The running banner, installed inventory, requested release, and image filename
  can use different spellings for the same release.
- Adding a large image can exhaust memory and reload the device before
  activation. Treat the add as impacting even though it often completes without
  disruption.
- `install-op-marked-succ` reports a no-op as successful.
- Operation history is bounded. The adapter must not depend on old records
  remaining indefinitely.

The running release comes from:

```text
Cisco-IOS-XE-device-hardware-oper:
  device-hardware-data/device-hardware/device-system-data/software-version
```

The leaf contains a banner such as:

```text
Cisco IOS XE Software, Version 17.18.02
```

The adapter extracts the value after `Version` and compares it by component.

The pruned YANG in `src/adapters/software_iosxe_yang.act` contains only the RPCs
and operational nodes used by the current adapter. Enumerations read from the
device are modeled as strings so a new value does not make the whole reply fail
to parse. The generated bindings are in
`src/adapters/software_iosxe_rpc.act`.

When adding another IOS XE operation, check its current schema with
`get-schema`. A pruned local module can have the same revision as the complete
module and is not evidence that an omitted node or RPC does not exist.

## 7. Testing

`IosXeSoftwareMock` runs behind `NetconfMockServer`, not behind a stubbed adapter.
Tests exercise NETCONF framing, XML encoding and decoding, RPC validation,
schema-driven parsing, operational reads, and RPC errors.

The mock keeps the running release, staged image, and operation history. It
replies to an RPC before changing operational state, so an adapter that treats
`<ok/>` as completion fails the tests. State changes are published through the
mock operational datastore and observed by later `get` calls.

Current coverage includes:

- version parsing and zero-padding comparison;
- image filename and RPC input construction;
- credential redaction in the adapter's own log message;
- record aggregation across UUIDs and multiple stages;
- preservation of multiple keyless history records by the current filter;
- a complete `xcopy` then `install` run through `DeviceMgr` and
  `SoftwareManager`;
- no RPCs when the device already runs an equivalent release;
- proof that RPC acceptance is not completion;
- propagation of a device-side RPC refusal to manager status `failed`;
- publication of software status and running release as operational data.

The mock does not reproduce memory pressure, SSH and NETCONF startup timing,
vendor bugs, or all RPC error details. Run at least one real upgrade with the
exact image, IOS XE release, and transport intended for deployment.

The hardware acceptance check is:

1. A device already on the target receives no install RPC and reports
   `up-to-date`.
2. A device on the previous release receives exactly `xcopy` then `install`.
3. The image URL and both destination path forms are correct.
4. The RPC replies arrive before completion and polling observes both stages.
5. The device returns on the requested release and the manager reports
   `succeeded`.
6. The device module set is resynced after reload.

Images remain outside git. Test environments should resolve device and image
server addresses at run time rather than storing deployment-specific addresses
in the repository.

## 8. Work still needed

### 8.1 Safe intent and retries

Run status is not durable, restored intent can start work after restart, and a
later device-meta write can retry a failed run. Define which configuration
change authorizes a new attempt, persist enough attempt state to survive a
restart, and fence late callbacks from older attempts.

The manager also needs a deadline around adapter jobs. The IOS XE driver has a
poll limit, but the manager can still remain busy forever if an adapter never
calls back. If the manager abandons a job, the adapter needs a way to clear its
local state without implying that it aborted the device operation.

### 8.2 Staging and maintenance windows

Implement `allow-staging` so image transfer can run before the maintenance
window while vetoes continue to block the impacting step. Re-check the veto
immediately before activation.

`install` must verify that the image staged by an earlier `prepare` still exists
and repeat preparation if necessary. The current IOS XE implementation assumes
the immediately preceding `xcopy` is still valid.

### 8.3 Checks, commit, and rollback

Implement the registered pre-check and post-check callbacks. Each check needs a
deadline, late-reply fencing, and evidence from a device read performed after
the check started.

The safer IOS XE workflow is:

```text
xcopy -> install without one-shot -> activate uncommitted
                                      |
                       post-check pass -> install-commit
                       post-check fail -> abort or auto-abort
```

This keeps an IOS XE auto-abort timer active while post-checks run. It requires
a `commit` job in `SoftwareAdapter` and in operational state; the current API has
neither. The manager also needs to know whether a platform supports rollback so
it does not report recovery that the adapter cannot provide.

Explore IOS XE `abort`, `remove`, and rollback behavior before implementing
automatic recovery or cleanup. Until cleanup is implemented, keep the previous
image for manual recovery.

### 8.4 Operational detail

Populate the modeled `job`, `precheck`, and `postcheck` nodes. Decide whether
check results are aggregate or keyed by registrant. Make `update_oper` notify
northbound subscribers as well as serving current values to reads.

Handle `op-done=op-reverted` as terminal and report why the operation reverted.

### 8.5 Credentials and verification

Replace credential-bearing `image-url` values with a URL plus a credential
reference resolved at transfer time, or define another secret-handling model.
Redact device configuration and RPC input in generic logging paths, not only the
adapter's own messages.

The IOS XE `image-files/sha1sum` value observed during testing did not match the
file's SHA-1. Determine what the device computes and add a reliable staged-image
integrity check. File presence and successful add are not a substitute for
checksum verification.

### 8.6 Broader support

Validate the adapter interface with a second platform. Decide whether release
state remains monolithic or needs per-component versions. Fleet campaign order,
parallelism, bandwidth limits, and window capacity belong above the per-device
manager.

## 9. References

- `src/device.act` — `SoftwareAdapter`, `SoftwareManager`, and operational-state
  publication through `DeviceMgr`.
- `src/swyang.act` — software configuration and state model.
- `src/adapters/software_iosxe.act` — IOS XE adapter and driver.
- `src/adapters/software_iosxe_yang.act` — pruned IOS XE schema used by the
  adapter.
- `src/adapters/software_iosxe_rpc.act` — generated typed RPC bindings.
- `src/adapters/software_iosxe_oper.act` — generated operational-data bindings
  and filter paths.
- `src/adapters/test_software_iosxe.act` — IOS XE NETCONF mock and adapter tests.
- `src/test_swmgr.act` — platform-neutral manager tests.
- `src/test_ttt_oper_read.act` — operational-state publication test.
- Cisco C8000V upgrade guide, "Upgrading IOS XE Software":
  <https://www.cisco.com/c/en/us/td/docs/routers/C8000V/Configuration/c8000v-installation-configuration-guide/upgrade-the-cisco-ios-xe-software/upgrading-ios-xe-software.html>
