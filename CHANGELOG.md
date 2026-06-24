# Changelog

[![SemVer 2.0.0][📌semver-img]][📌semver] [![Keep-A-Changelog 1.0.0][📗keep-changelog-img]][📗keep-changelog]

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog][📗keep-changelog],
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html),
and [yes][📌major-versions-not-sacred], platform and engine support are part of the [public API][📌semver-breaking].
Please file a bug if you notice a violation of semantic versioning.

[📌semver]: https://semver.org/spec/v2.0.0.html
[📌semver-img]: https://img.shields.io/badge/semver-2.0.0-FFDD67.svg?style=flat
[📌semver-breaking]: https://github.com/semver/semver/issues/716#issuecomment-869336139
[📌major-versions-not-sacred]: https://tom.preston-werner.com/2022/05/23/major-version-numbers-are-not-sacred.html
[📗keep-changelog]: https://keepachangelog.com/en/1.0.0/
[📗keep-changelog-img]: https://img.shields.io/badge/keep--a--changelog-1.0.0-FFDD67.svg?style=flat

## [Unreleased]

### Added

- `kettle-family bump-version` now accepts the same relative bump targets as
  `kettle-bump` (`major`, `minor`, `patch`, and `pre`) and applies them per
  member from each member's current version.

### Changed

### Deprecated

### Removed

### Fixed

- `kettle-family bump-version` now leaves non-exact family dependency
  requirements unchanged instead of rejecting them as ambiguous, allowing
  families with loose inter-gem constraints to use relative version bumps.
- `kettle-family bump-version --execute` now reports actual writes as
  `updated`, includes each member's `current -> target` version change, commits
  version bump edits, and uses member-local branch target stacks so branch
  traversal can continue safely.
- Text reports now indent each line of multi-line command output consistently.

### Security

## [0.1.11] - 2026-06-23

- TAG: [v0.1.11][0.1.11t]
- COVERAGE: 94.51% -- 1342/1420 lines in 20 files
- BRANCH COVERAGE: 76.59% -- 458/598 branches in 20 files
- 40.40% documented

### Fixed

- Release reports now label plain `release` as build-only mode and
  `release --publish` as publish mode, making it clear when the workflow will
  run `kettle-release`.
- Branch-stack release workflows now reuse the cached gem signing password in
  member-local child workflows, avoiding a second signing prompt for the same
  family run.
- Release workflows now cache gem signing passwords for signed build commands,
  even when publishing is not enabled.
- Release workflows now normalize configured lockfiles before readiness checks
  with local path dependency environment variables disabled, then commit any
  resulting lockfile changes.

## [0.1.10] - 2026-06-23

- TAG: [v0.1.10][0.1.10t]
- COVERAGE: 94.34% -- 1300/1378 lines in 20 files
- BRANCH COVERAGE: 75.92% -- 432/569 branches in 20 files
- 40.14% documented

### Fixed

- Workflow commands now honor member-local `.kettle-family.yml` release target
  branches when the active family root has no branch stack, and reports list
  those member-local branch targets.

## [0.1.9] - 2026-06-23

- TAG: [v0.1.9][0.1.9t]
- COVERAGE: 94.43% -- 1255/1329 lines in 20 files
- BRANCH COVERAGE: 76.45% -- 409/535 branches in 20 files
- 39.73% documented

### Fixed

- Member workflow commands now run with the parent Bundler environment removed,
  so `bundle exec` inside a member uses that member's lockfile instead of
  pre-activated gems from the `kettle-family` process.
- CLI parsing now rejects stray positional arguments after options, catching
  missing repeated `--env` flags instead of silently ignoring environment
  overrides.

## [0.1.8] - 2026-06-23

- TAG: [v0.1.8][0.1.8t]
- COVERAGE: 94.48% -- 1250/1323 lines in 20 files
- BRANCH COVERAGE: 76.46% -- 406/531 branches in 20 files
- 39.73% documented

### Fixed

- `kettle-family release-state` now honors member-local `.kettle-family.yml`
  release target branches when the active family root has no branch stack,
  allowing mixed sibling workspaces to report stacked gems correctly.

## [0.1.7] - 2026-06-22

- TAG: [v0.1.7][0.1.7t]
- COVERAGE: 94.50% -- 1236/1308 lines in 20 files
- BRANCH COVERAGE: 76.49% -- 397/519 branches in 20 files
- 39.73% documented

### Added

- Added `kettle-family add-changelog` to pass one unreleased changelog entry to
  each selected member via the absolute installed `kettle-changelog`, including
  configured branch-lane traversal, so member binstubs cannot shadow it. Branch
  lane runs commit each member changelog update before checking out the next
  branch.

