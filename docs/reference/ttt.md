# TTT — Transactional Transform Trees

Internal developer documentation for `src/ttt.act` (+ `ttt_links.act`, `ttt_gen.act`). Audience: platform engineers who read and modify the engine. The tests in `src/test_ttt_*.act` are the authoritative behavioral spec; when this doc and the code disagree, the code wins.

> **Baseline.** This describes `src/ttt.act` on `main` (`e0c905d`), whose module docstring is a condensed summary pointing here. **Symbol names are the authoritative anchors; inline line numbers are approximate aids that drift as the file is edited — search by symbol if a number is off.** The list multi-pass membership logic (§3/§4) reflects the `fix-list-state` change: `active[tid]` accumulates across passes and removal is driven by explicit `gdata.Absent`, not by omission.

---

## 1. Overview

TTT is the transaction engine of StratoWeave. It runs the transform functions that turn a higher service model into a lower one, manages the lifecycle of transforms (create / modify / remove), and — its defining feature — **cleans up downstream config automatically on removal, with no cleanup code**. The whole engine is ~2400 lines because it is built on Acton actors: concurrency is message-passing, not locks-and-shared-memory.

### The stack and the tree

Two orthogonal structures. **Layers** stack vertically (CFS → RFS → device); **Nodes** form the per-layer config tree.

```
 LAYER STACK (vertical)                  PER-LAYER NODE TREE (one Layer's root)
 ───────────────────────                 ──────────────────────────────────────
                                          Layer.root : Node (Container)
  Layer "cfs"  ── lower ──┐                  ├─ Node (Container)
   root: Node tree        │                  │    └─ Node (List)  ── ListState ──┐
   subs pool              │                  │           ├─ Node (elem, Container) │ per-key
       │                  ▼                  │           │     └─ Node (Transform) │ elem
       │            Layer "rfs" ── lower ─┐  │           └─ Node (elem, Container)  │ nodes
       │             root: Node tree      │  │                 └─ Node (Transform) ─┘
       │             subs pool            ▼  └─ Node (Transform)   <- emits diff into the
       │                           Layer "device" ── lower=None         lower Layer's session
       │                            root: Node tree (Sink/Device)
       ▼
  edit_config(diff) opens a Session chain mirroring the stack (one Session per Layer,
  sharing one tid and one swdb.Buffer). Config flows DOWN; completion flows UP.
```

- A **Layer** (`ttt.act:673`) owns exactly one long-lived root `Node` tree, built once at construction by `rootgen(PathRoot(name), lower)` (`674`). It also owns the persistence handle and the subscription pool. Layers chain via the `lower: ?Layer` ctor arg; the bottom layer's `lower` is `None`.
- A **Node** (`actor Node`, `ttt.act:551`) wraps a `_Node` impl: `_Container`, `_List` (+ its `ListState` actor and per-element nodes), or a transform leaf (`_TransformBase` / `_RFSTransform` / `_Device` / `_DeviceConfig`). The Node tree is **persistent** across edits.
- A **transform** is the leaf where a pure (or stateful) function runs. Each transform consumes its merged input config and emits a *downward diff* into the next-lower Layer's Session, building that layer's candidate under the same transaction.
- Edits never mutate the Node tree directly. Each edit spins up a parallel **Transaction** actor tree (via `newtrans()`) that stages a candidate and then promotes or discards it on commit.

### Plain transform vs RFS transform

Two transform flavors share the same transaction machinery but differ in what they model and in their function signature:

- A **plain transform** (`Transform`, `2035`; base `TransformFunction`, `2123`) maps a service model to a lower service model. Its function is `transform_wrapper(cfg, linked, memory, dynstate)` — the second arg is the **`linked`** tree assembled from cross-tree links (§7). It pushes its output diff into the lower Layer's Session.
- An **RFS transform** (`RFSTransform`, `2149`; base `RFSFunction`, `2296`) is the resource-facing tier: it maps the per-device resource model to device config. Its function is `transform_wrapper(cfg, device_info, memory, dynstate)` — the second arg is a **`DeviceInfo`** (`devname`, modset; `2288`, supplied at `2213`) rather than `linked`. It is wired to a `swdev.DeviceMgr` (via the `dev_registry` ctor arg) so its actor can drive the device. Consequently **`sw:link` is forbidden on RFS transforms** (codegen raises, `ttt_gen.act:130-131`): an RFS transform's second slot is `DeviceInfo`, not a `linked` tree, so there is nowhere for link data to land.

Both emit deltas downward the same way and participate identically in lock/commit/cleanup; the difference is the modeled second input and the device wiring.

---

## 2. The data model & monoidal composition

All configuration is `gdata.Node` trees. But at every transform / container / list transaction node, config is stored **per source** — `dict[str, gdata.Node]` keyed by the contributing source's identity — not as a single tree. The source key is either an upstream session source (`'_'` at the layer boundary) or a transform's own `self.me` tag.

### Why per-source

Multiple upstream services can contribute to the same downstream node. Keeping their contributions separable lets the engine **decompose** as cleanly as it composes: when one source changes or is removed, its slice is updated or dropped independently while the others persist untouched. This is the foundation of automatic cleanup (§5).

### The merge monoid

`merge(cfg_per_src)` (`ttt.act:128`) folds all per-source trees into one combined tree with `gdata.merge`, which recursively unions container/list children:

```
[src A tree]  [src B tree]  [src C tree]
      \            |            /
       └──── gdata.merge fold ──┘        acc = merge(acc, conf), dict-iteration order
                  │
            combined tree  ──► transform fn ──► newout
                                                  │
                          difference(old_output, newout) = delta
                                                  │
                              out.configure(tid, {self.me: delta})  ──► lower Session
```

The combined tree is the input to the transform function. The identity element is the empty `gdata.Container` (used wherever `running` is empty, e.g. `2007-2010`, `1872`).

**merge is a PARTIAL operation — not a total commutative monoid.** On *non-conflicting* trees it is commutative and associative with the empty Container as identity. But two sources writing **different scalar values (or different types) to the same leaf is a conflict**, and `gdata._merge_rec` raises `ValueError` (acton-yang `gdata.act:2102-2109`). There is **no last-writer-wins and no winner selection**. Equal values merge idempotently (the leaf case returns `a`). LeafLists union instead of raising (`gdata.act:2111-2121`), so the conflict rule is specific to scalar leaves.

