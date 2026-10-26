# Contributing

Open an issue for a reproducible bug or a focused pull request for a fix. For larger changes, describe the proposed behavior in an issue first.

- Use Xcode 26 or later, with the macOS 26 SDK. Install FFmpeg for integration tests.
- Keep UI and playback coordination in `Sources/Beamly`; reusable queue, media, and HTTP code lives in `Sources/BeamlyCore`.
- Run `Scripts/test.sh` after changing application behavior. Run `Scripts/release.sh` and `npm test` after changing packaging or installation.
- An optional GitHub Actions workflow is provided in `Docs/ci.example.yml`; enabling it requires permission to write workflows.
- Add a small regression test for a bug. Explain non-obvious platform behavior in English comments.
- Keep original media files untouched, retain cancellation and path validation, and preserve existing users' queue and settings.
- Use generated or freely distributable media in tests. Do not commit personal settings, API keys, signing certificates, binaries, or local investigation output.

By contributing, you agree that your contribution is licensed under the project's MIT license.
