# Getting started

Build the app, install a nightly, and import your first app. Product model lives in `README.md:6-29`; build entry points live in `README.md:83-101`.

## Prerequisites

You need an Apple Silicon Mac with Xcode 26 plus and the iOS platform installed (`README.md:85`, `.github/workflows/build.yml:121-167`).

```sh
xcodebuild -downloadPlatform iOS
```

## Build from source

```sh
./build-ophanim.sh Release
```

This runs `xcodebuild` on the `Ophanim` scheme, deep ad-hoc re-signs leaf-first, verifies, and installs to `~/Applications/Ophanim.app` (`build-ophanim.sh:12-43`). Only `Release` and `Nightly` exist; `Debug` is named in the scheme but absent and fails (`AGENTS.md:20`).

Then deploy the injected runtime where hosted apps load it from:

```sh
./scripts/deploy-runtime.sh
```

See `README.md:87-94` for the companion scripts (`Galgal/build-galgal.sh`, `Galgal/build-agent.sh`, `TestApp/build-testapp.sh`, `scripts/integration-test.sh`).

## Install a nightly

Nightly builds are rolling pre-releases on the `nightly` tag (`.github/workflows/build.yml:373-376`). Download `Ophanim.app.zip`, then:

```sh
unzip Ophanim.app.zip -d /Applications
xattr -dr com.apple.quarantine /Applications/Ophanim.app
```

The quarantine clear is required because builds are ad-hoc signed (`.github/workflows/build.yml:301-306`).

## Import your first app

1. Launch Ophanim and drop in an `.ipa` file. It re-signs, injects Galgal, and installs the app (`README.md:103-109`).
2. Open the app Instrumentation settings: enable the engine, pick categories, sinks, and the injection method (`README.md:106-107`). Start with `embedded` (see `reference/GLOSSARY.md`).
3. Launch the app from within Ophanim. View captured events in View log or `log stream --predicate 'subsystem == "be.ophanim"'` (`README.md:108-109`).
4. No `.ipa` handy: build the harness with `./TestApp/build-testapp.sh`, which produces `TestApp/build/OphanimTest.ipa` (`TestApp/build-testapp.sh:1-4,45-47`), then import that file.

Headless instead: `install_app` runs the same importer with Galgal forced (`docs/MCP-GUIDE.md:240-255`); start from `guides/01-operator-runbook.md`.
