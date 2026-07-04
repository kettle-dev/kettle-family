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

- Family releases now raise downstream family dependency floors after each
  member release by default, with `--no-auto-floors` and
  `release.auto_dependency_floors: false` opt-outs.

### Changed

### Deprecated

### Removed

### Fixed

### Security

## [0.2.3] - 2026-07-03

- TAG: [v0.2.3][0.2.3t]
- COVERAGE: 95.51% -- 2210/2314 lines in 21 files
- BRANCH COVERAGE: 76.41% -- 716/937 branches in 21 files
- 29.82% documented

### Fixed

- Root-configured member branch target commands now rediscover the checked-out
  member repository before version bumping, preventing old release lines from
  being bumped to the current branch's version.

## [0.2.2] - 2026-07-02

- TAG: [v0.2.2][0.2.2t]
- COVERAGE: 95.54% -- 2205/2308 lines in 21 files
- BRANCH COVERAGE: 76.53% -- 714/933 branches in 21 files
- 29.82% documented

### Fixed

- Branch-target workflows now fail before doing member work when a dirty
  worktree would block `git checkout` for configured release target branches.

## [0.2.1] - 2026-07-02

- TAG: [v0.2.1][0.2.1t]
- COVERAGE: 95.45% -- 2180/2284 lines in 21 files
- BRANCH COVERAGE: 76.39% -- 702/919 branches in 21 files
- 29.96% documented

## [0.2.0] - 2026-07-02

- TAG: [v0.2.0][0.2.0t]
- COVERAGE: 95.56% -- 2173/2274 lines in 21 files
- BRANCH COVERAGE: 76.50% -- 700/915 branches in 21 files
- 29.96% documented

### Changed

- `kettle-family bump-version` now delegates per-member version file,
  gemspec-version, and relative bump target handling to `kettle-dev`'s shared
  `kettle-bump` engine, leaving `kettle-family` responsible only for
  family-specific dependency pin updates and reporting.
- `kettle-dev` is now a runtime dependency because `kettle-family` reuses its
  version bump engine directly.
- Runtime dependency `kettle-dev` now requires 2.3.0 or newer.

### Fixed

- `kettle-family release --execute --publish` now skips already-published
  members whose release-state reports no pending release, even when current
  `HEAD` no longer matches the release tag.
- `kettle-family bump-version` now prefers `lib/<gem_name>/version.rb` over
  alphabetically earlier compatibility namespace version files when discovering
  each member's editable version file.

## [0.1.32] - 2026-07-01

- TAG: [v0.1.32][0.1.32t]
- COVERAGE: 95.46% -- 2227/2333 lines in 21 files
- BRANCH COVERAGE: 75.96% -- 714/940 branches in 21 files
- 29.82% documented

### Added

- `kettle-family` now supports `--exclude` anywhere member selection is
  available, selecting all members except the comma-separated exclusions.
- `kettle-family` now uses command-specific option parsing and help powered by
  `command_kit`, keeping naked help focused on global options.

### Fixed

- `kettle-family` reports a final summary for every command, including selected
  release members left pending when parallel release execution stops after a
  failure.

