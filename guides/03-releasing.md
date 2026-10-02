# Releasing

How nightly builds ship and what the release job does. CI definition lives in `.github/workflows/build.yml:1-21`.

## Nightly flow

Every green build on `main` publishes: channel resolves to `nightly` unless the ref is a tag (`.github/workflows/build.yml:281-287,328-336`). The version comes from the packaged bundle `CFBundleShortVersionString` (`.github/workflows/build.yml:241-244`). To cut a numbered release instead, bump `MARKETING_VERSION` (`Ophanim.xcodeproj/project.pbxproj:1132,1235`) and push a `v*` tag; tag pushes always build (`.github/workflows/build.yml:56-64`).

## What tag-and-publish does

The `release` job (`.github/workflows/build.yml:328-471`) downloads the build artifact, then plans the release (`.github/workflows/build.yml:361-388`):

- Channel `nightly`: deletes the old rolling `nightly` pre-release and tag, then recreates it from the current commit with `Ophanim.app.zip`, the versioned zip, `OphanimTest.ipa`, and `checksums.txt`.
- Channel `release`: creates `v<version>` (or the pushed tag name) once with generated notes; an existing tag is left untouched because tags and assets are immutable.
- Non-prereleases get Sigstore provenance attestation (`actions/attest@v4`); failures there are non-blocking (`.github/workflows/build.yml:390-395`).
- Never cancel a tag run: it may be halfway through uploading an immutable release (`.github/workflows/build.yml:66-69`).

## Device-proof checklist

Confirm each item before announcing a build:

1. Runner is Apple Silicon `arm64` with Xcode 26 plus and the iOS SDK present (`.github/workflows/build.yml:121-167`). A macOS-only toolchain cannot produce a working bundle.
2. `codesign --verify --deep --strict` passes on `~/Applications/Ophanim.app` (`.github/workflows/build.yml:206-211`).
3. `Galgal` and `OphanimAgent.dylib` are Catalyst-tagged `arm64` slices via `vtool` (`.github/workflows/build.yml:213-229`).
4. `Assets.car` exists in `Contents/Resources` (`.github/workflows/build.yml:231`).
5. `dist/` holds at least one zip plus `checksums.txt`, or publishing refuses (`.github/workflows/build.yml:361-370).
6. Install proof on hardware: unzip into `/Applications` and clear quarantine with `xattr -dr com.apple.quarantine /Applications/Ophanim.app` (`.github/workflows/build.yml:301-306`).