- Added support for JRuby 10.1 and TruffleRuby 34.0.

### Changed

- Retemplated project metadata and CI/development automation with `kettle-jem` v7.0.0.

### Fixed

- Corrected OpenCollective funding metadata to use the `kettle-dev` collective.
- Commands now traverse configured release target branches, matching release
  branch-lane behavior for gems with per-series branches, and `kettle-family
  template` commits post-template lockfile normalization changes before moving
  to the next branch.
- Family dependency ordering now ignores development dependencies, preventing
  false cycles between gems that only reference each other in test or release
  tooling.
- `kettle-family template` can bootstrap legacy members that do not yet have
  generated templating bundle wiring, and member command execution now respects
  `.tool-versions` mise configuration files.

## [0.1.6] - 2026-06-18

- TAG: [v0.1.6][0.1.6t]
- COVERAGE: 94.12% -- 1169/1242 lines in 20 files
- BRANCH COVERAGE: 76.97% -- 361/469 branches in 20 files
- 39.73% documented

### Changed

- `kettle-family template` now lets each member `kettle-jem` run create its own
  templating commit by default; use `--no-commit` to pass `--skip-commit` to
  member templating commands.

### Added

- Added `--env KEY=VALUE` workflow overrides so `kettle-family` commands can
  run a session with explicit environment values after member `mise.toml`
  defaults have loaded.

## [0.1.5] - 2026-06-17

- TAG: [v0.1.5][0.1.5t]
- COVERAGE: 94.24% -- 1162/1233 lines in 20 files
- BRANCH COVERAGE: 77.32% -- 358/463 branches in 20 files
- 39.73% documented

### Added

- Added `kettle-family install` to build and install selected local family gems,
  including config-defined `install.local_dependencies` resolved relative to the
  `.kettle-family.yml` file.

### Changed

- Development dependency `kettle-dev` now requires 2.2.10 or newer.

## [0.1.4] - 2026-06-16

- TAG: [v0.1.4][0.1.4t]
- COVERAGE: 93.72% -- 1060/1131 lines in 19 files
- BRANCH COVERAGE: 76.12% -- 322/423 branches in 19 files
- 40.14% documented

### Added

- Added configurable readiness checks, root/shared changelog support, release
  environment overrides, and an optional family changelog release phase for
  monorepo gem families whose members share root release metadata.

### Fixed

- Fixed the Ruby 3.2 CI appraisal so root changelog release-state checks have
  Prism available.

## [0.1.3] - 2026-06-14

- TAG: [v0.1.3][0.1.3t]
- COVERAGE: 94.34% -- 917/972 lines in 19 files
- BRANCH COVERAGE: 78.36% -- 268/342 branches in 19 files
- 44.00% documented

### Changed

- Runtime dependency `kettle-dev` now requires 2.2.8 or newer.
- `kettle-family release-state` now expands configured
  `release.target_branches` and reports release state for each branch
  independently.

- Project licensing changed from MIT to AGPL-3.0-only.
- `kettle-family release-state` now invokes `kettle-changelog` from the active
  toolchain instead of depending on `kettle-dev` as a published runtime
  dependency.

### Fixed

- Fixed release-state checks to use the active `kettle-dev` API instead of each
  member's potentially stale bundle.
- Fixed default discovery excludes so top-level `vendor/`, `tmp/`, `spec/`, and
  `test/` directories are ignored.

### Added

- Added `kettle-family metadata` to report each family member's version, Ruby
  requirement, licenses, and authors.

## [0.1.2] - 2026-06-13

- TAG: [v0.1.2][0.1.2t]
- COVERAGE: 94.17% -- 840/892 lines in 19 files
- BRANCH COVERAGE: 78.06% -- 242/310 branches in 19 files
- 41.80% documented

## [0.1.1] - 2026-06-13

- TAG: [v0.1.1][0.1.1t]
- COVERAGE: 94.16% -- 838/890 lines in 19 files
- BRANCH COVERAGE: 77.92% -- 240/308 branches in 19 files
- 41.80% documented

### Added

- Added configurable member discovery excludes via `members.exclude` /
  `members.ignore`.
- Added `kettle-family release-state` to report changelog release state across
  family members using `kettle-changelog --release-state --json`.

### Changed

- Retemplated generated project files with `kettle-dev` >= 2.2.7.

### Fixed

- Member discovery now filters configured excludes and git-ignored paths before
  loading gemspecs, avoiding duplicate fixture/tmp gemspecs in recursive family
  roots.
- Member discovery now skips default `spec/` and `test/` fixture trees before
  loading gemspecs, avoiding fixture load failures in family roots.

## [0.1.0] - 2026-06-10

