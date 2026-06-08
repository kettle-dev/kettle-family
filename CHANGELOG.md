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

- Added the initial `kettle-family` CLI discovery slice with config loading, gemspec discovery, dependency ordering, selection, and JSON reports.
- Added workflow command planning/execution, readiness checks, and failure resume hints for `check`, `test`, `lint`, and `docs`.
- Added the `template` workflow with kettle-jem command planning, template environment, lockfile normalization hooks, and explicit family commit safety.
- Added `bump-version VERSION` with Prism-backed version constant edits, exact family dependency pin updates, and check/dry-run/execute modes.
- Added the `release` workflow with readiness/changelog gates, build-only and publish modes, fixed-order planning, and explicit tag/push phases.
- Added sibling-repository discovery, branch lane mappings, and a read-only `branch-lanes` audit command for multi-branch release planning.
- Added `release.target_branches` config so a flat repository can release sequentially across configured branch targets.

### Changed

### Deprecated

### Removed

### Fixed

### Security
