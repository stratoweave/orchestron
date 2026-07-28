# YANG to Acton compilation

The YANG to Acton compilation phase turns a StratoWeave system specification
and its YANG models into the Acton modules used by transform code and the
runtime. Run it after changing the system specification, a YANG model, a device
type, or a device schema filter:

```bash title="Compile YANG to Acton"
make gen
```

The project's generator entry point, for example `spec/src/sorespo_gen.act`,
loads the YANG models for each transform layer and device type, compiles the
system specification, applies any schema filters, and calls `gen_app(...)`.
Generated files are written below the project's source package. They should not
be edited by hand.

## Transform layer modules

Each transform layer produces five modules in `src/<project>/layers/`. The
number in the module name is the layer's position in the system specification,
starting with layer 0 at the top of the transform stack.

| Module | Purpose |
| --- | --- |
| `y_<N>.act` | Strict typed classes for transform input. Mandatory leaves and leaves with defaults are available as non-optional values. |
| `y_<N>_loose.act` | Loose typed classes for transform output. All fields except list keys are optional, so a transform can emit only the values it intends to change. |
| `y_<N>_oper.act` | Loose typed classes that include config-false state and generated subscription paths for the layer. |
| `base_<N>.act` | Base classes implemented by transforms, together with helpers such as `o_root()` for creating output for the next layer. |
| `t_<N>.act` | Runtime glue that connects transform implementations, target links, and the transform tree. |

Transform implementations normally import `base_<N>` and subclass one of its
generated base classes. The strict and loose `y_` types are then encountered
through the transform input and output objects. The `t_<N>` module is an
implementation detail of the generated application and does not normally need
to be imported directly.

For example, a mandatory `asn` leaf has different types in the input and output
modules:

```acton
# y_0: transform input
asn: u64

# y_0_loose: transform output
asn: ?u64
```

The loose output is intentional. Transform output is partial and is merged
with output from other transforms further down the stack.

## Device modules

Each device type produces three modules in `src/<project>/devices/`:

| Module | Purpose |
| --- | --- |
| `<device>.act` | Typed, config-true device classes used to construct configuration, for example with `root()`, `create(...)`, and `to_gdata()`. |
| `<device>_oper.act` | Typed operational view that includes config-false state and generated subscription paths. |
| `<device>_schema.act` | The compiled YANG schema represented as Acton data. The config module imports it, and the runtime uses it when validating and serializing data. |

The schema module is not a backup copy of the generated API. Separating the
large schema data from the typed config classes keeps the generated modules
manageable while preserving the schema needed at runtime.

The operational module is used when reading state or declaring telemetry
subscriptions. See [Subscriptions](subscriptions.md) for the generated
subscription API.

## Application wiring

Compilation also creates the modules that assemble the application. The
generated `sysspec.act` imports each layer and device module, builds the layer
stack, and registers the config and operational schemas for every device type.
The generated `device_types.act` provides the device type registry. Unlike the
other generated files, it is only created when missing so a project can extend
the registry with device types supplied by other packages.
