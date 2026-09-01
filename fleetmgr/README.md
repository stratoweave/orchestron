# fleetmgr — layered fleet management

`fleetmgr` is the top of the layered deployment. It owns the complete
per-device inventory and generic software upgrade campaigns, and assigns each
device to a manually named shard.

`flotilla` is the bottom. It has no application CFS layer: its northbound is
the standard StratoWeave RFS, and every `/device` entry is managed directly as
a CPE.

    fleetmgr CFS /fleet/device{cpe, shard=flotilla-1}
        -> fleetmgr RFS /rfs{flotilla-1}/device{cpe}
        -> NETCONF
        -> flotilla RFS /device{cpe}
        -> physical CPE

There is no range expansion. A flotilla assigned 500 devices receives 500
complete `/device` entries, including addresses, credentials, policy, mock and
debug settings, feature flags, and software intent.

## Build and regenerate

    just gen
    just build

Set `ACTON=/path/to/acton` when the compiler is not on `PATH`. Regeneration
produces both generated system-spec packages from `spec/`; the build produces
both binaries.

## Manual two-process demo

Start the bottom first:

    just flotilla

Then start the top in another terminal:

    just demo

The demo declares `flotilla-1` at `127.0.0.1:12901` and assigns 20 complete
mock CPE entries to it. The processes use these ports:

    process    HTTP   NETCONF
    fleetmgr   18200  12900
    flotilla   18201  12901

Inspect the top CFS and the bottom RFS independently:

    curl -H "Accept: application/yang-data+json" \
      http://127.0.0.1:18200/restconf/data

    curl -H "Accept: application/yang-data+json" \
      http://127.0.0.1:18201/restconf/data

The second response should contain the 20 `stratoweave-rfs:device` entries
rendered by the top.

## Models and transforms

The `fleetmgr` CFS has two inventory lists:

- `/fleet/node`: connection configuration for a flotilla. Its transform creates
  the top's managed `/device` entry with device type `flotilla`.
- `/fleet/device`: complete CPE configuration plus a string `shard`. Its
  transform writes the entry under `/rfs{shard}/device`.

The generic `software` model remains separate from inventory. Its campaign
transform links to `/fleet/device` only to resolve each member's shard, then
merges software intent into the same RFS device entry.

The RFS transform renders that entry directly into the flotilla's standard
`/device` schema. Operational fan-in from the flotilla is deliberately left for
a later change; campaign members remain `pending` at the top for now.

`flotilla` supplies only one modeled layer, the standard RFS. StratoWeave adds
the implicit device layer beneath it.

## Tests

    just test

The focused tests cover node creation, per-device sharding, campaign routing,
the parent RFS-to-flotilla render, and direct `/device` configuration at the
RFS-only bottom.
