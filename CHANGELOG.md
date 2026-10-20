# Battery Tool Plus Changelog

Repository: [hcy2206/battery-tool-plus](https://github.com/hcy2206/battery-tool-plus).
This project is a fork of [BatteryTool](https://github.com/oresttokovenko/battery-tool).

## Unreleased

### Changed

- Dashboard shows the four modes (system, ready, daily, timed) as one exclusive row whose highlight follows the current mode, with the actions (set a plan, pause load, hand back to the system) in a separate row. The menu bar offers the same mode picker.

## [0.4.0-beta.2](https://github.com/hcy2206/battery-tool-plus/releases/tag/v0.4.0-beta.2) (2026-10-20)

### Fixed

- Battery readings on macOS 27 and the 15.8 / 26.7 firmware: capacity figures are read from the nested `BatteryData` dictionary when the top-level keys are absent, instead of reporting -1 % / 0 % health.
- Charge control on that firmware: the SMC wrapper no longer treats an absent key as readable, and both the app and the CLI pick the key set the firmware actually has (CHTE, CH0B/CH0C, or CHIE adapter cut-off alone) instead of failing on CHTE.
- A history database write failure no longer stops the task or revokes power authorization; it is shown as a warning.
- Load workers run at user-initiated QoS so CPU load lands on performance cores, and their heartbeat lease is 15 s so a slow power service cannot cascade into a worker exit.
- Starting a plan that the policy rejects (for example with the charger unplugged) now reports why.
- Recommendations are clamped to the 24-hour plan limit; computing a recommendation no longer silently saves settings.
- The CLI reports that root is required instead of failing on the lock file.

### Added

- Idle recommendation page relaid out: grouped learning settings, hour pickers and a start / end / duration window card.
- Application icon, display name, category and copyright in the bundle.
- Menu bar icon reflects the current charge level and charging state.
- CI runs on pushes to `main` and includes the native integration tests.

### Changed

- The application ships as a signed DMG with an Applications shortcut instead of a ZIP.
- History records are inserted with bound parameters.
- Project metadata lists the fork maintainer and repository URLs.
- Documentation rewritten in a direct voice.

## [0.4.0-beta.1](https://github.com/hcy2206/battery-tool-plus/releases/tag/v0.4.0-beta.1) (2026-10-18)

### Added

- Native SwiftUI management window and menu bar controls.
- CPU and Metal GPU load during both charging and discharging, with activity pauses and thermal protection.
- Ready-to-leave, daily cycling and timed-load modes, with separate desktop-work and departure deadlines.
- Local SQLite history, initial idle windows, history-based recommendations and charging-time estimates.
- Native policy, controller, IPC, worker-lifetime and view-rendering checks.

### Fixed

- CLI argument parsing, threshold validation, error exit codes and SMC failure handling.
- Charging restoration, charger-disconnection handling, duplicate logging and C input validation.
- Editable-build dependencies and coordination between CLI and native power control.
- Explicit macOS 15 Swift deployment target, checked against the packaged binary.

### Documentation

- Adopt the Battery Tool Plus project name and fork repository links.
- Document source installation rather than directing fork users to the upstream PyPI package.
- Document native management, development setup and inherited release configuration.

## Upstream history

The entries below describe releases of the original BatteryTool project. Their
version dates, authorship context, comparison URLs and commit links are preserved
as upstream history; they are not releases published by Battery Tool Plus.

## [0.3.0](https://github.com/oresttokovenko/battery-tool/compare/v0.2.4...v0.3.0) (2026-08-17)


### Features

* add file-backed fake SMC backend for sandboxed testing ([3639bac](https://github.com/oresttokovenko/battery-tool/commit/3639baca23fad8b6f66f58b9e6dba158a743bb07))
* add file-backed fake SMC backend for sandboxed testing ([2af9e17](https://github.com/oresttokovenko/battery-tool/commit/2af9e1707a201533f5d230f9232b4cdc3aa6772b))


### Documentation

* explain the fake backend testing model in CONTRIBUTING ([2fd8bdc](https://github.com/oresttokovenko/battery-tool/commit/2fd8bdc5229e394455d33b161d8c1d1879483ea9))
* replace em dashes and arrows with plainer punctuation ([1f5b58a](https://github.com/oresttokovenko/battery-tool/commit/1f5b58a81cc5e4678b3ab3f5e80d3d6497694226))

## [0.2.4](https://github.com/oresttokovenko/battery-tool/compare/v0.2.3...v0.2.4) (2026-07-12)


### Bug Fixes

* check IOKit read results and guard against zero-capacity divisions ([11a908c](https://github.com/oresttokovenko/battery-tool/commit/11a908ca5d47f5c0b3454fdb241251b4834f6800))
* check IOKit read results and guard against zero-capacity divisions ([c8d3fd1](https://github.com/oresttokovenko/battery-tool/commit/c8d3fd196155989e2dcf77a78797a3a969b8f1fe))

## [0.2.3](https://github.com/oresttokovenko/battery-tool/compare/v0.2.2...v0.2.3) (2026-02-16)


### Bug Fixes

* clean up logging and correctly cli invocation ([1a36f0c](https://github.com/oresttokovenko/battery-tool/commit/1a36f0cabdd164d354c5d5ca35076c78a2a1af78))
* clean up logging and correctly cli invocation ([2c5d760](https://github.com/oresttokovenko/battery-tool/commit/2c5d7604edea23f4c6e1a658b63e047e41823edb))

## [0.2.2](https://github.com/oresttokovenko/battery-tool/compare/v0.2.1...v0.2.2) (2026-02-16)


### Bug Fixes

* rename release workflow to match PyPI trusted publisher ([c86def1](https://github.com/oresttokovenko/battery-tool/commit/c86def1cb706f5c5fa504d5ce1639cee9e052537))
* rename release workflow to match PyPI trusted publisher ([64b16d9](https://github.com/oresttokovenko/battery-tool/commit/64b16d95fab18bb37aa137af0f5b5089f4999927))

## [0.2.1](https://github.com/oresttokovenko/battery-tool/compare/v0.2.0...v0.2.1) (2026-02-16)


### Bug Fixes

* use ubuntu runner for PyPI publish step ([f30bd4e](https://github.com/oresttokovenko/battery-tool/commit/f30bd4ec8f244f06169b425de103e68aee9c757b))
* use ubuntu runner for PyPI publish step ([4b0515b](https://github.com/oresttokovenko/battery-tool/commit/4b0515b2d66f5edf3433857f4e7643d9eed364fc))

## [0.2.0](https://github.com/oresttokovenko/battery-tool/compare/v0.1.0...v0.2.0) (2026-02-16)


### Features

* add CFFI C bindings for SMC read/write ([30efc98](https://github.com/oresttokovenko/battery-tool/commit/30efc982bc92e6a706fd92927ccce23475bad35f))
* add CFFI C bindings for SMC read/write ([a625c0c](https://github.com/oresttokovenko/battery-tool/commit/a625c0ccefdbcc99bc77fb2231582351e3bb0907))

## 0.1.0 (2026-02-16)


### Features

* replace Python SMC bindings with CFFI C extension ([cea4ce8](https://github.com/oresttokovenko/battery-tool/commit/cea4ce86aef04cde6dbea71505fe45a7c13b9faa))
