# Releasing Beamly

Requirements: Xcode 26 or later, FFmpeg, Node.js/npm, Git, and an authenticated [GitHub CLI](https://cli.github.com/). Do not include signing credentials in this repository.

1. Update `CFBundleShortVersionString` / `CFBundleVersion` in `Resources/Info.plist`, the version in `package.json`, the pinned npm version in README, and the changelog.
2. Run `Scripts/test.sh` with FFmpeg installed.
3. Run `Scripts/release.sh`. This produces `dist/Beamly-VERSION-universal.zip`, `dist/SHA256SUMS`, and a cask with that archive's SHA-256 checksum. It verifies both architectures and the local signature.
4. Run `npm test` and `npm pack --dry-run`. Check the ZIP contains only `Beamly.app` and that no private files are staged in Git.
5. Commit the source changes, including the generated cask. Push the commit and verify the checks (locally, or in CI if enabled). Tag that exact commit, then publish the exact archive whose checksum was committed:

```sh
git tag -a v1.0.0 -m "Beamly 1.0.0"
git push origin main v1.0.0
gh release create v1.0.0 \
  dist/Beamly-1.0.0-universal.zip dist/SHA256SUMS \
  --verify-tag --title "Beamly 1.0.0" --notes-file CHANGELOG.md
```

6. Download the published assets, verify `SHA256SUMS`, and try both installers in isolated installation directories. The cask must retain the checksum of the uploaded ZIP; a rebuilt ZIP may have a different checksum.

The npm installer can be installed directly from the tagged GitHub repository. Publishing `@stpashik/beamly` to npm is a separate, optional action requiring access to that npm scope; GitHub access does not grant npm publishing access.

## Optional GitHub Actions

[ci.example.yml](ci.example.yml) runs the Swift tests, universal build, and npm installer checks on a macOS 26 runner. To enable it, copy it to `.github/workflows/ci.yml` and commit using a GitHub account or token with permission to write workflows. The initial publishing credentials do not have that permission; the first release was checked locally instead.

## Signing and notarization

The current release uses an ad-hoc signature. This verifies integrity and supports local builds; it is not a Developer ID signature and does not imply notarization.

For a notarized release, sign the assembled universal application with your Developer ID Application identity and hardened runtime, submit it to Apple's notarization service, and staple the successful ticket. Recreate the ZIP and cask checksum after stapling, then verify with `codesign`, `xcrun stapler validate`, and Gatekeeper before publishing. See Apple's [distribution documentation](https://developer.apple.com/documentation/xcode/distributing-your-app-for-beta-testing-and-releases).

Do not describe an ad-hoc build as notarized, publish credentials, or remove quarantine as part of an installer. Local development records, reverse-engineering evidence, and screenshots containing private filenames are intentionally excluded from Git.
