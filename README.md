<p align="left">
  <img src="docs/images/StratoWeaveTmpBlue.png" width="400"/>
</p>

[![REUSE Compliance Check](https://github.com/stratoweave/stratoweave/actions/workflows/reuse-compliance.yml/badge.svg)](https://github.com/stratoweave/stratoweave/actions/workflows/reuse-compliance.yml)

StratoWeave is a platform for the development of robust network orchestration systems based on model-driven declarative transforms. It does the heavy lifting so you can focus on building automation that makes sense. With native support for streaming telemetry, StratoWeave enables you to build reactive closed loop automation.

## Getting Started
Learn all about StratoWeave, in under 10 minutes, on our [YouTube channel](https://youtu.be/Mkl-Ud8shMI)!

[<img src="https://img.youtube.com/vi/Mkl-Ud8shMI/hqdefault.jpg" width="600" height="400"
/>](https://www.youtube.com/embed/Mkl-Ud8shMI)

Check out [SORESPO](https://github.com/stratoweave/sorespo/blob/main/README.md),
our **reference implementation** of StratoWeave, including hands-on tutorials!

## StratoWeave Design Philosophy

Automation logic is implemented primarily through *transforms* which take certain input data and transform it into other output data. Transforms are layered in order to break down problems into smaller tractable problems, similar to how structured programming introduced the idea of defining and calling functions to break down large problems into smaller problems.

The platform in itself is purely reactive, acting on input events, either configuration changes from northbound APIs or subscriptions on streaming telemetry from devices.

We try to "left shift" run time errors to compile / development time so we can detect and avoid bugs before committing code, building better and more robust automation systems. For example by turning YANG models into types, we can utilize the static type system of the programming language compiler to detect spelling mistakes or other data errors at compile time.

The ideas behind StratoWeave has its roots in ideas from functional programming combined with some influence from a decade of experience in operating large IP networks using automation. We just recently started building, but we have been thinking about this for a long time. We know what we want, now we just got to write some code.
