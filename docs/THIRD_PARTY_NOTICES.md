# Licensing and third-party notices

Battery Tool Plus 1.0.0 (2026-10-22) is a modified fork of
[BatteryTool by Orest Tokovenko](https://github.com/oresttokovenko/battery-tool).
The combined application is distributed under **GPL-3.0-only**; see `../LICENSE`.
This does not replace the original licenses of its components.

## Upstream BatteryTool

The upstream Python/C project was distributed under Apache License 2.0, except
for separately licensed third-party files. Its license is preserved verbatim in
`../LICENSES/Apache-2.0.txt`. Attribution and historical changelog entries remain.
Fork modifications include CLI/hardware error handling, controller coordination,
the SwiftUI manager, Metal/CPU workers, scheduling, history, prediction and
release packaging; see `CHANGELOG.md` and Git history.
The fork's new original code is licensed under GPL-3.0-only.

## SMC implementation

`c/smc.c` and `c/smc.h` retain their notices:

- Copyright (C) 2006 devnull
- Portions Copyright (C) 2013 Michael Wilber
- GNU General Public License, version 2 or (at your option) any later version.

Source reference: [smcFanControl / smc-command](https://github.com/hholtmann/smcFanControl/tree/master/smc-command).
This distribution exercises the GPL version 3 option for the combined application.
Apache-2.0 portions retain their original terms and notices in that combination.
See [Apache's compatibility explanation](https://www.apache.org/licenses/GPL-compatibility)
and [GNU's GPLv3 guide](https://www.gnu.org/licenses/quick-guide-gplv3.html).

## Corresponding source and build

Each application Release includes a `BatteryToolPlus-<version>-source.tar.gz`
asset from the exact commit used to build the application, including C/Swift
sources, build scripts, license texts and documentation. Download it alongside
the binary at https://github.com/hcy2206/battery-tool-plus/releases.
On Apple Silicon with macOS 15+ and Xcode Command Line Tools, extract the source
and run `./scripts/build-macos.sh`. No third-party library download is needed for
the native build: it links macOS frameworks and SQLite and uses the OS Swift
runtime. Python dependencies and cmocka are not linked into the native app.

No Developer ID key is required to rebuild this ad-hoc-signed release.
See the README for local signing and installation. The software is provided
without warranty, as specified by its licenses.
