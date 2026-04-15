# Subscriptions

Subscriptions are declared as a `set[yang.gdata.SubscriptionSpec]` and
reconciled by `yang.gdata.SubscriptionManager`.

`SubscriptionManager` is the owner-scoped declarative API. It binds:

- one `TreeProvider`
- one stable owner id
- one update callback

The callback receives one merged gdata tree for that owner.

The public shape is intentionally small:

```acton
subs = yang.gdata.SubscriptionManager(
    dev.tree_provider(),
    "base-config",
    on_state,
)

want = set([
    yang.gdata.SubscriptionSpec(_system_state_filter(), period=0.05)
])

subs.declare(want)
```

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

`SubscriptionManager` is the declarative owner-facing API. Internally,
StratoWeave splits subscriptions into two layers:

- `SubscriptionOwner`: one logical subscriber with one callback and one
  desired `set[SubscriptionSpec]`
- `SharedSubscription`: one physical device subscription keyed by the
  canonical `SubscriptionSpec` and shared by one or more owners

This means two transforms can declare the same `SubscriptionSpec` and
the device layer will only keep one physical poll running. Each
`SharedSubscription` tracks its current `latest` subtree and the set of
owner ids that depend on it.

Each `declare(...)` call is treated as the owner's complete desired
state. The device layer diffs the previous and new sets, removes dropped
specs from the owner's membership, creates newly needed shared
subscriptions, and reuses unchanged ones. The owner does not manage
handles or explicit cancellation.

## Merged Tree Delivery

The owner callback receives one merged operational tree rather than one
callback per subscription. Internally, `_merge_subscription_tree(...)`
walks the owner's desired `SubscriptionSpec` set, looks up the latest
subtree for each active shared subscription, and patches those subtrees
together into one gdata tree.

The merge order is made deterministic by sorting the owner's spec set
before merging. This avoids depending on set iteration order when
combining overlapping subtrees.

Today the merge starts from an empty `Container({})` and repeatedly
applies `yang.gdata.patch(...)` for each available subtree. There is a
TODO in `yang.gdata.patch(...)` to accept `None` as the empty base so
callers do not need to synthesize that root container.

## Change Detection And Snapshots

After building the merged tree, the device layer compares it to the
owner's previously delivered merged tree. If the merged tree changed, or
if an error is being reported, the callback is invoked.

The cached previous tree is currently stored as a detached snapshot, not
as a direct reference to the last merged tree. The reason is that
`yang.gdata.Node` is not yet a truly immutable persistent tree. Patch
and merge operations can still reuse mutable internals, so retaining an
older tree by reference is not a safe snapshot boundary.

The current workaround is to snapshot the merged tree before caching it.
That is intentionally conservative. The longer-term fix is to make
`yang.gdata.Node` properly immutable, likely with Merkle-style structure
sharing and cheap change detection, so this extra snapshot can go away.
