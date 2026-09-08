# fleetmgr — layered fleet management

`fleetmgr` is the top of the layered deployment. It owns the complete
per-device inventory and generic software upgrade campaigns, and assigns each
device to a manually named shard.

`flotilla` is the bottom. It has no application CFS layer: its northbound is
the standard StratoWeave RFS, and every `/device` entry is managed directly as
an IOS XE device.

    fleetmgr CFS /fleet/device{cpe, shard=flotilla-1, type=iosxe}
        -> fleetmgr RFS /rfs{flotilla-1}/device{cpe}
        -> NETCONF -> flotilla RFS /device{cpe}
        -> IOS XE adapter -> physical or mock IOS XE device

    flotilla operational datastore
        -> one periodic /device/software/state subscription per flotilla
        -> fleetmgr RFS /rfs{flotilla-1}/flotilla-status
        -> fleetmgr CFS /software/upgrade-campaign/state

There is no range expansion. A flotilla assigned 500 devices receives 500
complete `/device` entries, including addresses, credentials, SSH options, policy,
mock and debug settings, feature flags, and software intent.

## Build and regenerate

    just gen
    just build

Set `ACTON=/path/to/acton` when the compiler is not on `PATH`. Regeneration
produces both generated system-spec packages from `spec/`; the build produces
both binaries.

## Ten-flotilla subprocess demo

Start the top:

    just demo

The top starts ten `flotilla` subprocesses and waits for every NETCONF listener
before starting its own runtime. The demo declares `flotilla-1` through
`flotilla-10` and assigns two complete mock IOS XE entries to each. The
processes use these ports:

    process          HTTP          NETCONF
    fleetmgr         18200         12900
    flotilla-1..10   18201..18210  12901..12910

For bottom-node development, `just flotilla` still starts one standalone
instance on the first flotilla's ports. Do not run it alongside `just demo`.

Inspect the top CFS and the bottom RFS independently:

    curl -H "Accept: application/yang-data+json" \
      http://127.0.0.1:18200/restconf/data

    curl -H "Accept: application/yang-data+json" \
      http://127.0.0.1:18201/restconf/data

The second response should contain the two `stratoweave-rfs:device` entries
assigned to `flotilla-1` and rendered by the top.

Run the two-device IOS XE campaign and follow its state from the top:

    just upgrade-and-watch

The watcher starts before the intent is submitted, so it catches the mock's
short `in-progress` state and stops when both devices have either succeeded or
failed. `running_release` changes from `17.18.02` to `17.18.3a` on success.

The submission and observation steps are also available separately:

    just watch-campaign       # run first in one terminal
    just upgrade              # submit upgrade.xml from another terminal
    just campaign-status      # print one current snapshot

Set `FLEETMGR_API` to point these targets at a top node on another address.

## Models and transforms

The `fleetmgr` CFS has two inventory lists:

- `/fleet/node`: connection configuration for a flotilla. Its transform creates
  the top's managed `/device` entry with device type `flotilla` and enables its
  operational collector.
- `/fleet/device`: complete device configuration plus a string `shard` and an
  explicit device `type`. Its
  transform writes the entry under `/rfs{shard}/device`.

Both lists expose an `ssh` container using the shared
`stratoweave-ssh:ssh-client-config` grouping. Set SSH client options under
`/fleet/device/ssh` to pass them through to the device's owning flotilla, or
under `/fleet/node/ssh` to configure the top's connection to that flotilla.
Algorithm preference order is preserved through both transforms.

The generic `software` model remains separate from inventory. Each campaign
device list entry links its name to the referenced `/fleet/device` entry,
resolving each member's shard before merging all software intent into the same
RFS device entry.

The RFS transform renders that entry directly into the flotilla's standard
`/device` schema. A second RFS transform maintains one periodic subtree-filtered
subscription to `/device/software/state` on each flotilla. It normalizes that
state locally; campaign transforms then select and aggregate only their own
members. This avoids both full-datastore pushes and one southbound subscription
per device or campaign.

`flotilla` supplies only one modeled layer, the standard RFS. StratoWeave adds
the implicit device layer beneath it.

## Tests

    just test

The focused tests cover node creation, per-device sharding, precise campaign
links, campaign aggregation, the parent RFS-to-flotilla render, direct
`/device` configuration at the RFS-only bottom, and a complete mock IOS XE
software upgrade. The root tests also cover IOS XE adapter behavior and ensure
that a software-intent change preserves the existing NETCONF adapter and
session.
