---
icon: lucide/rocket
---

# Introduction

## Project setup

To create a new StratoWeave project, we recommend you clone [SORESPO](https://github.com/stratoweave/sorespo).
The **SOmewhat REalistic Service Provider Orchestrator** is a sample project
that we maintain to demonstrate best practices for structuring StratoWeave
projects.

``` bash hl_lines="1" title="Set up project"
git clone https://github.com/stratoweave/sorespo.git
```

!!! warning

    You do ***NOT*** need to clone the [StratoWeave](https://github.com/stratoweave/stratoweave)
    framework itself. All SORESPO dependencies will be downloaded by the Acton
    package manager at build time.

## Development Environment
StratoWeave is written in the [Acton Programming Language](https://acton.now/),
so you will need to set up an Acton development environment to work with it.
Use the Acton APT repository on Debian or Ubuntu, or Homebrew on macOS.

``` bash hl_lines="1-6" title="Debian / Ubuntu"
sudo install -m 0755 -d /etc/apt/keyrings
sudo wget -q -O /etc/apt/keyrings/acton.asc https://apt.acton-lang.io/acton.gpg
sudo chmod a+r /etc/apt/keyrings/acton.asc
echo "deb [signed-by=/etc/apt/keyrings/acton.asc] http://apt.acton-lang.io/ stable main" | sudo tee -a /etc/apt/sources.list.d/acton.list
sudo apt-get update
sudo apt-get install -qy acton
```

``` bash hl_lines="1" title="macOS"
brew install actonlang/acton/acton
```

## Project Structure
StratoWeave projects have a specific directory structure that organizes the
various components of the project. Here is an overview of the typical project
with files that you will be interested in modifying as you develop your system
specification and transform code.
```bash hl_lines="3 6-9 11-12 14 23-25" title="Project structure"
├── spec
│   ├── src
│   │   └── sorespo_gen.act
│   └── yang
│       ├── cfs
│       │   ├── ietf-l3vpn-svc.yang
│       │   ├── ietf-yang-types.yang
│       │   ├── netinfra.yang
│       │   └── sorespo-ietf-l3vpn-svc.yang
│       ├── inter
│       │   ├── l3pvn-inter.yang
│       │   └── netinfra-inter.yang
│       ├── rfs
│       │   └── sorespo-rfs.yang
│       ├── CiscoIosXr_25_3_1
│       │   └── ... (Cisco IOS-XR Device Adapter YANG models)
│       ├── JuniperCRPD_24_4R1_9
│       │   └── ... (Juniper cRPD Device Adapter YANG models)
│       └── NokiaSRLinux_25_3_2
│           └── ... (Nokia SR Linux Device Adapter YANG models)
└── src
    ├── sorespo
    │   ├── cfs.act
    │   ├── inter.act
    │   ├── rfs.act
    │   ├── device_types.act
    │   ├── devices
    │   │   └── ... (Auto-generated device definitions based on YANG models)
    │   ├── layers
    │   │   └── ... (Auto-generated layer definitions based on YANG models)
    │   └── sysspec.act
    └── sorespo.act
```

A quick overview of the most important files:

* `spec/src/sorespo_gen.act` This is the main entry point for generating the
 system specification. Here you define the layers of your system and how they
 are composed together. You also specify which YANG models to use for each layer.
* `spec/yang/` - This directory contains the YANG models that make up the
 system specification.
    * `cfs/`, `inter/`, and `rfs/` contain the service models for the 3 transform layers in SORESPO, e.g. Customer-facing, Resource-facing, and an intermediate layer.
    * `CiscoIosXr_25_3_1/`, `JuniperCRPD_24_4R1_9/`, and `NokiaSRLinux_25_3_2/` contain the vendor YANG for the relevant device adapters.
* `src/sorespo/` - This directory contains all the Acton code from which the orchestrator is built.
    * `cfs.act`, `inter.act`, and `rfs.act` contain the transform code for the 3 transform layers in SORESPO.

## Development Workflow
There are two distinct phases in the StratoWeave development workflow,
the first involves modifications to the ***System Specification***, and the second
resolves primarily around modifications to the ***Transform Code***.

``` mermaid
graph LR
  A[Start] --> B{System Specification Modifications?};
  B -->|Yes| C[Regenerate Project];
  B -->|No| D{Transform Code Modifications?};
  D ---->|Yes| E[Build Project];
  C --> E;
  D ---->|No| F[Done!];
  E --> F;
```

After modifying the system specification, e.g. any YANG models,
you will need to (re)generate the project.
``` bash hl_lines="1" title="(Re)generate project"
make gen
```

After modifying the system specification and/or the transform code,
you will need to (re)build the project [^1].
``` bash hl_lines="1" title="(Re)build project"
make build
```
[^1]:
  It is also possible to cross-compile for other platforms. This can be very
  useful when developing e.g. on macOS but deploying to Linux-based containers
  or servers.
  ``` bash title="Cross-compilation make targets"
  make build-linux-x86_64
  make build-linux-aarch64
  make build-macos-aarch64
  ```

The generated orchestrator binary will be located at `out/bin/sorespo`.

You can also execute the included test suite to verify that everything is
working correctly.
``` bash hl_lines="1" title="Run tests"
make test
```