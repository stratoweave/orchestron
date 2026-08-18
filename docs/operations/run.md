
# Running StratoWeave
A StratoWeave-based Orchestrator is a single binary that can be deployed on any
Linux-based system.

## Deployment
The simplest way to deploy a StratoWeave orchestrator is wrap up the binary
into a container image and deploy it to a container orchestration platform such as
Kubernetes. The following example shows a simple Dockerfile that wraps the
SORESPO binary into a container image.

```dockerfile title="Dockerfile for a StratoWeave orchestrator"
FROM ubuntu:22.04
RUN apt-get update && apt-get install -y libssh-4
COPY out/bin/sorespo /usr/local/bin/sorespo
ENTRYPOINT ["/usr/local/bin/sorespo"]
```

!!! tip
    You could use a more minimal base image such as `alpine` or `debian:slim`,
    and in the future we intend to enable you to use a `FROM scratch` base
    image.

## Logging
StratoWeave orchestrators log to `stdout` and `stderr` by default. When you run
the orchestrator in a container, these streams are captured by the container
runtime and can be viewed with `docker logs` or `kubectl logs`.
Through [Docker logging drivers](https://docs.docker.com/engine/logging/configure/),
you can also redirect these streams to a file or a logging service of your
choice.

## Run-time configuration
Running `--help` is the fastest way to confirm the exact interface exposed by
the StratoWeave orchestrator binary you are using. The following example shows
the output of `--help` for SORESPO, the reference implementation of a
StratoWeave orchestrator.

```console title="Inspect runtime options for a StratoWeave orchestrator"
out/bin/sorespo --help
Usage: /sorespo [--db DB] [--exit-on-done] [--help] [--http-port HTTP-PORT] [--netconf-host-key NETCONF-HOST-KEY] [--netconf-password NETCONF-PASSWORD] [--netconf-port NETCONF-PORT] [--netconf-user NETCONF-USER] FILE [FILE ...]

Positional arguments:
  FILE           Config XML file(s)

Options:
  --db DB        LMDB directory for TTT persistence
  --exit-on-done Exit after startup config has been applied
  --help         show this help message
  --http-port HTTP-PORT HTTP listen port
  --netconf-host-key NETCONF-HOST-KEY SSH host key file for NETCONF; ephemeral in-memory key if unset
  --netconf-password NETCONF-PASSWORD NETCONF SSH password (v1 static credential)
  --netconf-port NETCONF-PORT NETCONF SSH listen port
  --netconf-user NETCONF-USER NETCONF SSH username (v1 static credential)
```

The required `FILE` arguments are startup configuration documents that are
loaded in the order given. In practice, operators often keep a base system
configuration in one file and add environment-specific overlays as later
arguments.

The most important runtime options are:

- `--db` enables LMDB-backed persistence, specifying the directory in which
  to store the database. If you omit this option, your StratoWeave
  orchestrator will run in a stateless mode and all configuration will be
  lost on shutdown.
- `--http-port` changes the HTTP listener, which defaults to `80`.
- `--netconf-port` changes the NETCONF over SSH listener, which defaults to
  `830`.
- `--netconf-host-key` points to a persistent SSH host key. If you omit it,
  SORESPO generates an ephemeral in-memory key at startup.
- `--netconf-user` and `--netconf-password` configure the built-in static
  NETCONF credentials. They default to `admin` / `admin` and should be
  overridden outside local testing.
- `--exit-on-done` applies the supplied startup configuration and then exits
  instead of continuing to serve traffic. This is useful for CI validation or
  one-shot initialization jobs.

### Acton Runtime System
As for any Acton application, you can also configure the [Acton Runtime System](https://acton.guide/rts.html).

!!! note
    There is generally no need to change these settings, the defaults are
    suitable for most deployments.