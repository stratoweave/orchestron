# Device management

StratoWeave keeps managed devices in the intent tree rather than in a separate
out-of-band inventory. The transform layer immediately above the RFS layer owns
that intent: it decides which devices exist, which generated device type each
device uses, how the orchestrator reaches it, and which RFS transforms should
be created for it.

## Build-time: device adapters come from the system spec

Each supported vendor OS version is declared as a separate device type in the
system specification. Every `DeviceType.from_dir(...)` call loads one specific
directory of YANG modules, and the generated application builds a typed device
adapter for that exact module set.

```acton title="spec/src/sorespo_gen.act"
spec = stratoweave.build.SysSpec("sorespo", [
		cfs_layer,
		rfs_layer,
], [
		stratoweave.build.DeviceType.from_dir(fc, "CiscoIosXr_25_3_1", "yang/CiscoIosXr_25_3_1"),
		stratoweave.build.DeviceType.from_dir(fc, "CiscoIosXr_25_4_1", "yang/CiscoIosXr_25_4_1"),
		stratoweave.build.DeviceType.from_dir(fc, "JuniperCRPD_24_4R1_9", "yang/JuniperCRPD_24_4R1_9"),
])

spec.gen_app(fc, "../src/")
```

When a vendor ships a new release with a different set of YANG modules or
revisions, add a new directory and a new `DeviceType.from_dir(...)` entry, and
rebuild the application. At runtime, the value written into `device.type` must
match one of these device type names exactly.

## Operations-time: device entries are part of intent

Operators do not create `DeviceMgr` instances directly. Instead, they submit
northbound intent, and the layer above RFS emits two related outputs for each
managed device:

- a `device` entry that selects the generated adapter and supplies connection
	details
- an `rfs` entry that carries the resource-facing service data for that same
	device

In a two-layer system this is the CFS transform. In a three-layer system it
would be the intermediate layer.

## Exposing device inputs on the northbound

If device address, credentials, or adapter selection should be operator
provided, those inputs must exist in the northbound YANG model.

```yang title="spec/yang/cfs/netinfra.yang"
...
	container netinfra {
		list router {
			key name;

			sw:transform sorespo.cfs.Router;

			leaf name {
				type string;
			}
			leaf device-type {
				type string;
			}
			leaf mgmt-address {
				type inet:host;
			}
			leaf device-username {
				type string;
			}
			leaf device-password {
				type string;
			}
		}
	}
```

If your northbound model exposes these leaves, operators can provide them in a
startup XML file or over a northbound API such as NETCONF:

```xml title="SORESPO-style northbound intent"
<netinfra xmlns="...">
	<router>
		<name>pe1</name>
		<device-type>CiscoIosXr_25_3_1</device-type>
		<mgmt-address>192.0.2.10</mgmt-address>
		<device-username>netops</device-username>
		<device-password>netops-password</device-password>
	</router>
</netinfra>
```

In other scenarios, the northbound model may not expose these leaves,
and the transform layer above RFS may instead look up the device type and
credentials from an internal database or a secrets manager. In that case,
the northbound intent would only need to provide e.g. the device name,
and the transform would fill in the rest.

## Creating device and RFS entries in the transform

The transform above RFS creates the device entry and the matching RFS subtree
together. The important pattern is:

```acton title="src/sorespo/cfs.act"
class Router(base.Router):
		def transform(self, i, linked, dynstate):
				o = base.o_root()

				dev = o.device.create(i.name)
				dev.type = i.device_type

				oob = dev.address.create("oob")
				oob.address = i.mgmt_address

				dev.credentials.username = i.device_username
				dev.credentials.password = i.device_password

				rfs = o.rfs.create(i.name)
				rfs.base_config.name = i.name

				return o
```

Here, `o.device.create(i.name)` adds the managed device entry consumed by the
generated device layer. `dev.type` selects one of the build-time device types,
for example `CiscoIosXr_25_3_1`. `o.rfs.create(i.name)` creates the RFS object
bound to that same device.

If credentials should not be operator supplied, keep them out of the
northbound YANG and set the same `dev.credentials` fields from an internal
lookup instead.

## SSH transport parameters

Every SSH-based adapter -- NETCONF over SSH today, CLI adapters later -- reads
its transport settings from the device's `ssh` container. Leave it out and the
SSH library's defaults apply; set it to deal with devices that need something
narrower or older.

To expose these settings in another model, import `stratoweave-ssh` and use
its `ssh-client-config` grouping inside an `ssh` container:

```yang
import stratoweave-ssh {
  prefix sw-ssh;
}

container ssh {
  uses sw-ssh:ssh-client-config;
}
```

Include `swyang.ssh` in the layer's models when generating the application,
and copy the settings to `dev.ssh` in its transform.

```acton title="src/sorespo/cfs.act"
dev.ssh.cipher = ["aes128-ctr"]
dev.ssh.key_exchange = ["diffie-hellman-group14-sha256"]
dev.ssh.host_key_algorithm = ["ssh-rsa"]
dev.ssh.minimum_rsa_bits = u64(1024)
```

The algorithm leaf-lists (`cipher`, `mac`, `key-exchange`,
`host-key-algorithm`, `public-key-algorithm`, `compression-algorithm`) are
ordered preference lists, most preferred first, and an empty one means "use the
library default". `host-key-algorithm` is what decides which host key type the
device presents. The remaining leaves are `compression-level` (1-9, default 7),
`rekey-after-bytes`, `rekey-after-seconds` and `minimum-rsa-bits`; absent
`rekey-after-bytes` uses the negotiated cipher's RFC 4344 volume limit, and
absent `rekey-after-seconds` disables time-based rekeying.

Changing the `ssh` container reconnects the device. An algorithm name the SSH
library does not support is rejected by the YANG enumeration; anything that
slips past is logged and leaves the device disconnected rather than retrying a
connection that can never come up.

The northbound NETCONF server has its own equivalent settings, configured as
system settings rather than as intent; see [Running StratoWeave](run.md).

## RFS models still define the service-specific southbound data

The built-in device list already comes from the StratoWeave RFS schema. Your
project-specific RFS YANG augments that schema with the service-specific nodes
that your RFS transforms need.

```yang title="spec/yang/rfs/sorespo-rfs.yang"
module sorespo-rfs {
	...
	augment "/sw-rfs:rfs" {
		container base-config {
			sw:rfs-transform sorespo.rfs.BaseConfig;

			leaf name {
				type string;
			}
		}
	}
}
```

In other words, the layer above RFS creates both the `device` entry and the
matching `rfs` subtree as part of the same overall intent. The generated device
layer then uses the `device` entry to select the correct per-version adapter
and reconcile the rendered configuration against the target device.