- `kettle-family release --execute` runs release members sequentially on
  TruffleRuby to avoid a TruffleRuby 24.2 internal `ENV.replace` crash from
  `Bundler.with_unbundled_env` inside parallel release threads
  ([truffleruby/truffleruby#4352](https://github.com/truffleruby/truffleruby/issues/4352)).

## [0.1.31] - 2026-06-30

- TAG: [v0.1.31][0.1.31t]
- COVERAGE: 95.32% -- 1974/2071 lines in 21 files
- BRANCH COVERAGE: 75.73% -- 696/919 branches in 21 files
- 37.71% documented

### Added

- `kettle-family bex` runs `bundle exec COMMAND` across selected family members,
  preserving command arguments after `--` and committing member changes by default.

### Fixed

- Package configured license files in gem release file lists.
- `kettle-family release --publish` now fails instead of skipping when the
  selected member version is already published but local `HEAD` is not the
  matching release tag, preventing unreleased commits from being hidden by an
  already-published version number.

## [0.1.30] - 2026-06-29

- TAG: [v0.1.30][0.1.30t]
- COVERAGE: 95.32% -- 1934/2029 lines in 21 files
- BRANCH COVERAGE: 75.31% -- 674/895 branches in 21 files
- 37.71% documented

### Added

- Family root configs can now set `release.member_target_branches` to override
  branch-stack targets for specific members while leaving other member-local
  branch configs inherited.

## [0.1.29] - 2026-06-28

- TAG: [v0.1.29][0.1.29t]
- COVERAGE: 95.29% -- 1922/2017 lines in 21 files
- BRANCH COVERAGE: 75.14% -- 668/889 branches in 21 files
- 38.37% documented

### Added

- `kettle-family --only` now accepts comma-separated member names for subset
  workflows.
- Parallel `kettle-family release` output now includes derived release waves so
  dependency-safe release groups are visible.

### Fixed

- Parallel `kettle-family release` waves now stop assigning queued releases as
  soon as any member fails.

## [0.1.28] - 2026-06-28

- TAG: [v0.1.28][0.1.28t]
- COVERAGE: 95.24% -- 1899/1994 lines in 21 files
- BRANCH COVERAGE: 74.86% -- 658/879 branches in 21 files
- 38.37% documented

### Added

- `kettle-family --start-at MEMBER@BRANCH` now resumes member-local and family
  branch-stack workflows at a specific release target branch.

## [0.1.27] - 2026-06-28

- TAG: [v0.1.27][0.1.27t]
- COVERAGE: 95.13% -- 1854/1949 lines in 21 files
- BRANCH COVERAGE: 74.79% -- 638/853 branches in 21 files
- 38.60% documented

### Added

- Added `kettle-family bup [GEM]` for family-wide `bundle update --all` or
  targeted `bundle update GEM`, and `kettle-family bupb` for family-wide
  `bundle update --bundler`.

### Fixed

- `kettle-family bup` and `bupb` now commit bundle lockfile changes after a
  successful member update so branch-stack runs can continue to the next branch.

## [0.1.26] - 2026-06-27

- TAG: [v0.1.26][0.1.26t]
- COVERAGE: 95.08% -- 1836/1931 lines in 21 files
- BRANCH COVERAGE: 74.47% -- 627/842 branches in 21 files
- 38.60% documented

### Added

- `kettle-family release --skip-steps LIST` now passes `skip_steps=LIST`
  through to `kettle-release` commands for recovery releases.

## [0.1.25] - 2026-06-27

- TAG: [v0.1.25][0.1.25t]
- COVERAGE: 95.07% -- 1833/1928 lines in 21 files
- BRANCH COVERAGE: 74.40% -- 625/840 branches in 21 files
- 38.60% documented

### Fixed

- `kettle-family` now renders `env -u` unset options before environment
  assignments so quiet release commands run correctly through `mise exec`.

## [0.1.24] - 2026-06-27

- TAG: [v0.1.24][0.1.24t]
- COVERAGE: 95.07% -- 1831/1926 lines in 21 files
- BRANCH COVERAGE: 74.47% -- 627/842 branches in 21 files
- 38.60% documented

### Fixed

- `kettle-family release --env NAME_LOCAL=/path` now allows release readiness
  checks to use matching local source lockfile paths for recovery releases.
- Quiet template and release commands now unset Bundler/RubyGems debug
  environment variables whose presence enables resolver/debug output.

## [0.1.23] - 2026-06-27

- TAG: [v0.1.23][0.1.23t]
- COVERAGE: 95.02% -- 1813/1908 lines in 21 files
- BRANCH COVERAGE: 74.58% -- 619/830 branches in 21 files
- 38.60% documented

### Fixed

- `kettle-family release --env KEY=VALUE` now applies explicit environment
  overrides to release commands and release lockfile normalization.

## [0.1.22] - 2026-06-27

- TAG: [v0.1.22][0.1.22t]
- COVERAGE: 95.01% -- 1808/1903 lines in 21 files
- BRANCH COVERAGE: 74.58% -- 619/830 branches in 21 files
- 38.60% documented

### Fixed

- `kettle-family template` now preserves template environment overrides during
  lockfile normalization so local path families remain active.
- `kettle-family release` now suppresses inherited Bundler/debug verbosity for
  member release commands unless `--debug` is enabled.

## [0.1.21] - 2026-06-26

- TAG: [v0.1.21][0.1.21t]
- COVERAGE: 95.01% -- 1807/1902 lines in 21 files
- BRANCH COVERAGE: 74.52% -- 617/828 branches in 21 files
- 38.60% documented

### Changed

- Local path environment suppression now uses `TSLP_DEV` for
  `tree_sitter_language_pack` overrides instead of
  `TREE_SITTER_LANGUAGE_PACK_DEV`.

### Fixed

- Release failure reports now suggest rerunning the full executed release command,
  preserving publish mode, instead of a `--start-at` hint that can skip
  unreleased siblings from a failed parallel wave.

## [0.1.20] - 2026-06-26

- TAG: [v0.1.20][0.1.20t]
- COVERAGE: 94.99% -- 1802/1897 lines in 21 files
- BRANCH COVERAGE: 74.39% -- 613/824 branches in 21 files
- 38.60% documented

### Added

- `kettle-family template --execute` now runs member templating in parallel by
  default, with `--jobs` and `template.jobs` controls plus compact live progress
  and changed-file summaries.
- `kettle-family release --execute` now runs dependency-safe member release
  waves in parallel for distinct Git worktrees, coordinating concurrent
  RubyGems MFA prompts.
- `kettle-family install --execute` now installs independent local gems in
  dependency-safe waves, using `--jobs` for parallelism.

### Changed

- Family templating now invokes `kettle-jem` in quiet JSON mode and suppresses
  noisy Bundler/debug environment by default, overriding inherited debug
  variables unless `--debug` is passed.

### Fixed

- Parallel release MFA coordination now shares an entered OTP only with prompts
  already queued at submission time, shows the live queued prompt count as
  `N / Y` for the current release wave capacity, and asks again for later
  RubyGems OTP prompts.

## [0.1.19] - 2026-06-25

- TAG: [v0.1.19][0.1.19t]
- COVERAGE: 94.74% -- 1531/1616 lines in 21 files
- BRANCH COVERAGE: 76.20% -- 538/706 branches in 21 files
- 39.63% documented

### Fixed

- Interactive release commands now leave RubyGems MFA/OTP prompts for the user
  instead of sending cached signing passphrases to the `Code:` prompt.
- Interactive command output is now normalized to UTF-8 before report rendering,
  avoiding encoding crashes when a release command fails after PTY output.

## [0.1.18] - 2026-06-25

- TAG: [v0.1.18][0.1.18t]
- COVERAGE: 94.72% -- 1524/1609 lines in 21 files
- BRANCH COVERAGE: 76.14% -- 536/704 branches in 21 files
- 39.63% documented

### Added

- `kettle-family release` now accepts `--accept` / `--no-accept` to control
  whether interactive confirmation prompts are answered automatically.

### Fixed

- Interactive release commands now answer `[y/N]` confirmation prompts before
  writing cached PEM passphrases, preventing confirmation prompts from consuming
  the signing password as input.

## [0.1.17] - 2026-06-25

- TAG: [v0.1.17][0.1.17t]
- COVERAGE: 94.67% -- 1510/1595 lines in 21 files
- BRANCH COVERAGE: 76.00% -- 532/700 branches in 21 files
- 39.63% documented

### Added

- `kettle-family push`, `kettle-family pull`, and `kettle-family up` now plan
  or execute family-wide git synchronization commands.
- `kettle-family gha-sha-pins` now plans or executes
  `kettle-gha-sha-pins` across family members, including branch stacks that
  include `main`.
- `kettle-family bump-version` now accepts the same relative bump targets as
  `kettle-bump` (`major`, `minor`, `patch`, and `pre`) and applies them per
  member from each member's current version.
- Text output from `kettle-family` now starts with the loaded `kettle-family`
  version so local runs show which executable is active.

### Fixed

- Branch-stack commands now allow `main` as a configured branch target for
  workflows like templating while excluding it from install and release
  traversals.
- `kettle-family bump-version` now leaves non-exact family dependency
  requirements unchanged instead of rejecting them as ambiguous, allowing
  families with loose inter-gem constraints to use relative version bumps.
- `kettle-family bump-version --execute` now reports actual writes as
  `updated`, includes each member's `current -> target` version change, commits
  version bump edits, and uses member-local branch target stacks so branch
  traversal can continue safely.
- Text reports now indent each line of multi-line command output consistently.
- `kettle-family release-state` now recovers member-local branch-stack release
  configuration from another local branch when the current branch does not carry
  `.kettle-family.yml`, restoring branch-matrix output for branch-stack families.
- Branch `release-state` rows now report the latest released version from that
  branch's major line instead of the repository-wide latest tag.
- Member-local branch-stack configuration is now discovered through the same
  shared path for `install`, `bump-version`, `add-changelog`, workflow commands,
  and `release-state`, including configs that only exist on another local
  branch.
- Branch lane audits now run as part of `kettle-family check`, and
  `branch-lanes` is no longer advertised as a separate user-facing command.

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

[Unreleased]: https://github.com/kettle-dev/kettle-family/compare/v0.2.3...HEAD
[0.2.3]: https://github.com/kettle-dev/kettle-family/compare/v0.2.2...v0.2.3
[0.2.3t]: https://github.com/kettle-dev/kettle-family/releases/tag/v0.2.3
[0.2.2]: https://github.com/kettle-dev/kettle-family/compare/v0.2.1...v0.2.2
[0.2.2t]: https://github.com/kettle-dev/kettle-family/releases/tag/v0.2.2
[0.2.1]: https://github.com/kettle-dev/kettle-family/compare/v0.2.0...v0.2.1
[0.2.1t]: https://github.com/kettle-dev/kettle-family/releases/tag/v0.2.1
[0.2.0]: https://github.com/kettle-dev/kettle-family/compare/v0.1.32...v0.2.0
[0.2.0t]: https://github.com/kettle-dev/kettle-family/releases/tag/v0.2.0
[0.1.32]: https://github.com/kettle-dev/kettle-family/compare/v0.1.31...v0.1.32
[0.1.32t]: https://github.com/kettle-dev/kettle-family/releases/tag/v0.1.32
[0.1.31]: https://github.com/kettle-dev/kettle-family/compare/v0.1.30...v0.1.31
[0.1.31t]: https://github.com/kettle-dev/kettle-family/releases/tag/v0.1.31
[0.1.30]: https://github.com/kettle-dev/kettle-family/compare/v0.1.29...v0.1.30
[0.1.30t]: https://github.com/kettle-dev/kettle-family/releases/tag/v0.1.30
[0.1.29]: https://github.com/kettle-dev/kettle-family/compare/v0.1.28...v0.1.29
[0.1.29t]: https://github.com/kettle-dev/kettle-family/releases/tag/v0.1.29
[0.1.28]: https://github.com/kettle-dev/kettle-family/compare/v0.1.27...v0.1.28
[0.1.28t]: https://github.com/kettle-dev/kettle-family/releases/tag/v0.1.28
[0.1.27]: https://github.com/kettle-dev/kettle-family/compare/v0.1.26...v0.1.27
[0.1.27t]: https://github.com/kettle-dev/kettle-family/releases/tag/v0.1.27
[0.1.26]: https://github.com/kettle-dev/kettle-family/compare/v0.1.25...v0.1.26
[0.1.26t]: https://github.com/kettle-dev/kettle-family/releases/tag/v0.1.26
[0.1.25]: https://github.com/kettle-dev/kettle-family/compare/v0.1.24...v0.1.25
[0.1.25t]: https://github.com/kettle-dev/kettle-family/releases/tag/v0.1.25
[0.1.24]: https://github.com/kettle-dev/kettle-family/compare/v0.1.23...v0.1.24
[0.1.24t]: https://github.com/kettle-dev/kettle-family/releases/tag/v0.1.24
[0.1.23]: https://github.com/kettle-dev/kettle-family/compare/v0.1.22...v0.1.23
[0.1.23t]: https://github.com/kettle-dev/kettle-family/releases/tag/v0.1.23
[0.1.22]: https://github.com/kettle-dev/kettle-family/compare/v0.1.21...v0.1.22
[0.1.22t]: https://github.com/kettle-dev/kettle-family/releases/tag/v0.1.22
[0.1.21]: https://github.com/kettle-dev/kettle-family/compare/v0.1.20...v0.1.21
[0.1.21t]: https://github.com/kettle-dev/kettle-family/releases/tag/v0.1.21
[0.1.20]: https://github.com/kettle-dev/kettle-family/compare/v0.1.19...v0.1.20
[0.1.20t]: https://github.com/kettle-dev/kettle-family/releases/tag/v0.1.20
[0.1.19]: https://github.com/kettle-dev/kettle-family/compare/v0.1.18...v0.1.19
[0.1.19t]: https://github.com/kettle-dev/kettle-family/releases/tag/v0.1.19
[0.1.18]: https://github.com/kettle-dev/kettle-family/compare/v0.1.17...v0.1.18
[0.1.18t]: https://github.com/kettle-dev/kettle-family/releases/tag/v0.1.18
[0.1.17]: https://github.com/kettle-dev/kettle-family/compare/v0.1.11...v0.1.17
[0.1.17t]: https://github.com/kettle-dev/kettle-family/releases/tag/v0.1.17
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
