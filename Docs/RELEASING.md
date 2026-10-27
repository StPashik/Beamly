# Releasing Beamly

Requirements: Xcode 26 or later, FFmpeg, Node.js/npm, Git, an authenticated [GitHub CLI](https://cli.github.com/), and the Sparkle signing key in the maintainer's macOS Keychain. Do not include credentials in this repository.

Use GitFlow: start release/<version> from an up-to-date develop, and perform the steps below on that release branch. Feature work targets develop; fixes to a published release start as hotfix/<description> from main. Never commit release preparation directly to main.

1. Update CFBundleShortVersionString and increment CFBundleVersion in Resources/Info.plist. Update the version in package.json, the pinned download/npm versions in README, and the changelog. Sparkle compares the numeric build version.

   For releases containing the new 4K/HDR path, include this notice prominently in the GitHub release notes until physical receiver testing is recorded: **"4K/HDR over AirPlay has not been tested on physical receivers. Playback may be unstable or incompatible with some devices or network configurations."** Automated FFmpeg, HTTP, and AVPlayer checks are not physical AirPlay validation. Retain specific unverified profiles and subtitle limitations from Docs/Media-Streaming.md.
2. Run Scripts/test.sh with FFmpeg installed.
3. Run Scripts/release.sh. This produces dist/Beamly-VERSION-universal.zip, dist/SHA256SUMS, and a cask with that archive's SHA-256 checksum. It verifies both architectures and the embedded framework's code-signature integrity.
4. Run npm test and npm pack --dry-run. Check the ZIP contains only Beamly.app and that no private files are staged in Git.
5. Review Docs/UpdateNotes.html, then run Scripts/sign-release.sh on the maintainer's Mac. The HTML fragment is embedded in Sparkle's update window, including the physical-testing warning. The script uses Sparkle's generate_appcast with the Keychain account app.peamer.mac to sign the archive and feed, then verifies the feed signature. It writes dist/appcast.xml; no private key leaves Keychain. If signing fails, do not publish an unsigned feed.
6. Commit the source changes, including the generated cask, and push the release branch. Open a pull request into main, wait for CI, and merge with a merge commit. Tag that exact merge commit. Publish the exact archive whose checksum was committed.
7. Create a **draft** GitHub release with the ZIP, SHA256SUMS, and appcast.xml attached. Verify all three assets, then publish it as the latest release. Draft publication keeps the feed and archive available together. For example, for a future 1.1.0 release:

~~~sh
git switch main
git pull --ff-only origin main
git tag -a v1.1.0 -m "Beamly 1.1.0"
git push origin v1.1.0
gh release create v1.1.0 \
  dist/Beamly-1.1.0-universal.zip dist/SHA256SUMS dist/appcast.xml \
  --verify-tag --draft --title "Beamly 1.1.0" --notes-file release-notes.md
gh release edit v1.1.0 --draft=false --latest
~~~

8. Merge the release branch back into develop through a pull request, keeping the merge commit. Hotfixes must also be merged back into develop.
9. Download the published assets, verify checksums/signatures, and try both installers in isolated installation directories. The cask must retain the checksum of the uploaded ZIP; rebuilding may change it.

The npm installer can be installed directly from the tagged GitHub repository. Publishing @stpashik/beamly on npm is a separate optional action requiring access to that scope; GitHub access does not grant npm publishing access.

## Sparkle signing key

Beamly 1.0.1 embeds the public Ed25519 key in SUPublicEDKey. The private key was created with Sparkle's generate_keys --account app.peamer.mac and is stored in the maintainer's login Keychain. Keep an encrypted backup outside the repository; use the bundled generate_keys --help export/import options and follow [Sparkle's key-management instructions](https://sparkle-project.org/documentation/).

Do not generate a replacement key for each release. Future updates must use the same key trusted by installed apps. Losing it prevents existing ad-hoc builds from accepting further in-app updates. Key rotation requires a planned migration; changing only the public key in the next release does not update the trust held by older installs.

The manual updater reads https://github.com/StPashik/Beamly/releases/latest/download/appcast.xml. Both the XML feed and ZIP are signed. Automatic checks, background installs, and system profiling are disabled. Version 1.0.0 has no updater and needs one manual upgrade to 1.0.1 or later.

## GitHub Actions

[ci.yml](../.github/workflows/ci.yml) runs Swift tests, the universal build, compiled-localization checks, and npm installer tests on macOS 26. It checks pull requests targeting develop or main, and pushes to both branches. CI has read-only repository access, receives no private signing key, and does not publish releases or modify the cask in Git. Workflow changes require permission to write workflows.

## Signing and notarization

The community archive built by Scripts/build.sh uses an ad-hoc code signature. The Xcode project retains hardened runtime and uses automatic Apple Development signing; select a development team before running it. Ad-hoc signing has no Team ID and cannot satisfy hardened runtime's library-validation requirement for the embedded Sparkle framework. Sparkle's separate Ed25519 signatures authenticate updates; they do not provide an Apple-verified developer identity or notarization.

For a notarized release, sign the assembled universal application and embedded Sparkle helpers with your Developer ID Application identity and hardened runtime, submit it to Apple's notarization service, and staple the successful ticket. Recreate the ZIP, checksum, and signed feed after stapling. Verify with codesign, xcrun stapler validate, and Gatekeeper. See Apple's [distribution documentation](https://developer.apple.com/documentation/xcode/distributing-your-app-for-beta-testing-and-releases).

Do not describe an ad-hoc build as notarized, publish credentials, or remove quarantine as part of an installer. Local development records, reverse-engineering evidence, and screenshots containing private filenames are intentionally excluded from Git.