A merge conflict surfaces as an exception caught in `configure` (`ttt.act:1810`): state is rolled back (`stage_db_state(..., clear=True)`) and `CfgError(e)` is returned, aborting the transaction. This is exactly what `config_failure` (`test_ttt_container.act:363-392`) exercises: a container with two PassThrough transform children (`q('left')`, `q('right')`); two transactions stage conflicting per-source contributions (t1=srcA, t2=srcB) into that same container subtree, so the second transaction's configure sees `_r.errors`, reconfigures with non-conflicting data, and only then commits. *Whether* the fold fails is order-independent; the error *message* (the reported path) is dict-iteration-order-dependent.

### The supporting helpers

| helper | sig | role |
|---|---|---|
| `merge` | `dict[str,Node] -> Node` (`128`) | fold per-source → combined (the monoid op; raises on conflict) |
| `patch` | `(dict[str,Node], dict[str,Node]) -> dict[str,Node]` (`114`) | apply a per-source diff onto running; `gdata.patch` per source; **drop a source when its patch yields `None`**; carry untouched sources through verbatim |
| `difference` | `(?Node, Node) -> ?Node` (`108`) | `gdata.diff(old,new)` if old exists, else the full `new`. **Asymmetric** — always `difference(old_output, new_output)` |
| `assert_complete` | `Node -> Node` (`125`) | **identity no-op today.** Named as a completeness/validity hook but enforces nothing. Do not assume merged trees are validated |
| `transpose_list` | `dict[src,Node] -> dict[key_str, dict[src,Node]]` (`75`) | pivot a per-source list diff to per-element-per-source |
| `transpose_container` | `dict[src,Node] -> dict[gdata.Id, dict[src,Node]]` (`92`) | pivot a per-source container diff to per-child-per-source |
| `prune` | `(Node, FNode) -> Node` (`140`) | restrict a tree to a filter subtree (empty Container if nothing remains); used to drop stale link contributions |
| `per_src` | diagnostic (`68`) | **debug pretty-printer only**; every call site is commented out. Despite the name it is unrelated to the per-source storage (which is the plain dict) |

### Transpose & the WILD buckets

`transpose_list`/`transpose_container` push per-source discipline one level down: a `dict[src → List/Container]` becomes a `dict[childkey → dict[src → childNode]]`, one per-source dict per child to recurse into. Removals carried as `gdata.Absent` collapse to a sentinel bucket on the side:

- list keys → `str` (`key_str`); container keys → `gdata.Id`. **Return-key types differ by design** (comment at `ttt.act:74`).
- `WILDKEY = ""` and `WILDID = gdata.Id("","")` (`71-72`) are sentinels for `Absent` sources, meaning "a remove for all existing children/keys." They **must be fanned out into every child and then deleted before recursing** (Container WILDID `del` at `1157`, List WILDKEY `del` at `1482`) or they leak as a fake child. (Note `1144-1145` is a *different* `del`: it drops diff children that match no embedded transform — key leaves, foreign nodes — before the WILDID handling.)

### The core configure cycle at a transform (`ttt.act:1774-1816`)

```
diffs[tid] accumulate   accdiff.update(diff.items())
        │
        ▼
newconf = patch(running, accdiff)      candidates[tid] = newconf
        │
   newconf == {} ?
     ├─ yes → essays[tid] = (None, None); clear(tid, out) emits remove diff downstream;
     │        unsubscribe all subscriptions; return CfgOk(empty=True)
     └─ no  → merged = assert_complete(merge(newconf))
              link_requests/link_updates; if no pending requests:
                 compute(tid, merged, linked, out)        # runs the transform fn
                 essays[tid] = (newout, newmemory)
              return CfgOk(requests, updates)
```

`compute` (`2070-2076`) runs `function.transform_wrapper(merged, linked, memory, dynstate)`, computes `res = difference(self.output, newout)`, and forwards it to the lower Session as a **single source keyed by `self.me`** (`out.configure(tid, {self.me: res})`). That keying preserves the per-source contract across the layer boundary: the downstream node sees this whole transform as exactly one source.

### Invariants

- **Per-source separability.** A node's config is the merge of independent per-source contributions; updating/removing one source never silently mutates another. `patch` carries untouched sources verbatim (`120-122`).
- **Empty per-source map (`newconf == {}`) is the fully-removed state** — triggers `clear()`, emits a remove diff downstream, and on commit nulls `oper` (`1954-1955`).
- **A source is dropped** exactly when `gdata.patch` of its accumulated diff yields `None` (`117-119`).
- **Removal is declarative and idempotent** via `gdata.Absent` — routed to WILD buckets in transpose, interpreted by patch/diff. Removing an absent target is not an error.
- **Transforms emit deltas, not restatements** — `difference` yields a minimal `gdata.diff` when prior output exists; only with no prior output is the full tree sent.

---

## 3. The actor topology

Two parallel actor trees: the **persistent Node tree** (committed state, lives across edits) and a **per-edit Transaction tree** (spun up by `newtrans()` when a transaction starts).

```
 OWNERSHIP                                                  message flow
 ─────────                                                  ────────────
 Layer (actor)                                              edit_config ─► Session
   owns ─► root: Node (actor) ──delegates──► _Node impl       configure/lock/commit
              │  newtrans()                                    fan DOWN the Transaction tree
              ▼                                                CfgResult aggregates UP
        Transaction (actor) ──delegates──► _Transaction impl
              │                                             Session (actor)  per Layer
   _Container ┤── child Node(s)  /  child Transaction(s)       root = rootnode.newtrans()
   _List      ┤── ListState (actor, SHARED by Node & Txn)      lower = lowerlayer.newsession()
   _Transform ┘── per-tid candidate engine                    (recurses the lower chain)
```

| actor / class | file:line | role |
|---|---|---|
| `Layer` | `673` | one stack tier; owns root Node, persistence, subscription pool |
| `Session` | `841` | one editing context over a Layer + recursive lower Session |
| `Node` / `_Node` | `551` / `579` | persistent tree node; wraps a `_Node` impl; `pub_impl` exposed for isinstance checks |
| `Transaction` / `_Transaction` | `592` / `639` | per-node mailbox; serializes configure/lock as async messages |
| `_Container` / `_ContainerTransaction` | `1053` / `1121` | static children keyed by `gdata.Id`; built eagerly from a template |
| `_List` / `_ListTransaction` | `1301` / `1439` | dynamic children keyed by compound key string |
| `ListState` (actor) | `1374` | shared list-membership manager; per-key element Nodes, active/provisional lifecycle |
| `_TransformTransactionBase` | `1722` | the per-tid candidate engine for one transform |

- A `Node` actor gives each tree node its own mailbox, so `configure`/`lock` run as serialized async messages per node. `get`/`get_data`/`bind_db`/`restore`/`is_empty` are delegated to the impl directly; `configure`/`lock`/`commit` go through the Transaction tree.
- `_Container.newtrans` builds a `ContainerTransaction` with one child Transaction per element. `_List.newtrans` builds a `ListTransaction` that **shares the same `ListState` actor** as the Node tree — entry lifecycle is centralized there, not duplicated per transaction.