- TAG: [v0.1.0][0.1.0t]
- COVERAGE: 94.28% -- 742/787 lines in 17 files
- BRANCH COVERAGE: 78.25% -- 223/285 branches in 17 files
- 42.34% documented

### Added

- Added the initial `kettle-family` CLI discovery slice with config loading, gemspec discovery, dependency ordering, selection, and JSON reports.
- Added workflow command planning/execution, readiness checks, and failure resume hints for `check`, `test`, `lint`, and `docs`.
- Added the `template` workflow with kettle-jem command planning, template environment, lockfile normalization hooks, and explicit family commit safety.
- Added `bump-version VERSION` with Prism-backed version constant edits, exact family dependency pin updates, and check/dry-run/execute modes.
- Added the `release` workflow with readiness/changelog gates, build-only and publish modes, fixed-order planning, and explicit tag/push phases.
- Added sibling-repository discovery, branch lane mappings, and a read-only `branch-lanes` audit command for multi-branch release planning.
- Added `release.target_branches` config so a flat repository can release sequentially across configured branch targets.
- Added `kettle-family release` passthroughs for `kettle-release` resume/security options and automatic already-published skips for resumable family releases.
- Added explicit runtime dependency wiring for extracted stdlib gems used by the CLI.

### Fixed

- Updated generated project metadata links to use the migrated `kettle-dev`
  GitHub organization.
- Restored `docs/CNAME` so the generated documentation site keeps its custom domain.
- Corrected misspelled contact metadata to use `galtzo.com`.
- Fixed CI load failures on engines without compatible `pty` support by falling back to Open3 for interactive release commands.
- Fixed Ruby 3.2 version-bump support by loading Prism lazily and wiring the Prism gem only for MRI versions that need it.

[Unreleased]: https://github.com/kettle-dev/kettle-family/compare/v0.1.11...HEAD
[0.1.12]: https://github.com/kettle-dev/kettle-family/compare/v0.1.11...v0.1.12
[0.1.12t]: https://github.com/kettle-dev/kettle-family/releases/tag/v0.1.12
[0.1.11]: https://github.com/kettle-dev/kettle-family/compare/v0.1.10...v0.1.11
[0.1.11t]: https://github.com/kettle-dev/kettle-family/releases/tag/v0.1.11
[0.1.10]: https://github.com/kettle-dev/kettle-family/compare/v0.1.9...v0.1.10
[0.1.10t]: https://github.com/kettle-dev/kettle-family/releases/tag/v0.1.10
[0.1.9]: https://github.com/kettle-dev/kettle-family/compare/v0.1.8...v0.1.9
[0.1.9t]: https://github.com/kettle-dev/kettle-family/releases/tag/v0.1.9
[0.1.8]: https://github.com/kettle-dev/kettle-family/compare/v0.1.7...v0.1.8
[0.1.8t]: https://github.com/kettle-dev/kettle-family/releases/tag/v0.1.8
[0.1.7]: https://github.com/kettle-dev/kettle-family/compare/v0.1.6...v0.1.7
[0.1.7t]: https://github.com/kettle-dev/kettle-family/releases/tag/v0.1.7
[0.1.6]: https://github.com/kettle-dev/kettle-family/compare/v0.1.5...v0.1.6
[0.1.6t]: https://github.com/kettle-dev/kettle-family/releases/tag/v0.1.6
[0.1.5]: https://github.com/kettle-dev/kettle-family/compare/v0.1.4...v0.1.5
[0.1.5t]: https://github.com/kettle-dev/kettle-family/releases/tag/v0.1.5
[0.1.4]: https://github.com/kettle-dev/kettle-family/compare/v0.1.3...v0.1.4
[0.1.4t]: https://github.com/kettle-dev/kettle-family/releases/tag/v0.1.4
[0.1.3]: https://github.com/kettle-dev/kettle-family/compare/v0.1.2...v0.1.3
[0.1.3t]: https://github.com/kettle-dev/kettle-family/releases/tag/v0.1.3
[0.1.2]: https://github.com/kettle-dev/kettle-family/compare/v0.1.1...v0.1.2
[0.1.2t]: https://github.com/kettle-dev/kettle-family/releases/tag/v0.1.2
[0.1.1]: https://github.com/kettle-dev/kettle-family/compare/v0.1.0...v0.1.1
[0.1.1t]: https://github.com/kettle-dev/kettle-family/releases/tag/v0.1.1
[0.1.0]: https://github.com/kettle-dev/kettle-family/compare/e4a9ca8ed52605b6375bbdd4f745b905a68b8b24...v0.1.0
[0.1.0t]: https://github.com/kettle-dev/kettle-family/releases/tag/v0.1.0
