# System specification

In a StratoWeave project, the **system specification** defines how many
layers the system has, their order, and what the schemas is for each layer.

The system specification definition for SORESPO looks as follows:
```acton title="spec/src/sorespo_gen.act"
spec = stratoweave.build.SysSpec("sorespo", [cfs_layer, inter_layer, rfs_layer], [
    stratoweave.build.DeviceType.from_dir(fc, "CiscoIosXr_25_3_1", "yang/CiscoIosXr_25_3_1"),
    stratoweave.build.DeviceType.from_dir(fc, "JuniperCRPD_24_4R1_9", "yang/JuniperCRPD_24_4R1_9"),
    stratoweave.build.DeviceType.from_dir(fc, "NokiaSRLinux_25_3_2", "yang/NokiaSRLinux_25_3_2"),
])
```

The resulting SORESPO system has 4 layers:

1. **Layer 0**: customer-facing service intent
2. **Layer 1**: intermediate service decomposition
3. **Layer 2**: resource-facing services
4. **Layer 3**: device configuration

The `#!acton SysSpec` takes 3 arguments:

* The system name
* A list of [transform layers](#transform-layers) in the system, in descending order of abstraction
    * A StratoWeave system must have at least one layer, but can have
    as many as are needed to cleanly separate different levels of abstraction
    in the transform stack.
    * The top-most layer is the **customer-facing service (CFS)** layer, which
    defines the schema that users will interact with over the northbound APIs
    (e.g. NETCONF, RESTCONF, or TMF APIs).
    * The bottom-most layer is the **resource-facing service (RFS)** layer.
    Transforms at this layer are tied to a specific device entry. This
    layer is also responsible for maintaining the list of managed devices.
* A list of [device types](#device-layer-and-device-types) that can appear in the device layer.

## Transform layers
Each layer is an instance of the `#!acton Layer` class.

In SORESPO, the layer definitions look like this:
```acton title="spec/src/sorespo_gen.act"
cfs_layer = stratoweave.build.Layer.from_dir(fc, "yang/cfs")
cfs_layer.models.extend([
    swyang.stratoweave,
    swyang.ietf_inet_types,
    tmf.yang.ietf_yang_tmf_map,
    tmf.yang.swtmf.replace("TMF640_STORE_TRANSFORM", "sorespo.tmf.Tmf640Store"),
    tmf.yang.swtmf640
])
inter_layer = stratoweave.build.Layer.from_dir(fc, "yang/inter")
inter_layer.models.extend([swyang.stratoweave, swyang.ietf_inet_types])
rfs_layer = stratoweave.build.Layer.from_dir(fc, "yang/rfs")
rfs_layer.models.extend([swyang.stratoweave, swyang.rfs, swyang.ssh,
                         swyang.ietf_inet_types, swyang.ietf_yang_types])
```

Each of these layers is built from a directory of YANG models, which define
the schema for that layer. The `models.extend(...)` calls add extra YANG
modules that are shipped with StratoWeave:

* `swyang.stratoweave` includes the core StratoWeave schema and transform
 definitions, such as `sw:transform` and `sw:rfs-transform`.
* `swyang.ietf_inet_types` includes common IETF-defined types.
* `swyang.rfs` includes the StratoWeave-specific RFS schema, that is used in
 the RFS layer.
* `swyang.ssh` provides reusable SSH client types and the `ssh-client-config`
 grouping used by the RFS device model and application inventory models.
* `swyang.ietf_yang_types` supplies the date and time types used by RFS.
* `tmf.yang.ietf_yang_tmf_map` includes the TMF mapping schema, which is used
 to annotate YANG with TMF Service/Resource mapping instructions.
* `tmf.yang.swtmf` and `tmf.yang.swtmf640` include the TMF640 store transform
 and related schema, which are used to store TMF metadata in the system.

## Device layer and device types
The device layer contains a list of device types that the system can manage.

StratoWeave is designed to support various device types but at present,
SORESPO only contains NETCONF/YANG-based device types. Each YANG-based device
type is built from a directory of YANG models.

### Schema transforms
Router vendors have made great efforts to model their entire devices with YANG,
every knob and feature is configurable and observable through YANG. As a result,
the full set of YANG models for some of these operating systems are several
hundred megabytes and include tens of thousands of nodes. To have access to
completely typed device models, StratoWeave transpiles the YANG to Acton types.

At present, this means that the full device models are too large to transpile
and subsequently compile in a reasonable time. The current recommendation for
developers is to prune the device models down to a manageable size by only
including the YANG nodes that you require for configuration and telemetry in
your use cases.

Pruning is only one of the schema transforms that can be applied to the device
schema, but it is arguably the most common. Transforms are listed on the device
type and applied to the compiled schema tree in the order given.

```acton title="spec/src/sorespo_gen.act"
import stratoweave.device_schema as swds

spec = stratoweave.build.SysSpec("sorespo", [cfs_layer, inter_layer, rfs_layer], [
    stratoweave.build.DeviceType.from_dir(fc, "CiscoIosXr_25_3_1", "yang/CiscoIosXr_25_3_1",
        transforms=[
            swds.filter_schema(xr_paths),
        ]),
    stratoweave.build.DeviceType.from_dir(fc, "JuniperCRPD_24_4R1_9", "yang/JuniperCRPD_24_4R1_9",
        transforms=[
            swds.filter_schema(crpd_paths),
            swds.remove_list_user_order(crpd_order_paths),
        ]),
    stratoweave.build.DeviceType.from_dir(fc, "NokiaSRLinux_25_3_2", "yang/NokiaSRLinux_25_3_2",
        transforms=[
            swds.filter_schema(srl_paths),
        ]),
])
compiled_spec = spec.compile(broken_leafrefs)
compiled_spec.gen_app(fc, "../src/")
```

The available transforms come from `stratoweave.device_schema`:

* `filter_schema(paths)` prunes the tree down to the listed YANG paths. A node
  is kept when its path is listed or when it is an ancestor of a listed path,
  so list keys have to be listed explicitly.
* `remove_list_user_order(paths)` rewrites `ordered-by user` (leaf-)lists to
  `ordered-by system`. JUNOS uses `ordered-by user` in many places where the
  order has no effect on the applied configuration, which otherwise shows up as
  spurious reordering whenever a transform writes the elements in a different
  order.

In SORESPO, all three device types are pruned this way, each with a list of the
YANG paths to retain.
```acton title="spec/src/sorespo_gen.act"
# Keep only the XR nodes that sorespo actively uses.
xr_paths = [
"/um-hostname-cfg:hostname",
"/um-hostname-cfg:hostname/system-network-name",
"/um-interface-cfg:interfaces",
"/um-interface-cfg:interfaces/interface",
"/um-interface-cfg:interfaces/interface/interface-name",
"/um-interface-cfg:interfaces/interface/description",
"/um-interface-cfg:interfaces/interface/shutdown",
...
```

!!! info "Compiler performance improvements"
    The platform core developers are actively working on improving the
    performance of the YANG transpilation and compilation process. We are
    combining several strategies to achieve this, including generating total
    types during the YANG to Acton transpilation, improving the efficiency of
    the Acton compiler, and support for shipping binary type libraries that
    can be imported directly without needing to compile the device types
    locally.

    The goal of these improvements is to allow for the use of full device
    models without pruning, while still maintaining a fast development
    workflow.

## Defining transforms
For a StratoWeave system to store and act on data at each layer, the system
specification must include transform definitions. Create a transform by
annotating a list or container in any transform layer's YANG with the
`#!yang sw:transform` statement from the StratoWeave YANG extensions.

```yang title="spec/yang/cfs/netinfra.yang" hl_lines="8"
...
container netinfra {
  description "Network infrastructure";
  list router {
    description "Network Infrastructure Router";
    key name;

    sw:transform sorespo.cfs.Router;
    tmf:cfs-service "Router";

    leaf name {
      type string;
    }
...
```

The value of the `sw:transform` annotation should be the import path to a class
containing a `transform()` method. See the [transforms](transforms.md) section
for more details on how to write the transform logic.

### Defining RFS transforms
The lowest transform layer in the system is the RFS layer, StratoWeave expects
this layer to be modeled according to the RFS YANG schema shippped with the
platform.
Augment the `#!yang sw-rfs:rfs` list from that schema to define the RFS layer
transforms for your system.
The RFS transforms also use a special annotation, `#!yang sw:rfs-transform`,
which is a variant of `#!yang sw:transform` that supplies the transform with
device information together with the input data.

```yang title="spec/yang/rfs/sorespo-rfs.yang" hl_lines="11"
module sorespo-rfs {
...
  augment "/sw-rfs:rfs" {
    container base-config {
     sw:rfs-transform sorespo.rfs.BaseConfig;

    leaf role {
      type string;
    }
...
```

### Using YANG augmentation
StratoWeave also supports using YANG augmentations to define transforms on
schema nodes that are defined in other modules. This is especially useful for
applying transforms to standard models that you do not want to edit directly,
such as published IETF modules.

```yang title="spec/yang/cfs/sorespo-ietf-l3vpn-svc.yang" hl_lines="11"
...
augment "/l3vpn-svc:l3vpn-svc/l3vpn-svc:vpn-services/l3vpn-svc:vpn-service" {
  sw:transform sorespo.cfs.L3VpnVpnService;
  tmf:cfs-service "L3VPN VPN Service";
}
...
```

The added benefit of using YANG augmentation for transform definitions on the
YANG modules in the CFS layer is that it allows you to keep the original YANG
module clean of any StratoWeave-specific annotations. This can be desirable when
a northbound NETCONF client downloads the YANG schemas from the system.

!!! info "The StratoWeave northbound NETCONF interface is not yet available."

## Defining TMF Service/Resource mappings
StratoWeave implements the YANG to TM Forum mapping defined in
[draft-lambrechts-onsen-yang-tmf-mapping-00](https://datatracker.ietf.org/doc/html/draft-lambrechts-onsen-yang-tmf-mapping-00).
To annotate your YANG models with TMF mapping instructions,
import the `ietf-yang-tmf-map` module from the StratoWeave YANG extensions
and use the `tmf:cfs-service` annotation to indicate which CFS service
each YANG node corresponds to.

```yang title="spec/yang/cfs/netinfra.yang" hl_lines="9"
...
container netinfra {
  description "Network infrastructure";
  list router {
    description "Network Infrastructure Router";
    key name;

    sw:transform sorespo.cfs.Router;
    tmf:cfs-service "Router";

    leaf name {
      type string;
    }
...
```

## Generating the system specification

Whenever you have modified the system specification definition,
either by changing the YANG models or the generator logic, execute the
`make gen` command to re-generate `sysspec.atd`, the layer modules, and device
types.
```sh
make gen
```

??? info "How system spec generation works"
    The `gen` Make target first builds the `spec/src/sorespo_gen.act` Acton
    program, then runs the resulting binary.
    ```sh
    cd spec && acton build $(DEP_OVERRIDES) && out/bin/sorespo_gen
    ```