### The ListState lifecycle — `elems` / `active` / `provisional`

A list's dynamic children live in **neither** the `_List` node nor any `_ListTransaction` — they live in one `ListState` actor (`1386`) that `_List.__init__` builds once (`1318`) and that `_List.newtrans` hands, unchanged, to every `_ListTransaction`. Committed reads (`_List.get`/`get_data`) and every in-flight edit therefore reach the same element Nodes through the same actor; membership is centralized, never copied per transaction. Each entry is a full Node subtree keyed by its **compound key string** (comma-joined, comma-escaped — must match `PathKey.name` and `path_route`, §8).

State (`1387-1390`):

| state | type | meaning |
|---|---|---|
| `elems` | `dict[key, Node]` | the element Nodes — the store. `_List`/`_ListTransaction` hold **no** children of their own. |
| `active` | `dict[tid, set[key]]` | per in-flight tid, the keys it has **claimed**, accumulated across all of this edit's passes. `tid in active` ⇔ an edit is mid-flight against this list. |
| `provisional` | `set[key]` | keys present in `elems` but **outside committed membership**: inserts not yet committed, and committed entries scheduled for removal. **Hidden from reads.** |

**`all()` — read visibility (`1434`).** Returns `elems` minus `provisional`. `_List.get`/`get_data` enumerate `all()`, so a GET never observes a provisional entry — neither an uncommitted insert nor a pending delete.

**`acquire` (`1404`) / `acquire_existing` (`1419`) — claiming entries.** Both record the touched keys in `active[tid]` and return the touched element Nodes, and both **accumulate** into `active[tid]` through the shared `_activate` helper (`1397`) — `active[tid] |= keys`, never overwrite — so a key claimed in an earlier pass stays claimed for the whole edit. They differ only in creation policy:

```
 acquire(tid, keys: dict[key, key-leaves])      ← configure(): the keys this diff provides
   new = set(keys) - set(elems)                   # keys not yet present
   for k in new:                                  #   instantiate each as an entry Node
     elems[k] = template(PathKey(k,…), lower); bind_db
   provisional |= new                             # new entries are born invisible
   return _activate(tid, set(keys))               # active[tid] |= keys

 acquire(tid, None)                             ← force / WILDKEY fan-out
   return _activate(tid, set(elems))              # claims every existing entry; creates none

 acquire_existing(tid, keys: set[key])          ← linkage() into entries this edit didn't configure
   return _activate(tid, {k for k in keys if k in elems})   # never resurrects a missing key
```

A new key joins `provisional` the instant it is acquired, so until commit even the creating edit reads it back as absent and no concurrent GET/edit can see it. `acquire_existing` is the **linkage** entry point: a link may target an entry committed by an *earlier* tx that this edit never configured, so it claims such entries if they still exist but never instantiates a missing one (a dangling target is skipped).

> **Why accumulate, not overwrite.** A single tid configures a list across multiple passes (initial apply + linkage re-applies + lock-time re-config), and each pass calls `acquire` with only the keys *that pass* names. If `acquire` overwrote `active[tid]`, a key claimed in pass 1 but not pass 2 would fall out of the claimed set, `release` would never lift it from `provisional`, and the trailing "delete still-provisional keys" step would delete a key the transaction had legitimately committed. Accumulating keeps every key the tid touched confirmed across all passes (`multipass_keep`, `test_ttt_list.act`).

**`release(tid, ok, deletes)` (`1422`) — confirm / roll back / delete.** Called from `_ListTransaction.commit` (`1622`) with `deletes = {key | accum[key].empty}`, the entries this edit emptied (§5):

```
 ok == True:   provisional -= active[tid]      # touched entries confirmed → become visible
               provisional |= deletes           # emptied entries now pending physical removal
 ok == False:  (neither)                         # aborted insert STAYS provisional; no delete scheduled
 always:       del active[tid]
               if not active:                    # no edit in flight anywhere on this list…
                   for k in provisional: del elems[k]   # …drop them: entry Node + all descendants
                   provisional = set()
```

Two consequences. **Confirmation is per-tid; physical deletion is global.** On success a tid's touched keys leave `provisional` at once — a new entry becomes visible immediately, even while another edit is still in flight — but the actual `del elems[k]` waits until `active` drains, i.e. until the *last* concurrent edit releases. And **an aborted insert cleans itself up**: `ok=False` skips the `-=`, the key stays provisional, and it is physically removed once `active` empties — no rollback bookkeeping.

**Removal is driven by an emptied element, not by omission.** A list configure is **incremental**: a key a source omits from a later pass means "unchanged", so `_ListTransaction.configure` re-renders such keys with an empty `{}` diff and the accumulated `active[tid]` keeps them confirmed — they survive. Genuine removal is **explicit**: a source restates the list with a `gdata.Absent(key)` element (and `gdata.diff` emits exactly that for a dropped key — §2). That Absent empties the entry's last source (`newconf == {}`, §5), the element returns `empty=True`, and `commit` collects it into `deletes`; a whole-list `gdata.Absent()` fans this to every entry via the WILDKEY transpose. (Proven by `basic_delete`/`all_delete`/`partial_delete`/`multipass_same_src_delete`; non-deletion of omitted keys by `multipass_keep`/`multipass_same_src_keep`.)

**`is_empty()` (`1441`).** True only when `elems`, `active`, and `provisional` are *all* empty — no entries, no in-flight edit, nothing pending. Feeds `_List.is_empty` → `_Container.is_empty`, the restore precondition (§9).

**`recreate` (`1444`) / `restore` (`1447`) — persistence bypass.** On `load_from_db` these skip the acquire/provisional path entirely: `recreate(key, leaves)` rebuilds the entry Node straight into `elems` (visible at once — a restored entry is committed by definition) and `restore` forwards each content sub-record to it. The `ATTR_KEYS` record (→ `recreate`) is guaranteed to arrive before any content record (→ `restore`) for the same key by ATTR ordering (§9).

### The YieldState continuation idiom

`lock` and `wait_complete` iterate children **one at a time** — not with a loop — because each child lock/complete is a *yielding* async action. The iteration state is snapshotted into a single slot `self.state: ?YieldState[T]` (`529`) holding `(iterator, current key, tid, out, results, dbuf, done)`:

```
 lock(tid, done):
   it = iter(sorted(accum.keys()))
   key = next(it)               # StopIteration here → done(CfgOk()) immediately
   self.state = YieldState(it, key, tid, out, done, dbuf)
   elems[key].lock(tid, out, lock_cont, dbuf)        # yield await

 lock_cont(res):                # resumed when the child's lock returns
   state.results[state.key] = res
   key = next(state.it)
     ├─ ok           → state.key = key; elems[key].lock(...)   # advance to next child
     └─ StopIteration→ self.state = None; state.done(self._analyze(state.results))
```

