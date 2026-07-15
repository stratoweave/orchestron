# RESTCONF

StratoWeave orchestrators expose a standard RESTCONF interface rooted at
`/restconf` for retrieving and modifying northbound service intent.

## Entry points

### `GET /.well-known/host-meta`
Returns host metadata that points clients at the RESTCONF root.

### `GET /restconf/yang-library-version`
Returns the advertised RESTCONF YANG library version.

### `GET /restconf/data`
Returns the top-level northbound data tree.

XML example:

```sh
curl -H "Accept: application/yang-data+xml" \
  "$STRATOWEAVE_API_ORIGIN/restconf/data"
```

JSON example:

```sh
curl -H "Accept: application/yang-data+json" \
  "$STRATOWEAVE_API_ORIGIN/restconf/data"
```

## Editing northbound intent

The RESTCONF root is also used for configuration operations such as `PATCH` and
`DELETE`.

For example, a StratoWeave orchestrator can accept northbound intent updates
like this:

```sh
curl -f -X PATCH \
  -H "Content-Type: application/yang-data+xml" \
  -d @netinfra.xml \
  "$STRATOWEAVE_API_ORIGIN/restconf/data"
```

JSON payloads can also be used:

```sh
curl -f -X PATCH \
  -H "Content-Type: application/yang-data+json" \
  -d @netinfra.json \
  "$STRATOWEAVE_API_ORIGIN/restconf/data"
```

To remove a node, send `DELETE` to the resource path below `/restconf/data`:

```sh
curl -f -X DELETE \
  "$STRATOWEAVE_API_ORIGIN/restconf/data/netinfra:netinfra/router=STO-CORE-1"
```

## SORESPO quicklab examples

SORESPO quicklab Makefiles use RESTCONF directly for both reads and writes.
Typical targets include:

```sh
make get-config-restconf
make get-config-restconf-json
make send-config-wait FILE="netinfra.xml"
make send-config-json-wait FILE="netinfra.json"
make send-config-async FILE="netinfra.xml"
```

SORESPO quicklab also uses RESTCONF resource paths for simple validation, for
example:

```sh
curl -sS -f -H "Accept: application/yang-data+json" \
  "$STRATOWEAVE_API_ORIGIN/restconf/data/netinfra:netinfra/router=AMS-CORE-1"
```

## When to use RESTCONF vs the inspection API

Use RESTCONF when you want the northbound service model exactly as exposed by
your orchestrator, or when you want to submit service intent. Use the
[StratoWeave inspection API](http-api.md) for internal state such as layer
snapshots, rendered per-device configuration, device module inventory, and
approval queues.
