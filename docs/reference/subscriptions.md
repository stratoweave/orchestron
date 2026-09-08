# Subscriptions

Subscriptions are declared as a `set[yang.gdata.SubscriptionSpec]` and
reconciled by `yang.gdata.SubscriptionManager`.

`SubscriptionManager` is the owner-scoped declarative API. It binds:

- one `TreeProvider`
- one stable owner id
- one update callback

The callback receives one merged gdata tree for that owner or, for a
destination rooted at a node, one instance of that node per call.

The public shape is intentionally small:

```acton
import yang.gdata as gdata
import mini.devices.ietf_oper as ietf_oper

subs = gdata.SubscriptionManager(
    dev.tree_provider(),
    "base-config",
    on_state,
)

want = set([
    ietf_oper.subs.system_state.clock.subscribe(depth=1, period=0.05)
])

subs.declare(want)
```

## Generated Subscription Helpers

Generated operational device modules such as `mini.devices.ietf_oper`
also expose a typed path API for building subscription filters. The
generated `_oper` module combines the config-false operational adata
tree with the `SubscriptionNode` helpers used for subscriptions.

Start from the generated root:

```acton
import mini.devices.ietf_oper as ietf_oper

sub = ietf_oper.subs
```

The generated module builds one shared filter path tree as the
`subs` module constant, rather than constructing a fresh helper tree
for each use.

### Subscribe To A Whole Subtree

Call `subscribe(...)` directly on a path to subscribe to everything
below that node:

```acton
# /system-state/clock
spec = sub.system_state.clock.subscribe(period=0.05)
```

### Subscribe To Direct Children Only

Use `depth=1` when you want the direct children of a container or list
entry, rather than the whole subtree:

```acton
# /system-state/clock/current-datetime
# /system-state/clock/boot-datetime
spec = sub.system_state.clock.subscribe(depth=1, period=0.05)
```

`depth` currently only supports `1`.

### Subscribe To One Keyed List Entry

Use `entry(...)` on generated list paths to add key predicates without
writing `FNode` filters manually:

```acton
iface = sub.interfaces.interface.entry("eth0")

# /interfaces/interface[name="eth0"]
spec = iface.subscribe(period=1.0)
```

### Select Specific Children

Use `select=[...]` to keep the list entry or container as the anchor,
but only subscribe to specific descendants below it:

```acton
iface = sub.interfaces.interface.entry("eth0")

spec = iface.subscribe(
    select=[iface.statistics, iface.ipv4],
    period=1.0,
)
```

Every selected path must be below the anchor used for `subscribe(...)`.

### Merge Overlapping Descendants

Selected descendants from the same subtree are merged into one filter:

```acton
iface = sub.interfaces.interface.entry("eth0")

spec = iface.subscribe(
    select=[
        iface.statistics.in_octets,
        iface.statistics.out_octets,
    ],
    period=1.0,
)
```

This produces one `statistics` branch with both leaves below it.

### Inspect The Raw Filter

Use `filt()` when you want the raw `FNode` without immediately wrapping
it in a `SubscriptionSpec`:

```acton
clock_filt = sub.system_state.clock.filt()
spec = gdata.SubscriptionSpec(clock_filt, period=0.05)
```

This is useful in tests and when integrating with older code that still
constructs `SubscriptionSpec` directly.

### Declare Multiple Filters For One Owner

`SubscriptionManager` still works on a set of `SubscriptionSpec`
objects, so you can mix several generated filters in one declaration:

```acton
iface = sub.interfaces.interface.entry("eth0")

want = set([
    sub.system_state.clock.subscribe(depth=1, period=0.05),
    iface.subscribe(select=[iface.statistics, iface.ipv4], period=1.0),
])

subs.declare(want)
```

### Where A Destination Is Rooted

A destination decides where each delivered tree starts. The module-level
`dst` is rooted at the top: the callback receives the whole subscribed
tree, as above. Every generated container and keyed list has a `dst` of
its own, rooted at that node: the callback receives one instance of the
node at a time. Its arguments are the keys of every list on the way
down, as a named tuple with a field per key named after the list and
the key; the instance itself, typed, or `None` when it is gone; and an
error, as on the top-rooted callback. A node with no list above it has
no keys argument. The types come with the `dst`, so the callback needs
no annotations.

```acton
import mini.layers.y_1_oper as y1_oper

def on_device(keys, device, err):
    if err is not None:
        ...
    elif keys is not None:
        if device is None:
            forget(keys.device_name)    # the device is gone
        else:
            record(keys.device_name, device)

def on_synced():
    ...                             # every device held at declaration has been delivered

dev = y1_oper.subs.device
subs.declare({
    dev.dst(on_device).deliver({
        dev.subscribe(period=1.0),
    }),
}, synced=on_synced)
```