`wait_complete`/`wait_complete_cont` use the same pattern (`_ListTransaction` at `1570-1646`; the Container forms mirror it). **`self.state` is a single slot**: a second concurrent iteration on the same Transaction node would clobber it — so the one-edit-at-a-time-per-node contract (§4) extends to these iterators, not just to the Session's continuation slots.

---

## 4. Sessions vs transactions

**Session** = one editing context over one Layer (`actor Session`, `841`), bound to a root Transaction (`root = rootnode.newtrans()`) plus a recursively-constructed child Session over the lower Layer. It owns single-slot per-edit state: `buf` (pending per-source diff), `done_cont`/`comp_cont`/`lock_cont` (continuation slots), `tid_state` (the in-flight tid), and a shared `dbuf` write buffer.

**Transaction** = the per-node candidate machinery, keyed by a `tid = 'tr' + actorid()` minted per edit (`898`). The whole config tree is mirrored as a tree of Transaction actors; each transform leaf holds **per-tid candidate dicts** so multiple in-flight tids stage independent proposals against shared committed state.

### The per-tid candidate model

```
 committed (shared)                  per-tid candidate (staged)
 ──────────────────                  ──────────────────────────
 running   dict[src,Node]            diffs[tid]                 accumulated per-source diff
 output    ?Node                     candidates[tid]            = patch(running, diffs[tid])
 linked    Node                      essays[tid] = (out, mem)   compute result, not promoted
 subscriptions  list[TaggedPath]     candidate_linked[tid]
 subscribers    list[TaggedPath]     candidate_subscriptions[tid]
 memory                              candidate_subscribers[tid]
        ▲                                        │
        └──────── commit(tid, ok=True) promotes ─┘   (ok=False discards)
```

- `candidate_*` use `get_def(tid, <committed default>)`: absence of a tid key means **inherit committed**, not empty (`1805`, `1822`, etc.).
- Candidate state is **never observable until commit**. `configure`/`compute` only write the per-tid dicts; `get()` reads committed `running`/`output`.

### Multi-pass configure & list-key membership

A single tid can configure a node multiple times (initial pass + linkage re-applies + lock-time re-config). `diffs[tid]` accumulates across passes (`accdiff.update`); `candidates[tid]` is recomputed each time. For lists, the per-tid touched-key set lives in `ListState.active[tid]`, which **accumulates** across passes (§3): `_ListTransaction.configure` re-configures every key it saw in an *earlier* pass (`accum`) but not the current diff with an empty `{}` diff, and the accumulated `active[tid]` keeps those keys confirmed so they survive commit. List-element **removal** is therefore explicit — a `gdata.Absent` element empties the entry (§5) — never implied by omitting a key from a later pass. See §3 for the full `acquire`/`release`/`provisional` lifecycle.

### The `done` vs `complete` callback contract

Two callbacks express two milestones. **`done` fires before `complete`, always.**

```
 SUCCESS path                                  ERROR path
 ────────────                                  ──────────
 configure / apply                             pre-lock error (CfgError up the tree):
 linkage fixpoint                                done(err)  AND  complete(err)  immediately
 lock (root then lower)                          (no lock, no commit)
 [DB write txn commits, if db bound]
 commit (whole stack, in-memory)              lock/flush error (edit_config_cont, res.errors):
   ▼                                            commit(tid, False)  (discard candidate)
 done_cont(result)   ◄── "whole Session chain    done_cont(err)
                          committed/persisted"    comp_cont(err)  DIRECTLY (not via wait_complete)
   ▼
 wait_complete(comp_cont)
   recurses to LOWEST layer, awaits device
   ▼
 comp_cont(value)    ◄── "downstream/device finished applying"
```

- **`done`** (`done_cont`, fired at `931`) = the candidate is locked, committed in memory, and — if a DB is bound — durably flushed to LMDB **first**: `_flush_dbuffer_then_commit` commits the LMDB write txn (`_flush_write_txn`, `872-876`) before `commit(...,True)` (`893`). There is no separate "accepted-but-not-committed" callback; by the time `done` fires, the commit has happened (the `TransformWriteFlow` test reads the persisted DB snapshot inside `done`, `test_ttt_persistence.act:321-334`). `done` receives `'Ok'` or the Exception.
- **`complete`** (`comp_cont`) = the bottom layer's `wait_complete` resolved (after async device apply). On the **error** path complete is invoked **directly** with the Exception, *not* via `wait_complete` (`933-934`). So a `complete` callback can receive an Exception, not just `'Ok'`.
- `wait_complete` recurses straight to the **lowest** layer and only there calls `root.wait_complete` (`997-1000`). A plain transform's `wait_complete` returns `'Ok'` immediately (`2001`); a `_DeviceConfig` delegates to `self.dev.wait_complete` (`~2419`) — the real completion source. At the lowest layer the result is **normalized before reaching the user callback**: `root.wait_complete(tid_state, lambda res: done((res.errors[0] if res.errors else "Ok") if isinstance(res, CfgResult) else res))` (`1000`) — a `CfgResult` collapses to its first error or `'Ok'`, anything else passes through. **Tests must read the lower layer in `complete`, not `done`** — reading in `done` races the device side-effects (see MEMORY note "TTT commit/read race").

### `force`

`force=True` (passed to `apply`/`root.configure`) makes configure re-run every existing child/element with an empty diff so unchanged subtrees recompute against new linked/dynstate. Its main consumer is transform-driven re-configuration (device reconcile). Concretely: `_Container.configure` synthesizes `{}` for each child (`1147-1149`) and `_ListTransaction.configure` calls `liststate.acquire(tid, None)` to pull *all* committed keys and configures each with `{}` (`1468-1472`) — that is the mechanism behind dynstate/device-reconcile recompute touching every existing element. Note `apply` always forces the **lower** session with `force=False` (`953`) — force governs only this layer's own pass.

### `recompute`

`recompute` (`1002`) is `edit_config` without a new diff: it skips `configure` and goes straight to `apply`/`lock`/`commit`, reusing the same continuation machinery. Used when inputs (memory/dynstate) changed rather than config — e.g. `update_dynstate` spawns `Session(...).recompute()` as a **separate transaction** with its own tid (`2115`).

### One Session ⇒ one edit at a time (a usage contract, not an enforced invariant)

