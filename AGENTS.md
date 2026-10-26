# Beamly development workflow

Use GitFlow for all new work in this repository.

- `main` contains published releases. Do not commit or push changes directly to it.
- `develop` is the integration branch. Start normal work from its latest remote state.
- Create `feature/<short-description>` from `develop`; submit a pull request back to `develop`.
- Create `release/<version>` from `develop` for release preparation. Merge it through a pull request into `main`, tag that merge commit as `v<version>`, and merge the release changes back into `develop`.
- Create `hotfix/<short-description>` from `main` for fixes to a published release. Merge the fix into both `main` and `develop`, and tag the release on `main`.
- Use merge commits when finishing GitFlow branches so branch history remains visible. Do not force-push shared branches or move published release tags.
- Keep branch names and commit messages in English. Do not include local build products, private investigation output, signing credentials, or user data in commits.

Read `CONTRIBUTING.md` and `Docs/RELEASING.md` before preparing a pull request or release.