Rooted below another list, the keys tuple carries that list's keys too:
a destination at `devices.device.interfaces.interface` hands its
callback `keys.device_name`, `keys.interface_name` and the interface.

The first pass delivers every instance the filter selects, one call each,
and then calls `synced`. After that each read delivers the instances that
changed since the last one, whatever the size of the list, so a
subscriber to a hundred thousand devices is called with one device. The
filters handed to a rooted destination must lead to its node, and they
are read on one period. A destination rooted at a container receives
that container, or `None` when it is gone.

`synced` belongs to the declaration, not to one destination: it is
called once, when every delivery in that `declare` has had its first
pass, the first read of each spec. A first read that ends in an error
still counts: the error, then `synced`. A declaration that adds nothing
new installs the new callbacks and nothing more: nothing is delivered
again and `synced` fires at once, since there is nothing to wait for. A
rooted destination is served by a TTT layer; a device provider answers it
with an error, and counts its first read as its first pass.

At the gdata level the root is an `FNode` path with one child per level
and no predicates, carried by `Dst(deliver, root=...)`; the destination
stamps it on the specs it delivers, so two destinations with the same
filters but different roots are served apart. A rooted delivery is a
spine: a tree from the top down to the one instance, every list on the
way holding one entry with its keys, with an `Absent` holding its keys
where a list entry is gone and nothing where a container is gone.
`gdata.instances` splits a tree into such spines and `gdata.gone` turns
one into the report of its instance gone. A generated `dst` wraps the
callback in a lambda that converts the spine to the keys and the
instance first; the provider calls it, so the conversion runs in the
provider and no actor stands between provider and consumer. After an owner's first pass the provider
calls `synced` with the owner id, sent after the data so it arrives after
it; the manager counts those for the declaration.

### On-Change Subscriptions

Omitting `period` creates an on-change `SubscriptionSpec`:

```acton
spec = sub.system_state.clock.subscribe(depth=1)
```

The generated filter helper supports this directly. The current
`NetconfDriver` limitation still applies, so on-change subscriptions are
not yet accepted there.

## `SubscriptionSpec`

`SubscriptionSpec` contains:

- `filt: ?FNode`
- `period: ?u64`

There is no explicit subscription mode. The behavior is inferred from
`period`:

- `period is None`: on-change subscription
- `period is not None`: periodic subscription

Internally, `period` is normalized to nanoseconds and stored as `?u64`. gNMI
uses nanoseconds, so we can express that granularity natively.

## Accepted `period` input

The constructor accepts:

- `float`: interpreted as seconds
- `u64`: interpreted as nanoseconds
- `int`: interpreted as nanoseconds
- `None`

Any other type raises `ValueError`.

Examples:

```acton
# Periodic, 50 ms
yang.gdata.SubscriptionSpec(filt, period=0.05)

# Periodic, 50,000,000 ns
yang.gdata.SubscriptionSpec(filt, period=u64(50000000))
yang.gdata.SubscriptionSpec(filt, period=50000000)

# On-change
yang.gdata.SubscriptionSpec(filt)
```

The recommended style is to use `float` seconds for readability unless
you specifically want to work in raw nanoseconds.

## Declaration Model

`SubscriptionManager` owns one logical subscriber. Each `declare(...)`
call describes the full desired subscription set for that owner.

- unchanged declarations are a no-op
- removed subscriptions are removed automatically
- added subscriptions are created automatically

The update callback receives one merged gdata tree for the owner, not
one callback per subscription.

## Current NETCONF Limitation

The current `NetconfDriver` only implements periodic subscriptions by
issuing periodic `<get>` operations. On-change subscriptions are not yet
implemented there, so a `SubscriptionSpec` with `period=None` will be
rejected by that driver.

## Internal Model

`SubscriptionManager` is the declarative owner-facing API. Below it, a TTT
layer serves each consumer from a `Subscription` actor of the consumer's
own, outside the Layer actor. The consumer's filters fold into one read
per period: the union of the filters declared with that period, read in
one pass. Each read runs on its period, and every delivery is the reads'
latest trees merged into one view, sent straight to the consumer, by
reference when there is one read. The Layer keeps only which actor serves
which consumer.

Each `declare(...)` call is the consumer's complete desired state. The
actor drops the reads no longer wanted, starts changed ones over, keeps
the rest with their latest trees, and calls `synced` once every read of
the declaration has run.

A consumer rooted at a node has one read, and instead of one view gets,
after each read, every instance that differs from the last read and
every instance gone, each as a tree from the top down to that one
instance.