`tid_state`, `done_cont`, `comp_cont`, `lock_cont` are single slots, all guarded by `if tid_state is not None`. A second `edit_config` on the *same* Session while one is in flight would clobber them. Concurrency arises instead from **independently-issued tids on shared nodes**: `Layer.edit_config` opens a *fresh* Session per call (`720-721`) over the same shared root, and dynstate recompute spawns its own Session. Nothing guards a direct caller who reuses one Session for overlapping edits — the safe pattern is one Session per transaction, which `Layer.edit_config` always does.

> **Caveat — dropped callbacks on the lock-time re-apply error path.** At `lock` (`961-967`), if `buf` is non-empty (an upper layer reconfigured during the async window) and the re-apply errors, the local `done` is called but `tid_state` is set only afterward (`968`). So `edit_config_cont`/`edit_config_finish` no-op (their `tid_state is not None` guard fails), and the stored `done_cont`/`comp_cont` are never fired. This violates the otherwise-uniform "both fire on error" rule. It is benign **only** because of fresh-Session-per-edit (the stranded continuations are GC'd with the throwaway Session); a long-lived reused Session would observe the dropped callback. Setting `tid_state = tid` before the re-apply at `963` would close the gap.

---

## 5. Transform lifecycle & automatic cleanup

A transform's lifecycle is **create / modify / remove**, and all three are expressed through the same per-source merge mechanism — there is no distinct "delete" code path.

- **Create**: a new source appears in `newconf`; `compute` runs and emits the new output downward.
- **Modify**: an existing source's slice changes; `compute` runs and `difference(old_output, new_output)` emits only the delta.
- **Remove**: a source's `gdata.patch` yields `None` (its diff fully removes its subtree), so it drops out of `newconf`. When *all* sources are gone, `newconf == {}`.

### Automatic recursive downstream cleanup

When `newconf == {}` (`1789-1796`), the transform:
1. sets `essays[tid] = (None, None)`,
2. calls `clear(tid, out)` which computes `difference(output, Container())` — a **remove diff** — and pushes it down via `out.configure(tid, {self.me: res})` (`2078-2084`), so the lower layer's output for this source is deleted,
3. emits unsubscribe `LinkRequest`s for all its subscriptions,
4. returns `CfgOk(empty=True)`.

For list elements, `empty=True` is what schedules removal. `_ListTransaction.commit` collects `deletes = {key for key,res in accum if res.empty}` (`1607-1611`) and calls `liststate.release(tid, ok, deletes)`. `ListState` physically `del elems[k]` for those keys (when no tx is active), which **drops the element Node and ALL its nested descendants in one shot** — no per-child delete code anywhere. Because the empty diff propagates down through every layer the same way, deleting a CFS service tears down its RFS and device config automatically. Proven by `basic_delete` (`test_ttt_list.act:93`), `all_delete` (`116`), `nested_delete` (`212`).

Containers, by contrast, are **structurally permanent**: `commit` clears `accum` but never deletes child nodes (`accum = {}` only). Deleting all content empties children but the container/children remain present (`test_ttt_container.act:97-133`). **Container "removal" is realized through the leaves, not the container shell**: an `Absent`/empty diff fans down via the WILDID transpose (§2) to every enclosing transform leaf, each of which hits the `newconf == {}` path and emits its *own* downstream remove. The container node survives but all its effect is gone — deletion always materializes at the transform leaf.

### Pure transform vs stateful Transform actor

- A **pure** transform implements `transform_wrapper(cfg, linked, memory, dynstate) -> (output, new_memory)` (`TransformFunction`, `2123`). `PassThrough` returns `(cfg, memory)`. Raising aborts the transaction.
- A **stateful** transform additionally wires an actor via the `act` ctor arg (`Transform(function, act=...)`, `2035`). `init_actor` (`2105`) calls the generated `*TransformCtor` with a `TransformActorParams(path, update_dynstate, update_oper, dev, lower)` and stores the returned `on_conf` callback. **For a plain `Transform`, `dev` is `None`**: `TransformFunction.init_actor` constructs `TransformActorParams(path, update_dynstate, update_oper, None, lower)` (`2140`), and the generated `*TransformCtor` selects `params.lower_tree_provider` as the actor's handle. Only an **RFS** transform gets a real `DeviceMgr`: `RFSFunction.init_actor` passes `dev` (`2313`) and the ctor selects `params.dev` (`ttt_gen.act:191`). The actor can asynchronously push state back:
  - **`update_dynstate(newstate)`** (`2109-2115`): if changed, stores it and spawns a `Session(...).recompute()` — a fresh transaction that folds the new dynstate into output.
  - **`update_oper(oper)`** (`2022-2023`): stores config-false operational data merged into `get_data` output only (no transaction).
- `essays[tid].1` is the memory half; on commit-ok `update_memory(essay.1)` persists it. `finalize(tid)` (`2117`) runs `function.on_conf(self.get(), memory)` when running config is non-empty.

---

## 6. The configure → lock → commit → complete lifecycle

Optimistic two-phase protocol keyed by `tid`.

```
 PHASE 1 (stage, side-effect-light)        PHASE 2 (serialize + promote)
 ──────────────────────────────────        ─────────────────────────────
 configure(tid, {'_': diff})  buffer        lock(tid, edit_config_cont)
        ▼                                       root.lock  ──► lower.lock   (top-down,
 apply(tid)  root.configure → compute             then layer below)         consistent
   pushes downward delta into lower               ◄── locks acquired         lock order
   Session via out.configure(tid,{me})    edit_config_cont(res):
   then lower.apply (recurse down, 953)       res.errors?  no → _flush_dbuffer_then_commit
        ▼                                                      yes → commit(False) + finish(err)
 while res.requests or res.updates:        _flush_dbuffer_then_commit:
   root.linkage(...)   LINK FIXPOINT          [LMDB write txn commits FIRST if db bound]
        ▼                                      commit(tid, True)  promote whole stack
 res.errors? yes → done+complete(err)         edit_config_finish('Ok')
            no  → store callbacks, lock            done_cont('Ok')
                                                   wait_complete(comp_cont) ► device ► comp_cont
```

### End-to-end cross-actor sequence (one successful edit, db bound)

This traces a single `edit_config` through the whole Session chain and the per-node Transaction tree, marking each `# yield await` suspension and where the lower chain is driven. Upper = the Session the caller invoked; Lower = its recursively-constructed child Session; Device = the bottom layer's `_DeviceConfig`/`swdev`.

```
 caller        Upper Session            Upper root Txn tree      Lower Session            Device
   │ edit_config(diff, done, complete)
   ├──────────►│ tid = 'tr'+actorid()
   │           │ configure → buf['_']=diff
   │           │ apply(tid) ───────────►│ root.configure(tid, diff, lower, force, dbuf)
   │           │                        │  compute → out.configure(tid,{me:δ}) ──► buf  (lower's diff staged)
   │           │  (953) lower.apply ─────────────────────────────►│ root.configure(tid, …)
   │           │                        │                         │  compute → out.configure ──► Device-layer buf
   │           │◄── CfgResult ──────────┤◄── CfgResult ───────────┤
   │           │ while req|upd:                                                       (LINK FIXPOINT, §7)
   │           │   root.linkage(tid,…) ►│  (drives subscriber/publisher exchange to a fixpoint)
   │           │ store done_cont/comp_cont
   │           │ lock(tid, edit_config_cont)
   │           │  (970) root.lock ──────►│ locker mutex per transform; YieldState child iteration
   │           │                         │   # yield await (suspends on contended nodes via pending)
   │           │◄── lock_cont1(res) ─────┤
   │           │  (977) lower.lock ──────────────────────────────►│ root.lock …   # yield await
   │           │◄── lock_cont2 ◄─────────────────────────────────┤
   │           │ edit_config_cont(res): no errors
   │           │ _flush_dbuffer_then_commit:
   │           │   _begin_write(db)            (busy? after WRITE_RETRY_DELAY, locks still held)
   │           │   dbuf.flush_to_db; commit()  # yield await  (one LMDB write txn for the whole stack)
   │           │  (990) commit(tid, True) ►│ promote candidate→running; invalidate other candidates
   │           │  (991) lower.commit ─────────────────────────────►│ commit(tid, True) ►│ …
   │           │ edit_config_finish('Ok')
   │◄ done ────┤ done_cont('Ok')
   │           │ wait_complete(comp_cont)
   │           │  (998) recurse to LOWEST ─────────────────────────────────────────────►│ root.wait_complete
   │           │                                                                         │  dev.wait_complete  # yield await
   │           │◄── lambda normalizes CfgResult→'Ok'/err ◄────────────────────────────────┤
   │◄ complete ┤ comp_cont('Ok')
```

Key timing facts: config flows **down** in one synchronous `apply` pass (each layer's transform pushes its delta into the lower Session's `buf` via `out.configure`, then `953` recurses `lower.apply`); locks are taken **root-then-lower** (`970`/`977`) for a consistent global order; commit fans **both** root and lower under the same tid (`990-992`); only the **lowest** layer awaits the device (`998-1000`).

### Notes

- **Candidate staging vs promotion.** Phase 1 writes only `candidates`/`essays`/`candidate_*` per tid; phase 2's `commit(tid, True)` atomically promotes them to `running`/`output`/`linked`/`subscriptions`/`subscribers` and **invalidates all other in-flight candidates** (`self.candidates = {}`, `1961-1963`), forcing concurrent tids to re-derive against the new running config. `commit(tid, False)` just drops the candidate; committed state is untouched.
- **DB durability precedes promotion.** The LMDB write txn commits before in-memory `commit` (`872-894`), so persistence and memory stay consistent; a DB failure aborts the tid. Busy-writer contention retries via `after WRITE_RETRY_DELAY` (`866`) without yet issuing commit.

### Strict serializability / concurrency model

The per-transform **`locker` mutex** (`var locker: ?str`, `1729`) is the serialization gate:

```
 lock(tid):  locker free      → locker = tid; done(CfgOk(...))
             locker == tid     → redundant; done(CfgOk())
             locker != tid     → self.pending.append(...)   (suspend, FIFO)

 commit(tid):  if tid == locker:  promote-or-discard; locker = None
                                  if pending: pop(0) and resume its lock
               else:              ignore  (spurious commit/config from a non-locker is a no-op)
```

- One tid holds the lock from `lock` through `commit`; others suspend in `pending` and resume in FIFO order on release (`1968-1972`). This serializes any two tids through any shared transform node.
- A tx observes exactly the committed state of all tids that committed before it locked (`overlapping_commit`, `test_ttt_transform.act:467-489`).
- Lock acquisition is **top-down within a layer, then to the layer below** (`root.lock` then `lower.lock`), giving a consistent global order to avoid deadlock across the chain.
- `lock` can re-run `configure(tid, {}, ...)` if a tid reached the transform only via link bookkeeping (`tid not in candidates`, `1902-1904`) so its candidate/essay exist before commit.
- **ListState provisional keys** add a second serialization point for list membership (§3): `all()` hides provisional keys, and physical deletion happens only when no tid is active.
- **Liveness under DB contention.** During the busy-writer retry window (`_begin_write` reschedules via `after WRITE_RETRY_DELAY`, `866`), the retrying tid has **already passed lock and holds the per-transform `locker` on every node in its stack** — `commit` has not run, so no lock is released. Every other tid queued in those nodes' `pending` queues stalls for the duration of the backoff. The DB-flush retry is therefore a real serialization/liveness consideration, not just a local stall.

---

## 7. Links

A **link** lets one transform (the **subscriber**) consume config produced by another transform elsewhere in the **same layer tree** (the **publisher**). Declared in YANG via `sw:link <tag>`: on a leaf with a `leafref` type (→ `LeafrefLink`), or on an inner node with a nested `sw:path` (→ `StaticLink`). Links are **intra-layer only** — only transform *output* crosses layers; link messages never do (`linkage` runs on a single layer's `root`, `907`).

### Codegen → runtime

At codegen (`ttt_links.extract_links`, `ttt_links.act:168`), each `sw:link` is resolved against the compiled schema, wrapped by cardinality, and `gen_build_target_links` emits a `build_target_links(conf)` function returning `list[TaggedPath]` — the publisher-selecting filters this transform currently demands, with leafref source values embedded into the FNode `value_match`. Wired into the transform as `self.build_links`. Cardinality rule (`ttt_links.act:182-194`): a `StaticLink` is always `Optional`; a `LeafrefLink` is **`Multi` iff a step in `link.source_path_from_transform` — the leafref source leaf's path *within the subscriber transform's input* — is a `schema.DList`** (`187-190`), else `Optional`; `Single` is defined but never emitted. Constraints enforced at codegen: unique tag per subtree; leaf links require a leafref type; `sw:link` forbidden under `sw:memory`/`sw:dynstate` (build_target_links only sees `conf`); `sw:link` unsupported on rfs-transforms (`ttt_gen.act:130-131`).

### Runtime cycle (driven to a fixpoint before lock)

```
 subscriber.configure
   build_links(merged) → latest demands
   diff vs candidate_subscriptions:
     new   → LinkRequest(tag, publisher_filter, route_fpath, status=True)
     gone  → LinkRequest(..., status=False)  AND  prune that subtree out of candidate_linked
   if any outstanding requests: SKIP compute this pass (wait for updates)
        │
        ▼  Layer loop:  while res.requests or res.updates: root.linkage(...)
 routing (Container.linkage / List.linkage):
   peel ONE path step per hop via .tail();  List routes by vequal(key) on value_match
        │
        ▼
 publisher.linkage (requests present):
   register/unregister subscriber in candidate_subscribers
   FAST PATH: if not updates and tid not in self.diffs → deliver current state to
              NEW subscribers only, skip forced recompute  (keeps service create O(1))
   → LinkUpdate(filter_fpath, subscriber, FULL rooted state)
        │
        ▼
 subscriber.linkage (updates present):
   for matching subscription: linked = merge(prune(linked, u.publisher), u.config)   # prune-then-merge
   self.configure(tid, {}, out, force=True)  → recompute with updated linked tree
```

- The publisher **always resends full state** (never deltas); the subscriber must **prune-then-merge** at the publisher path, or removed publisher children leak.
- `route_fpath` (subscriber self-address; list keys = **unnamed** `value_match` = compound key string) and `filter_fpath` (publisher advertisement; **named** key-predicate FNodes) are two distinct renderings of the same Path. `gdata.filter`/`prune` reject the unnamed form, so use `filter_fpath` for pruning and `route_fpath` only for List routing via `vequal`.
- All cross-link state is staged per-tid in `candidate_linked`/`candidate_subscriptions`/`candidate_subscribers` and promoted only on commit (`1939-1964`).

> **Termination caveat.** The linkage loop (`903-907`) has **no iteration bound**. It is convergent *by construction*: `link_requests` is diff-based/idempotent (`1825-1832`) and the subscriber-set-only fast path (`1859-1876`) breaks the subscribe→broadcast→resubscribe amplification. But convergence rests on `build_links` being a deterministic, monotone function of config — an adversarial transform whose link set oscillates would hang the edit with no diagnostic.

---

## 8. Paths & filters

A node's position is a singly-linked `Path` chain built top-down at construction: `PathRoot` → `PathElem` (named container/leaf step, carries namespace `ns`) → `PathKey` (list-element step, carries the element's key leaves). The same Path renders three ways:

```
 /routers/router[name=ce1]/config/mtu
        │
        ├─ path_route (257→)   list entry → unnamed FNode(value_match='ce1')   [routing/linkage]
        ├─ path_filter (274→)  list key   → named FNode(nameId, value_match='ce1')  [gdata.filter/prune]
        └─ make_rooted (285)   nested Container / List / Container   [publish/diff]
```

The two filter renderings are intentionally not interchangeable (comments at `251`/`267`).

### Read dispatch

Reads flow through `get_data(filt)`. Each tree level **consumes exactly one filter layer** (its own node name) and forwards only child selection downward:

```
 get_data(filt)
   │ root_filter(filt)         adapt named top-level filter → child of anonymous root FNode
   ▼
 Container.get_data
   │ filter_transpose(filt)    fan out → dict[Id → child FNode]  (None ⇒ read all children)
   ▼
 List.get_data
   │ list_filters → normalize
   │ exact_list_filter_branches  EXACT: every key a literal value_match, no children → route to elements
   │ list_element_filters        else SCAN: enumerate liststate.all(), per-element filter
   ▼
 Transform.get_data
   data = self.get()  (merge of running outputs, or empty Container)
   if oper: data = merge(data, _with_path_keys(path, oper))      # config + oper, additive
   gdata.filter(_with_path_keys(path, data), routed_filter(filt)) # routed_filter strips the consumed name
   return _with_path_keys(path, filtered)                          # reattach this element's key leaves
```

Key points: a list element's key leaves are **not stored in the element data**; they are reattached on read from `PathKey.keyvals` via `_with_path_keys`. A node returns `None` when an explicit filter selected nothing (read pruning); a `None`/bare-named filter reads the whole subtree. `key_str` escapes commas as `\,` — `PathKey.name`, the `path_route` value_match, and `ListState` keys must all use this identical escaping or routing silently fails.

---

## 9. Persistence

LMDB-backed, per-layer, prefix-scoped by layer name.

### What is stored

Under keys encoded by `swdb.KeyCodec` (`name | path-segments(escaped, namespace-qualified) | ATTRIBUTE_SEP | attr | QUALIFIER_SEP | source`):

| attr | written by | restored by |
|---|---|---|
| `ATTR_RUNNING` | `_TransformTransactionBase.db_ops` (`1928`) | base `restore` (`1983`); per-source, qualifier = source |
| `ATTR_OUTPUT` | `_TransformTransactionBase.db_ops` (`1928`) | base `restore` (`1983`) |
| `ATTR_KEYS` | `_ListTransaction.db_ops` (`1508`) | `_List.restore` → `liststate.recreate` (`1354-1368`); per-element key leaves (structural) |
| `ATTR_MEMORY` / `ATTR_DYNSTATE` | `_TransformTransaction.db_ops` / `_RFSTransform` (`2090` / `2252`) | the **subclass** `restore` overrides (`2092-2103` / `2254`) |

Plus a single `META_KEY` record `{version, namespaces}`: `version` must equal `1`; `namespaces` is the order-significant codec index used to encode/decode qualified ids (grows additively, indices stable).

**Restore symmetry — memory/dynstate live in subclass overrides.** The base `_TransformTransactionBase.restore` (`1983`) handles **only** `ATTR_RUNNING`/`ATTR_OUTPUT` and *raises* `"Unexpected persisted transform attribute"` on anything else. `ATTR_MEMORY`/`ATTR_DYNSTATE` are read back by the subclass overrides `_TransformTransaction.restore` (`2092`) and `_RFSTransform.restore` (`2254`), each of which intercepts those two attrs and delegates the rest to the base. So they are written and restored symmetrically — just not in the base class. `oper` is **not persisted at all** (it is transient out-of-band state injected via `update_oper` and merged only at read time, §8); on an empty commit it is nulled (`1955`) but it never reaches `db_ops`.

All ops for one edit are staged into one `swdb.Buffer` (shared down the whole stack) and flushed in a **single atomic LMDB write transaction** before the in-memory commit.

### Restore ordering (recreate before restore)

Restore is **not automatic** — you must build the (empty) Layer stack on a reopened Db, then call `load_from_db()`.

```
 1. reconstruct layers bottom-up: Layer("lower", ...) then Layer("upper", ..., lower=lower)
 2. restored_top.load_from_db()
      read META_KEY → codec (version check)
      require root.is_empty()   (else "TTT restore requires an empty tree")
      seek prefix = to_key([name]); for each matching key:
          root.restore(path[1:], attr, qualifier, value)
      recurse into lower.load_from_read_txn  IN THE SAME read txn  (unless top_only)
 3. one shared read txn for the whole stack; commit/abort at the top
```

A `_Container` routes a restore record to a child by matching **either the bare name or the namespace-qualified name**: `if key.name == child_name or swdb.qualified_name(key) == child_name` (`1103`). This is what lets a qualified-namespace path segment route to the right child after the codec encodes it namespace-qualified. Within a List, an `ATTR_KEYS` record triggers `liststate.recreate(key, leaves)` to **rebuild the element Node before its content records arrive** — guaranteed by lexicographic ordering of the `ATTR_*` constants (the entry Node exists before its sub-records). Exact-name prefix isolation holds (`foo` and `foobar` restore independently). A removed namespace with live persisted data is rejected; one merely present in the gap is tolerated.

---

## 10. Code generation

`ttt_gen.act` is a pure source emitter. `ttt_prsrc(root, input_yang_module, output_yang_module, oper_yang_module?)` (`ttt_gen.act:326`) walks a compiled `schema.DRoot` and returns **two source strings**:

- **`base`** — one abstract class per transform (`TransformFunction` / `RFSFunction` subclass) that the developer subclasses by implementing `transform`. Generated `transform_wrapper`/`transform_xml` glue convert gdata/XML ↔ the modeled adata via `from_gdata`/`to_gdata`.
- **`ttt`** — `get_ttt(...)` returning the whole tree literal as the `proc(Path, ?Layer) -> Node` builder the Layer instantiates, plus `_build_target_links_*` link builders and `*TransformCtor` actor-wiring procs.

`dschema_to_tttsrc` recurses: plain containers/lists → nested `ttt.Container({...})` / `ttt.List(child, keys)`; a node carrying `sw:transform` / `sw:rfs-transform` / `sw:device` / `sw:device-config` terminates recursion with the matching leaf (`ttt.Transform` / `ttt.RFSTransform` / `ttt.Device` / `ttt.DeviceConfig`). Leaves and config-false nodes are never tree-builder elements (config-false subtrees matter only as oper state for an enclosing transform). `sw:memory`/`sw:dynstate` children add typed params and a memory output tuple; config-false oper state or dynstate cause a `*TransformCtor` to be emitted, with its actor handle selected by transform kind: `params.dev` (a `DeviceMgr`) for rfs-transforms, `params.lower_tree_provider` for plain transforms (`ttt_gen.act:191`). For the deeper mechanics (input class naming via `get_path_name`, `ns=`/`module=` gating, oper-wrapper typing, link IR resolution) see `ttt_gen.act` and `ttt_links.act` directly.

---

## 11. Reading the code — orientation map

| concern | type / actor | file:line |
|---|---|---|
| **Monoid helpers** | `per_src` `transpose_list` `transpose_container` `difference` `patch` `assert_complete` `merge` `prune` | `ttt.act:68,75,92,108,114,125,128,140` |
| **Paths** | `Path` `PathRoot` `PathElem` `PathKey` `path_route` `path_filter` `make_rooted` `_with_path_keys` | `212,220,226,234,257,274,285,293` |
| **Filters** | `root_filter` `routed_filter` `filter_transpose` `list_filters` `filter_exact_list_key` `exact_list_filter_branches` | `305,316,329,398,412,443` |
| **Subscriptions** | `LayerSharedSubscription` `LayerSubscriptionOwner` `merge_subscription_tree` | `465,485,505` |
| **Node** | `actor Node` / `class _Node`; `YieldState` | `551`/`579`; `529` |
| **Transaction** | `actor Transaction` / `class _Transaction` | `592`/`639` |
| **Layer** | `actor Layer`; `load_from_db` `newsession` `edit_config` `tree_provider` `declare_subscriptions` | `673`; `679,714,720,729,804` |
| **Session** | `actor Session`; `edit_config` `apply` `lock` `commit` `wait_complete` `recompute` | `841`; `897,945,959,988,994,1002` |
| **Containers** | `Container` / `_Container` / `_ContainerTransaction` | `1050,1053,1121` |
| **Lists** | `List` / `_List`; `actor ListState`; `_ListTransaction` (`lock_cont`/`wait_complete_cont` `1583,1629`) | `1298,1301,1374,1439` |
| **Transform engine** | `_TransformTransactionBase` (`configure` `link_requests` `linkage` `lock` `commit`); `_TransformTransaction.compute/clear`; `TransformFunction`/`RFSFunction`; factories `Transform`/`RFSTransform`/`Device`/`DeviceConfig`; `TransformActorParams` | `1722` (`1774,1818,1846,1890,1939`); `2070,2078`; `2123,2296`; `2035,2149,2323,2364`; `2025` |
| **Links** | `Link`/`StaticLink`/`LeafrefLink`/`LinkedInput`; `extract_links`; `gen_build_target_links` | `ttt_links.act:6,20,26,34,168,255` |
| **Codegen** | `ttt_prsrc`; `dschema_to_tttsrc`; `TTTSrc` | `ttt_gen.act:326,91,54` |
| **Conflict raise** (not in TTT) | `gdata._merge_rec` Leaf-vs-Leaf | `acton-yang/src/gdata.act:2102-2109` |

### Things that will bite you

- `assert_complete` is a **no-op** — no validation happens at `1799`.
- `per_src` is a **debug formatter**, unrelated to per-source storage (every call site commented out).
- `patch` (TTT, per-source dict) ≠ `gdata.patch` (single tree); the TTT helper additionally drops a source when its result is `None`.
- `difference` is **asymmetric**: `difference(None, b)` returns `b` (full tree), not a diff. Order matters.
- `merge` is **partial** — conflicting scalar leaves raise; it is not last-writer-wins.
- WILDKEY/WILDID must be fanned out and deleted before recursing (`del` at `1157`/`1482`) or they leak as a fake child. Don't confuse that with the `del` at `1145` (drops non-transform diff children).
- `_Container.is_empty` only descends into child Containers/Lists — a tree with only transform state still reports empty.
- `ListState.acquire`/`acquire_existing` both **accumulate** into `active[tid]` via `_activate` (`1397`), never overwrite — a key touched in an earlier pass stays claimed across the edit's later passes (§3). List-element removal is driven by an explicit `gdata.Absent` element emptying the entry, not by omitting a key from a later pass.
- `YieldState`'s `self.state` is a **single slot**; a second concurrent child iteration on the same Transaction clobbers it (§3).
- On error, `complete` does **not** go through `wait_complete` — it gets the Exception directly. And on the lock-time re-apply error path, callbacks can be dropped entirely (§4 caveat).
- Base transform `restore` (`1983`) handles only RUNNING/OUTPUT and *raises* on memory/dynstate — those are restored by subclass overrides (`2092`/`2254`); `oper` is never persisted (§9).