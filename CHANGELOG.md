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

- Add version and mise-trust commands and run template members in dependency waves.

- Add reconcile-releases for verified RubyGems to GitHub Release backfills.

### Changed

### Deprecated

### Removed

### Fixed

- Template lockfile recovery preserves compound shell commands when appending lockfile bootstrap gems.

- Preserve the original template bootstrap failure when lockfile recovery finds no release lockfiles.

- Replace obsolete byebug debugger dependency stacks with debug before templating legacy members.

- Skip nomono-specific lockfile normalization until a legacy member declares nomono.

- Report actionable GitHub release reconciliation checks in family summaries.

- Honor KETTLE_DEV_DEV when release reconciliation invokes kettle-gh-release.

### Security

## [1.2.20] - 2026-07-31

- TAG: [v1.2.20][1.2.20t]
- COVERAGE: 94.15% -- 4281/4547 lines in 28 files
- BRANCH COVERAGE: 76.79% -- 1684/2193 branches in 28 files
- 28.88% documented

### Fixed

- Legacy Bundler recovery preserves shell operators in configured compound lockfile commands while removing an unsupported `--add-checksums` flag.

## [1.2.19] - 2026-07-31

- TAG: [v1.2.19][1.2.19t]
- COVERAGE: 94.13% -- 4282/4549 lines in 28 files
- BRANCH COVERAGE: 76.72% -- 1684/2195 branches in 28 files
- 28.88% documented

### Fixed

- Legacy Bundler recovery now retries template lock normalization without
  `--add-checksums` after that flag is rejected, instead of repeating the same
  unsupported command.

## [1.2.18] - 2026-07-31

- TAG: [v1.2.18][1.2.18t]
- COVERAGE: 94.14% -- 4277/4543 lines in 28 files
- BRANCH COVERAGE: 76.75% -- 1680/2189 branches in 28 files
- 28.88% documented

### Added

- Family template progress and final reports now aggregate checksum write
  bypasses, rendered-but-unchanged files, and changed files from Kettle-Jem
  NDJSON summaries.
- Template summaries now distinguish exact checksum hits from source-matched
  local destination changes protected by the template-only checksum policy.

## [1.2.17] - 2026-07-31

- TAG: [v1.2.17][1.2.17t]
- COVERAGE: 94.10% -- 4225/4490 lines in 28 files
- BRANCH COVERAGE: 76.58% -- 1658/2165 branches in 28 files
- 28.88% documented

### Fixed

- Template branch-target workflows now recover a sole locally sourced
  `Gemfile.lock` with the existing release-safe reset helper before checkout,
  and retry a failed Bundler lock normalization once after recovery.
- Checksum-aware template lock normalization now upgrades Bundler and retries
  once when the active Bundler rejects `--add-checksums`.

## [1.2.16] - 2026-07-31

- TAG: [v1.2.16][1.2.16t]
- COVERAGE: 94.03% -- 4193/4459 lines in 28 files
- BRANCH COVERAGE: 76.46% -- 1634/2137 branches in 28 files
- 28.88% documented

### Fixed

- Configured per-member branch-target workflows now preserve the parent
  family's local dependency root, preventing sibling local gems from resolving
  beneath the target member checkout.

## [1.2.15] - 2026-07-31

- TAG: [v1.2.15][1.2.15t]
- COVERAGE: 94.03% -- 4192/4458 lines in 28 files
- BRANCH COVERAGE: 76.46% -- 1634/2137 branches in 28 files
- 28.88% documented

### Fixed

- Family-owned release OTP lookups now render as structured secret-provider
  progress events, including a visible `👀 🔒` authorization prompt cue, instead
  of printing loose MFA status lines through the release tape.

## [1.2.14] - 2026-07-31

- TAG: [v1.2.14][1.2.14t]
- COVERAGE: 94.22% -- 4175/4431 lines in 28 files
- BRANCH COVERAGE: 76.69% -- 1622/2115 branches in 28 files
- 28.88% documented

### Added

- Release publish/build commands now write per-member transcript logs under
  `tmp/kettle-family/release-*`, and failure summaries include the log path.

- Release progress now renders child `kettle-release` `remote_parity` events,
  keeping remote fetch, skip, failure, and completion activity visible without
  scraping raw command output.

- Release progress now renders child `kettle-release` `ci_monitor` events with
  provider and workflow or pipeline context, so CI activity is visible as
  structured progress.

- Release progress now renders child `kettle-release` `pre_release` events, so
  pre-release checks are visible as structured progress while raw output stays
  in the transcript log.

- Release progress now renders child `kettle-changelog` `changelog` events, so
  release plan, coverage, and changelog update activity is visible as structured
  progress.

### Changed

- Family release now keeps raw child `kettle-release` output in the per-member
  transcript log by default and renders structured NDJSON progress in the
  terminal, with raw passthrough still available under verbose/debug output.
- Release summary footers now include the transcript log directory when release
  logs were written, including successful runs where raw output stayed quiet.
- Release progress now renders child `command_step` summaries, so phases can
  show context such as `release:bundle_lock:Gemfile` or
  `release:yard:documentation`.
- Release progress now renders child `release_lockfile` and `release_probe`
  events, so lockfile reset retries and published-gem availability probes show
  as structured progress.
- Release progress now renders GitHub CI wait/start/tick events with completion
  counts, so CI monitoring no longer appears stuck while waiting for workflows.
- Release preflight now renders through the shared progress event tape instead
  of printing separate start and finish lines for each successful phase.

### Fixed

- Release preflight no longer prints a nested 1Password authorization alert
  between the phase start and finish lines; the preflight phase itself is the
  user-facing authorization notice.

- Family release runs can now pass configured required release remotes through
  to `kettle-release`, allowing mirrors to remain optional while primary remotes
  still block release parity failures.

## [1.2.13] - 2026-07-31

- TAG: [v1.2.13][1.2.13t]
- COVERAGE: 94.09% -- 4043/4297 lines in 28 files
- BRANCH COVERAGE: 76.48% -- 1538/2011 branches in 28 files
- 28.84% documented

### Fixed

- Family publish runs now keep release secrets provider interaction in
  `kettle-family` by default, so `--secrets-provider` no longer gets passed down
  to child `kettle-release` commands unless the configured publish command
  explicitly includes it.

- Family release progress now renders child `kettle-release` `secret_provider`
  events, keeping keepalive and prompt-response activity visible when a release
  command emits NDJSON.

- `kettle-family state` now queries `kettle-jem` transfer changelog totals
  outside the active bundle when the root bundle does not include `kettle-jem`,
  so the transfer lag column header can show the real total instead of `T(?)`.

- `kettle-family` local development bundles now localize `kettle-dev`'s direct
  sibling runtime dependencies when `KETTLE_DEV_DEV` is enabled, so unreleased
  floors such as `kettle-ndjson >= 0.1.4` resolve during family development.

- Release dry-runs now stop after planned lockfile normalization when a member
  has local path remotes, avoiding a false readiness failure on lockfiles that
  would be normalized under `--execute`.

- Release state now reads kettle-jem transfer changelog replay cursors from
  `.structuredmerge/kettle-jem.lock`, so `T(n)` reports actual lag instead of
  treating every member as missing all transfer changelogs.

- `kettle-family state` now labels the transfer changelog column as `T(n)`,
  where `n` is the total transfer changelog count and row values are the lag
  after each member's stored replay cursor.

- `kettle-family state` now uses an ASCII `^ / v` ahead/behind column header so
  terminal table alignment is stable in monospace output.

- Text reports now repeat the command context in the final summary footer so the
  command, family, mode, config, order, and release target details remain visible
  after long runs.

- Failed streamed release commands now report the last useful output line when
  no explicit failure marker is present, avoiding empty `output omitted`
  summaries for Bundler boot failures.

- Template execution now aligns stale managed `nomono` Gemfile floors and
  lockfiles before member bundles run, avoiding already-activated `nomono`
  conflicts during family templating.

- `kettle-family` now loads `kettle-dev` through its public entrypoint instead
  of direct nested implementation files.

- Command summaries now include total elapsed wall time in the final footer.

- Parent-owned RubyGems MFA lookup failures during release now fall back to
  manual OTP entry when possible, and otherwise fail the member cleanly instead
  of escaping from a worker thread with a misleading release summary.

- Dependency-floor CI bundle validation now recognizes workflow `env:
  BUNDLE_GEMFILE` entries, including `${{ github.workspace }}` paths, so
  release waves wait for just-published floors before pushing dependent CI
  workflows that install through setup-ruby-flash.

## [1.2.12] - 2026-07-30

- TAG: [v1.2.12][1.2.12t]
- COVERAGE: 93.90% -- 3846/4096 lines in 27 files
- BRANCH COVERAGE: 76.54% -- 1475/1927 branches in 27 files
- 27.83% documented

### Fixed

- Publish release skip checks now use `kettle-dev`'s shared RubyGems version
  cache instead of a direct `gem.coop` HTTP request, matching the cached
  release-state path used by `kettle-family state`.

- Family release dependency-floor readiness now validates CI-facing direct
  appraisal Gemfiles, so generated workflows such as `dep-heads.yml` cannot fail
  after a just-published family dependency was only checked through release
  lockfiles.

## [1.2.11] - 2026-07-30

- TAG: [v1.2.11][1.2.11t]
- COVERAGE: 93.78% -- 3784/4035 lines in 27 files
- BRANCH COVERAGE: 76.34% -- 1452/1902 branches in 27 files
- 27.83% documented

### Added

- Release execution now prints a parent-process intent summary, a configurable
  countdown, and visible release preflight progress before member release work
  starts.

### Changed

- Releases using a configured secrets provider now authorize that provider as
  the first release preflight phase, making 1Password approval prompts appear
  before slower checks can consume operator attention.

## [1.2.10] - 2026-07-30

- TAG: [v1.2.10][1.2.10t]
- COVERAGE: 94.00% -- 3698/3934 lines in 27 files
- BRANCH COVERAGE: 76.24% -- 1409/1848 branches in 27 files
- 28.01% documented

### Fixed

- Shared-root changelog release phases now collect coverage from the family root
  bundle, preserving aggregate monorepo coverage stats while keeping
  `kettle-changelog` execution inside a member gem.

## [1.2.9] - 2026-07-30

- TAG: [v1.2.9][1.2.9t]
- COVERAGE: 94.00% -- 3698/3934 lines in 27 files
- BRANCH COVERAGE: 76.24% -- 1409/1848 branches in 27 files
- 28.01% documented

### Fixed

- Shared-root changelog release phases now run `kettle-changelog` inside the
  member gem that owns the configured shared version file, while passing the
  root changelog path explicitly.

## [1.2.8] - 2026-07-29

- TAG: [v1.2.8][1.2.8t]
- COVERAGE: 93.98% -- 3652/3886 lines in 27 files
- BRANCH COVERAGE: 76.43% -- 1394/1824 branches in 27 files
- 28.01% documented

### Fixed

- Monorepo `kettle-family template` now runs local `kettle-jem` through its
  checked-out `exe/kettle-jem` when `STRUCTUREDMERGE_DEV` points at a local
  stack, avoiding transient RubyGems executable wrapper failures during highly
  parallel templating.
- Deferred monorepo template commits now hold the same shared Git operation lock
  passed to `kettle-jem`, preventing `.git/index.lock` races with member
  templating Git preflight checks.
- `kettle-family bup` and `bupb` now disable family local-path envs even when
  `release.env` already sets those keys to false, avoiding leaked monorepo roots
  such as `STRUCTUREDMERGE_DEV=/path/to/family/root` during bundle updates.
- Family local-path env injection now defaults to `members_root` when no
  explicit `family.local_path_root` is configured, matching monorepo families
  whose sibling gems live under a subdirectory such as `gems/`.

## [1.2.7] - 2026-07-29

- TAG: [v1.2.7][1.2.7t]
- COVERAGE: 93.98% -- 3650/3884 lines in 27 files
- BRANCH COVERAGE: 76.43% -- 1394/1824 branches in 27 files
- 28.01% documented

### Fixed

- `kettle-family bup`, `bupb`, and release lockfile handling now treat truthy
  `*_DEV` and `*_LOCAL` environment values as local path dependency mode, so
  family local path envs such as `STRUCTUREDMERGE_DEV=true` are disabled for
  release-style bundle refreshes.

## [1.2.6] - 2026-07-29

- TAG: [v1.2.6][1.2.6t]
- COVERAGE: 94.00% -- 3649/3882 lines in 27 files
- BRANCH COVERAGE: 76.43% -- 1391/1820 branches in 27 files
- 28.01% documented

## [1.2.5] - 2026-07-29

- TAG: [v1.2.5][1.2.5t]
- COVERAGE: 94.00% -- 3649/3882 lines in 27 files
- BRANCH COVERAGE: 76.43% -- 1391/1820 branches in 27 files
- 28.01% documented

### Fixed

- `kettle-family template` now defers `kettle-jem` bootstrap commits for
  executed monorepo templating and runs a serialized member-scoped
  `commit_template` phase, avoiding parallel `.git/index.lock` races when many
  members share one Git repository.

- kettle-jem-template-20260730-001 - Gemspec package file enumeration now runs
  relative to the gemspec directory, so packaged template assets are included
  even when the gemspec is loaded from another working directory.

## [1.2.4] - 2026-07-29

- TAG: [v1.2.4][1.2.4t]
- COVERAGE: 93.92% -- 3629/3864 lines in 27 files
- BRANCH COVERAGE: 76.22% -- 1378/1808 branches in 27 files
- 28.01% documented

### Added

- kettle-jem-template-20260729-005 - Gemspec metadata now publishes this
  project's RubyForum tag as `mailing_list_uri`, and support docs link to the
  tagged RubyForum community alongside Discord.

### Fixed

- Family release changelog phases now pass `--yes` to configured
  `kettle-changelog` commands by default, matching child `kettle-release`
  behavior and keeping publish runs non-interactive unless `--no-accept` is
  used.

- kettle-jem-template-20260728-003 - Generated dep-heads workflows now run
  TruffleRuby jobs with current RubyGems and Bundler, avoiding setup failures
  before the test suite starts.
- kettle-jem-template-20260728-004 - Generated dep-heads workflows now use the
  setup-ruby Bundler install path for direct appraisal Gemfiles, avoiding rv
  lockfile parser failures on Git and path dependencies.
- kettle-jem-template-20260728-005 - VersionGem bootstrap now creates the
  missing canonical version spec when a project only has shim namespace version
  specs.
- kettle-jem-template-20260729-001 - Generated JRuby 9.4 workflows now use the
  legacy manual bundle install path, avoiding setup-time Bundler full-index
  failures against `gem.coop`.
- kettle-jem-template-20260729-002 - VersionGem bootstrap now preserves
  and templates dedicated `version_gem.rb` entrypoints even when the gemspec
  dependency is intentionally omitted, and generated anonymous-loader specs
  cover both `version.rb` and `version_gem.rb`.
- kettle-jem-template-20260729-003 - Old-Ruby gems below the VersionGem runtime
  floor now get managed minimal `version.rb` files and anonymous-loader version
  specs without adding `version_gem`.

## [1.2.3] - 2026-07-28

- TAG: [v1.2.3][1.2.3t]
- COVERAGE: 93.83% -- 3617/3855 lines in 27 files
- BRANCH COVERAGE: 76.18% -- 1369/1797 branches in 27 files
- 28.01% documented

### Fixed

- `kettle-family template` now removes Bundler-reported stale CHECKSUMS entries
  and retries pre-template lockfile normalization, allowing templating to
  recover from local pre-release checksum drift.
- `kettle-family template` now includes locked template bootstrap gems such as
  `nomono` and `kettle-dev` in pre-template lockfile normalization so legacy
  members can boot current `kettle-jem` preparation before their generated
  templating gemfiles have been refreshed.
- `kettle-family template` now uses `bundle install` for pre-template lockfile
  preparation when a member has no `Gemfile.lock`, instead of running a
  `bundle update` command before the bundle exists.

## [1.2.2] - 2026-07-28

- TAG: [v1.2.2][1.2.2t]
- COVERAGE: 93.87% -- 3569/3802 lines in 27 files
- BRANCH COVERAGE: 76.29% -- 1345/1763 branches in 27 files
- 28.10% documented

### Fixed

- `kettle-family template` now runs the `kettle-jem prepare` phase through the
  same member bundle shape as `kettle-jem install`, so local template-stack
  overrides are honored during preparation.
- Failed template preparation event streams are now summarized instead of being
  dumped raw into the final text report.

## [1.2.1] - 2026-07-28

- TAG: [v1.2.1][1.2.1t]
- COVERAGE: 93.86% -- 3561/3794 lines in 27 files
- BRANCH COVERAGE: 76.24% -- 1341/1759 branches in 27 files
- 28.10% documented

### Fixed

- `kettle-family reset Gemfile.lock` now launches `kettle-reset` outside each
  member bundle, so it can repair lockfiles that reference uninstalled
  unreleased dependency versions.

## [1.2.0] - 2026-07-27

- TAG: [v1.2.0][1.2.0t]
- COVERAGE: 93.85% -- 3557/3790 lines in 27 files
- BRANCH COVERAGE: 76.15% -- 1338/1757 branches in 27 files
- 28.20% documented

### Added

- `kettle-family reset Gemfile.lock` now resets selected member lockfiles with
  local sibling paths disabled and repairs missing checksum entries by updating
  the affected released gems.

- `kettle-family release` can now use an opt-in `1password` release secrets
  provider to load the gem signing passphrase and RubyGems MFA OTP from the
  local `op` CLI during executed publish flows.

- `kettle-family clean-unreleased` now scans installed versions of selected
  family gems and can uninstall local versions newer than each gem's latest
  released version, helping recover from failed local release attempts that
  leave unpublished gems installed.

- kettle-jem-template-20260726-001 - Projects now include YARD lint
  configuration and documentation dependencies so documentation issues fail
  before generated docs are refreshed.

- kettle-jem-template-20260727-001 - Spec harness documentation now lists the
  RSpec helpers provided by `kettle-test`.

### Changed

- Templating and release progress rows now show a scheduled family-step counter
  and per-member elapsed timer, making parallel family runs easier to scan.

- `kettle-family reset Gemfile.lock` now delegates to each member's
  `kettle-reset release-lockfiles`, keeping `Gemfile.lock` and
  `Appraisal.root.gemfile.lock` reset semantics aligned with `kettle-release`.

- Explicit `members.roots` lists now remain open to member discovery by default:
  newly discovered gems are included in family operations and reported as
  unlisted until the config is updated. Set `members.discover: false` to operate
  only on configured members.
- The `kettle-family` executable startup header is now shown only when
  `--verbose` is passed; `-v` and `--version` still print just the executable
  version and exit.
- README release guidance now documents release secrets provider overrides,
  release-state columns, default `--only` filters, JSON reports, and
  unreleased-gem cleanup recovery.
- Release secrets now use the shared `kettle-dev` provider implementation;
  family publish runs cache the signing passphrase once and let child
  `kettle-release` processes fetch RubyGems OTP values directly.
- Family publish runs now pass `--yes` to child `kettle-release` commands by
  default, so release-owned confirmation prompts are approved explicitly instead
  of being answered by terminal prompt detection.

- GitHub workflows now use the setup-ruby-flash revision that supports
  appraisal-only setup without installing the main Gemfile bundle.

- kettle-jem-template-20260728-001 - Generated Ruby workflows now use clearer
  setup-ruby-flash planning and can prepare appraisal-only jobs without
  installing the main Gemfile bundle.

### Fixed

- RuboCop Gradual now ignores gems installed under `gemfiles/vendor/bundle`,
  preventing vendored dependency source from being treated as project lint debt.

- Family releases now pass configured 1Password CLI paths through to child
  `kettle-release` processes and derive direct secret handoff from normalized
  provider config instead of parsing equivalent command-line spellings.

- Family release secrets now preserve `Kettle::Family::Error` failures when the
  shared `kettle-dev` provider reports 1Password lookup errors.

- Template summaries now count unique changed files from kettle-jem event
  streams instead of adding duplicate per-phase summary counts.
- Family release lockfile refreshes now disable the generated local-path
  toggles used by member Gemfiles, reject lockfile refreshes that still write
  path sources, and re-normalize lockfiles before family-managed release pushes.

- kettle-jem-template-20260726-002 - Generated version files now document their
  version namespace and constants, reducing warning-only YARD lint output.

- kettle-jem-template-20260726-003 - Coverage upload steps now treat Coveralls,
  QLTY, and Codecov as optional, so provider outages do not fail CI when local
  coverage thresholds still pass.

- kettle-jem-template-20260728-002 - Generated RuboCop configs now ignore the
  same `gemfiles/vendor/bundle` tree as `.gitignore`, so vendored dependency
  installs are not reported as project lint debt.

## [1.1.9] - 2026-07-25

- TAG: [v1.1.9][1.1.9t]
- COVERAGE: 95.23% -- 3197/3357 lines in 25 files
- BRANCH COVERAGE: 77.20% -- 1192/1544 branches in 25 files
- 28.16% documented

### Added

- `kettle-family state` now marks mismatched GitHub release tags and reports
  kettle-jem transfer changelog replay lag in a `T📰` column.

### Changed

- Bare `kettle-family bump` now defaults to `--only bump`, and bare
  `kettle-family release` now defaults to `--only pending`.

- kettle-jem-template-20260725-002 - Generated gemspec templates now include
  `anonymous_loader` as a development dependency, and version specs use it to
  execute generated `version.rb` files for coverage without redefining package
  constants. Managed version specs are removed when `version_gem` is disabled
  or incompatible with the project's runtime Ruby floor.

### Fixed

- Monorepo templating now passes a shared Git operation lock to `kettle-jem`,
  allowing template workers to serialize repo-wide Git config/index mutations
  instead of only bootstrap commits.

## [1.1.8] - 2026-07-25

- TAG: [v1.1.8][1.1.8t]
- COVERAGE: 95.48% -- 3147/3296 lines in 25 files
- BRANCH COVERAGE: 77.42% -- 1169/1510 branches in 25 files
- 28.26% documented

### Added

- `kettle-family state` now reports the latest GitHub release tag in a `GH.rel`
  column next to the local, changelog, and RubyGems version columns.

## [1.1.7] - 2026-07-25

- TAG: [v1.1.7][1.1.7t]
- COVERAGE: 95.52% -- 3113/3259 lines in 25 files
- BRANCH COVERAGE: 77.50% -- 1147/1480 branches in 25 files
- 28.26% documented

### Fixed

- Release and template orchestration now consume NDJSON event lines even when
  progress rendering is disabled, preventing raw `--events` payloads from
  leaking into interactive terminal output.
- TTY workflow progress now clamps member status text and summarizes structured
  diagnostics, preventing long event payloads from wrapping rows and corrupting
  multi-member progress displays.
- Automated lockfile, bundle-update, and workflow-pin commits now use the
  gitmoji grapheme accepted by generated commit hooks.

## [1.1.6] - 2026-07-25

- TAG: [v1.1.6][1.1.6t]
- COVERAGE: 95.19% -- 3084/3240 lines in 25 files
- BRANCH COVERAGE: 76.80% -- 1132/1474 branches in 25 files
- 28.68% documented

### Fixed

- Release summaries now count only members that reached a release terminal
  phase as succeeded, so dependency-floor side effects do not appear as
  published gems after an earlier failure.
- Dependency-floor lockfile refresh now uses checksum-aware Bundler locking
  (`bundle lock --update ... --add-checksums`) before validating just-published
  sibling floors, so missing or empty checksum entries still retry and fail
  instead of being accepted.
- Interactive release commands now suppress consumed `kettle-release --events`
  NDJSON lines from terminal output while keeping them captured for progress and
  failure summaries.

### Changed

- kettle-jem-template-20260725-001 - Generated JRuby and TruffleRuby workflow
  files now run when pull request head branches start with `feature/release`,
  so release CI monitoring does not report intentionally skipped engine
  workflows as failures.

## [1.1.5] - 2026-07-25

- TAG: [v1.1.5][1.1.5t]
- COVERAGE: 94.64% -- 3021/3192 lines in 25 files
- BRANCH COVERAGE: 76.45% -- 1110/1452 branches in 25 files
- 28.68% documented

### Added

- Release orchestration now passes `--events` through to `kettle-release` and
  maps release NDJSON events into the family progress display.

### Changed

- kettle-jem-template-initial - Initial templating by kettle-jem.

### Fixed

- Failed release command reports now summarize release NDJSON diagnostics and
  final status instead of dumping the raw event stream into the human report.

## [1.1.4] - 2026-07-24

- TAG: [v1.1.4][1.1.4t]
- COVERAGE: 94.56% -- 2972/3143 lines in 25 files
- BRANCH COVERAGE: 76.69% -- 1076/1403 branches in 25 files
- 28.68% documented

### Fixed

- Dependency floor propagation after a sibling release now retries
  `bundle update <released-gem>` before committing floor changes, so dependents
  wait for Bundler to install the just-published gem and write valid lockfile
  checksums.

## [1.1.3] - 2026-07-23

- TAG: [v1.1.3][1.1.3t]
- COVERAGE: 94.44% -- 2987/3163 lines in 25 files
- BRANCH COVERAGE: 76.40% -- 1078/1411 branches in 25 files
- 28.68% documented

### Fixed

- No-config single-member templating no longer injects a synthetic family-local
  path environment pointing at the member root.
- Template and release progress now keep each member locked to its own TTY row
  while parallel workers report events out of order.

## [1.1.2] - 2026-07-23

- TAG: [v1.1.2][1.1.2t]
- COVERAGE: 94.42% -- 2961/3136 lines in 25 files
- BRANCH COVERAGE: 76.31% -- 1060/1389 branches in 25 files
- 28.68% documented

### Fixed

- Release workflows now automatically normalize `Gemfile.lock` before readiness
  when a selected member lockfile contains local path remotes.
- `bump` summaries now list successfully bumped members instead of reporting
  `succeeded: none`.

## [1.1.1] - 2026-07-23

- TAG: [v1.1.1][1.1.1t]
- COVERAGE: 94.41% -- 2954/3129 lines in 25 files
- BRANCH COVERAGE: 76.28% -- 1058/1387 branches in 25 files
- 28.68% documented

### Fixed

- `bup` / `bupb` now run bundle updates with local sibling path environments
  disabled and refuse to auto-commit lockfiles containing local path remotes.

## [1.1.0] - 2026-07-23

- TAG: [v1.1.0][1.1.0t]
- COVERAGE: 94.37% -- 2934/3109 lines in 25 files
- BRANCH COVERAGE: 76.29% -- 1049/1375 branches in 25 files
- 28.68% documented

### Changed

- `kettle-family state` now includes a `bump` boolean column, documents the
  boolean release-state columns above the table, and accepts `--only bump` to
  select members with unreleased changes whose `V.rb` still matches `V.rel`.
- `--only` release-state filters now accept the short table column names
  `unrel`, `prep`, and `pend` in addition to `unreleased`, `prepared`, and
  `pending`.
- The `kettle-family` executable now supports `-v` / `--version` and prints a
  standard startup header on normal runs.
- Template and release workflows now use `tty-progressbar`-backed multi-line
  member progress in normal TTY output, with kettle-jem NDJSON marks rendered
  as a fixed-width sliding event tape instead of dots or raw event dumps.

## [1.0.6] - 2026-07-23

- TAG: [v1.0.6][1.0.6t]
- COVERAGE: 94.43% -- 2781/2945 lines in 24 files
- BRANCH COVERAGE: 76.66% -- 982/1281 branches in 24 files
- 29.23% documented

### Fixed

- Monorepo templating now passes a shared `kettle-jem` git commit lock so
  parallel member templating no longer races while updating `HEAD`.

## [1.0.5] - 2026-07-23

- TAG: [v1.0.5][1.0.5t]
- COVERAGE: 94.41% -- 2772/2936 lines in 24 files
- BRANCH COVERAGE: 76.59% -- 978/1277 branches in 24 files
- 29.23% documented

### Fixed

- Family releases now retry `bundle update` for dependent members after
  wave-aware dependency floor bumps, and reject empty lockfile checksum entries
  for the just-published gems, so a registry version endpoint becoming visible
  before Bundler's dependency index no longer breaks the next publish.
- Failed interactive release results now summarize streamed command output
  instead of replaying the full child-process transcript in the final report.
- `kettle-family state` now reports per-gem release-state rows for monorepos
  that use a shared root changelog, while still preferring member-local
  changelogs when present and retaining branch-stack release-state output.

## [1.0.4] - 2026-07-21

- TAG: [v1.0.4][1.0.4t]
- COVERAGE: 95.68% -- 2726/2849 lines in 24 files
- BRANCH COVERAGE: 77.97% -- 952/1221 branches in 24 files
- 28.68% documented

### Fixed

- `kettle-family release --publish` now skips already-published members with no
  unreleased changes even when post-release commits leave HEAD ahead of the
  release tag, allowing later pending members to continue.

## [1.0.3] - 2026-07-21

- TAG: [v1.0.3][1.0.3t]
- COVERAGE: 95.61% -- 2724/2849 lines in 24 files
- BRANCH COVERAGE: 77.97% -- 952/1221 branches in 24 files
- 28.68% documented

### Changed

- `kettle-family release-state` text tables now use compact column headings and
  truncate checkout branch names to 10 characters.

### Fixed

- `kettle-family release` now builds release waves from gemspec development
  dependencies and literal Gemfile dependencies, including dependencies in
  modular Gemfiles loaded with `eval_gemfile`, so development-tooling releases
  unblock dependent member releases before the next wave starts.

- `kettle-family bump` now rewrites exact family dependency pins according to
  release-wave order, so earlier members are not changed to require unreleased
  later member versions.

## [1.0.2] - 2026-07-21

- TAG: [v1.0.2][1.0.2t]
- COVERAGE: 95.51% -- 2637/2761 lines in 23 files
- BRANCH COVERAGE: 77.98% -- 928/1190 branches in 23 files
- 28.63% documented

### Added

- `kettle-family template` now passes family-level `readme.corporate_sponsors`
  config into member `kettle-jem` runs for template-managed README sponsor logos.
- `kettle-family state` is now an alias for `kettle-family release-state`.
- `kettle-family sync` now fetches the remote default branch, rebases the local
  default branch onto it, then rebases the original checked-out branch onto the
  updated local default branch.

### Changed

- `kettle-family release-state` now reports the checked-out branch and displays
  release distance as local/remote ahead and behind counts.
- kettle-jem-template-20260720-001 - Generated READMEs can now render
  template-managed corporate sponsor logos from project or family config.
- kettle-jem-template-20260720-002 - Generated development Gemfiles now use the
  released `tree_sitter_language_pack` gem 1.13.3 or newer by default.
- kettle-jem-template-20260720-003 - Generated StructuredMerge Git diff driver
  config now uses the installed `smorg-rb` Ruby driver name.
- kettle-jem-template-20260720-004 - Generated multi-engine workflow files now
  omit JRuby and TruffleRuby jobs when project config declares MRI-only engines.
- kettle-jem-template-20260720-005 - Generated README Support & Community rows
  now include a RubyForum help badge.

### Fixed

- Default member discovery now excludes benchmark fixture gemspecs so benchmark
  projects are not treated as install/template/release family members.
- `kettle-family template` now keeps non-verbose `kettle-jem --events` progress
  compact and omits raw NDJSON event streams from failed text reports.
- Generated HEAD and runtime dependency HEAD CI workflows no longer include
  JRuby or TruffleRuby jobs for this MRI-only gem.

## [1.0.1] - 2026-07-20

- TAG: [v1.0.1][1.0.1t]
- COVERAGE: 95.44% -- 2534/2655 lines in 23 files
- BRANCH COVERAGE: 77.89% -- 877/1126 branches in 23 files
- 29.10% documented

### Added

- `kettle-family release-state` now includes an `ahead` column counting commits
  from the latest release tag to the local default branch when available.
- `kettle-family release` now accepts `--skip-remotes` and forwards the
  comma-separated remote skip list to member `kettle-release` runs.
- `kettle-family --only` now accepts release-state tokens `unreleased`,
  `prepared`, and `pending`; multiple tokens are combined with logical AND.
- `kettle-family template` now accepts `--verbose` and forwards verbose mode to
  member `kettle-jem` runs instead of forcing quiet JSON output.

- `kettle-family template` now runs `kettle-jem prepare` before full templating
  for Kettle Jem-powered members so templating-only dependency bootstraps, such
  as parser packages, are available before the full template command loads.

- `kettle-family template` now uses `kettle-jem --events` as its default
  templating interface, including verbose and single-job runs, and streams
  newline-delimited JSON template phase, recipe, post-apply, command-step,
  diagnostic, and summary events as member-prefixed progress lines.

### Deprecated

- `kettle-family bump-version` is now deprecated in favor of `kettle-family bump`.

### Fixed

- The templating prepare phase now disables only the implicit family local path
  environment variable unless it was explicitly provided, avoiding stale local
  Gemfile activation failures before the prepare payload can refresh generated
  modular Gemfiles.
- The templating prepare phase now runs outside each member's Bundler context so
  it can repair stale generated Gemfiles before Bundler evaluates them.

- `kettle-family` template preparation now handles custom non-`kettle-jem`
  template commands without treating no-op dependency preparation as failure.
- `kettle-family release-state` now counts `ahead` from the release tag to the
  checked-out member `HEAD`.
- Generated docs now retain the YARD `_index.html` content wrapper after
  regeneration with the shared YARD postprocessing stack.

## [1.0.0] - 2026-07-17

- TAG: [v1.0.0][1.0.0t]
- COVERAGE: 95.22% -- 2370/2489 lines in 23 files
- BRANCH COVERAGE: 76.87% -- 801/1042 branches in 23 files
- 29.29% documented

### Added

- `kettle-family release` now accepts `--ci-workflows` and forwards the
  comma-separated workflow subset to member `kettle-release` runs.

### Changed

- Promoted the gems that provide built-in `kettle-family` workflow commands to
  runtime dependencies: `kettle-dev` for release/changelog/SHA-pin/version
  tooling and `kettle-test` for test runs.
- Moved the `kettle-jem` templating provider to the templating Gemfile while
  the next `kettle-jem` release depends on unreleased `kettle-family` fixes.
- Raised the runtime Ruby floor to 4.0.0.

- kettle-jem-template-20260716-001 - Shim gemspec manifests now include
  `LICENSE.md` instead of nonexistent `LICENSE.txt`.
- kettle-jem-template-20260716-002 - Generated gemspec manifests now ship fewer
  repository-only files by default to reduce downstream distro packaging churn.

### Fixed

- Root-mode family changelog release commands now pass the configured family
  name to `kettle-changelog`, allowing shared root changelogs to run from
  repositories that do not have a root gemspec.
- `kettle-family bump-version` now recognizes exact same-version family
  dependencies written as `= #{spec.version}` instead of failing with a
  misleading ambiguous dependency error.
- `kettle-family release --ci-workflows` now validates workflow names before
  forwarding them to shell-backed `kettle-release` commands.

## [0.2.7] - 2026-07-15

- TAG: [v0.2.7][0.2.7t]
- COVERAGE: 95.20% -- 2342/2460 lines in 23 files
- BRANCH COVERAGE: 76.92% -- 780/1014 branches in 23 files
- 29.29% documented

### Fixed

- Family release now waits for just-published prerequisite family gems to appear
  in the gem server registry before continuing dependent lockfile normalization
  and release steps.

## [0.2.6] - 2026-07-14

- TAG: [v0.2.6][0.2.6t]
- COVERAGE: 95.14% -- 2311/2429 lines in 23 files
- BRANCH COVERAGE: 76.75% -- 769/1002 branches in 23 files
- 29.54% documented

### Fixed

- Command runner child processes now use a per-child unbundled environment
  instead of mutating global `ENV`, avoiding threaded release crashes on
  TruffleRuby.
- Family release commands no longer receive the implicit family local path
  environment variable by default, preventing `kettle-release` from committing
  sibling path sources into release lockfiles.

## [0.2.5] - 2026-07-11

- TAG: [v0.2.5][0.2.5t]
- COVERAGE: 95.22% -- 2309/2425 lines in 23 files
- BRANCH COVERAGE: 76.75% -- 766/998 branches in 23 files
- 29.54% documented

### Added

- Family workflows now inject a derived local family path environment variable
  by default, such as `RUBY_OAUTH_DEV=/path/to/ruby-oauth`, so in-flight family
  members can resolve unreleased sibling gems during orchestration.
- Family configs now expose `pre_release.image_url_skip_patterns` and pass the
  active config path to release commands so `kettle-pre-release` can skip
  project-specific volatile image URLs.
- `kettle-family release --skip-bundle-audit` now forwards
  `--skip-bundle-audit` and `KETTLE_DEV_SKIP_BUNDLE_AUDIT=true` to downstream
  `kettle-release` commands.

### Changed

- `require "kettle/family"` no longer loads `version_gem` by default; require
  `kettle/family/version_gem` for the optional `VersionGem::Basic` extension.
- Release lockfile normalization now forces configured local path environment
  variables off after caller overrides so release locks are cleaned
  deterministically.

## [0.2.4] - 2026-07-04

- TAG: [v0.2.4][0.2.4t]
- COVERAGE: 95.33% -- 2288/2400 lines in 22 files
- BRANCH COVERAGE: 76.42% -- 752/984 branches in 22 files
- 30.04% documented

### Added

- Family releases now raise downstream family dependency floors after each
  member release by default, with `--no-auto-floors` and
  `release.auto_dependency_floors: false` opt-outs.

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

[Unreleased]: https://github.com/kettle-dev/kettle-family/compare/v1.2.20...HEAD
[1.2.20]: https://github.com/kettle-dev/kettle-family/compare/v1.2.19...v1.2.20
[1.2.20t]: https://github.com/kettle-dev/kettle-family/releases/tag/v1.2.20
[1.2.19]: https://github.com/kettle-dev/kettle-family/compare/v1.2.18...v1.2.19
[1.2.19t]: https://github.com/kettle-dev/kettle-family/releases/tag/v1.2.19
[1.2.18]: https://github.com/kettle-dev/kettle-family/compare/v1.2.17...v1.2.18
[1.2.18t]: https://github.com/kettle-dev/kettle-family/releases/tag/v1.2.18
[1.2.17]: https://github.com/kettle-dev/kettle-family/compare/v1.2.16...v1.2.17
[1.2.17t]: https://github.com/kettle-dev/kettle-family/releases/tag/v1.2.17
[1.2.16]: https://github.com/kettle-dev/kettle-family/compare/v1.2.15...v1.2.16
[1.2.16t]: https://github.com/kettle-dev/kettle-family/releases/tag/v1.2.16
[1.2.15]: https://github.com/kettle-dev/kettle-family/compare/v1.2.14...v1.2.15
[1.2.15t]: https://github.com/kettle-dev/kettle-family/releases/tag/v1.2.15
[1.2.14]: https://github.com/kettle-dev/kettle-family/compare/v1.2.13...v1.2.14
[1.2.14t]: https://github.com/kettle-dev/kettle-family/releases/tag/v1.2.14
[1.2.13]: https://github.com/kettle-dev/kettle-family/compare/v1.2.12...v1.2.13
[1.2.13t]: https://github.com/kettle-dev/kettle-family/releases/tag/v1.2.13
[1.2.12]: https://github.com/kettle-dev/kettle-family/compare/v1.2.11...v1.2.12
[1.2.12t]: https://github.com/kettle-dev/kettle-family/releases/tag/v1.2.12
[1.2.11]: https://github.com/kettle-dev/kettle-family/compare/v1.2.10...v1.2.11
[1.2.11t]: https://github.com/kettle-dev/kettle-family/releases/tag/v1.2.11
[1.2.10]: https://github.com/kettle-dev/kettle-family/compare/v1.2.9...v1.2.10
[1.2.10t]: https://github.com/kettle-dev/kettle-family/releases/tag/v1.2.10
[1.2.9]: https://github.com/kettle-dev/kettle-family/compare/v1.2.8...v1.2.9
[1.2.9t]: https://github.com/kettle-dev/kettle-family/releases/tag/v1.2.9
[1.2.8]: https://github.com/kettle-dev/kettle-family/compare/v1.2.7...v1.2.8
[1.2.8t]: https://github.com/kettle-dev/kettle-family/releases/tag/v1.2.8
[1.2.7]: https://github.com/kettle-dev/kettle-family/compare/v1.2.6...v1.2.7
[1.2.7t]: https://github.com/kettle-dev/kettle-family/releases/tag/v1.2.7
[1.2.6]: https://github.com/kettle-dev/kettle-family/compare/v1.2.5...v1.2.6
[1.2.6t]: https://github.com/kettle-dev/kettle-family/releases/tag/v1.2.6
[1.2.5]: https://github.com/kettle-dev/kettle-family/compare/v1.2.4...v1.2.5
[1.2.5t]: https://github.com/kettle-dev/kettle-family/releases/tag/v1.2.5
[1.2.4]: https://github.com/kettle-dev/kettle-family/compare/v1.2.3...v1.2.4
[1.2.4t]: https://github.com/kettle-dev/kettle-family/releases/tag/v1.2.4
[1.2.3]: https://github.com/kettle-dev/kettle-family/compare/v1.2.2...v1.2.3
[1.2.3t]: https://github.com/kettle-dev/kettle-family/releases/tag/v1.2.3
[1.2.2]: https://github.com/kettle-dev/kettle-family/compare/v1.2.1...v1.2.2
[1.2.2t]: https://github.com/kettle-dev/kettle-family/releases/tag/v1.2.2
[1.2.1]: https://github.com/kettle-dev/kettle-family/compare/v1.2.0...v1.2.1
[1.2.1t]: https://github.com/kettle-dev/kettle-family/releases/tag/v1.2.1
[1.2.0]: https://github.com/kettle-dev/kettle-family/compare/v1.1.9...v1.2.0
[1.2.0t]: https://github.com/kettle-dev/kettle-family/releases/tag/v1.2.0
[1.1.9]: https://github.com/kettle-dev/kettle-family/compare/v1.1.8...v1.1.9
[1.1.9t]: https://github.com/kettle-dev/kettle-family/releases/tag/v1.1.9
[1.1.8]: https://github.com/kettle-dev/kettle-family/compare/v1.1.7...v1.1.8
[1.1.8t]: https://github.com/kettle-dev/kettle-family/releases/tag/v1.1.8
[1.1.7]: https://github.com/kettle-dev/kettle-family/compare/v1.1.6...v1.1.7
[1.1.7t]: https://github.com/kettle-dev/kettle-family/releases/tag/v1.1.7
[1.1.6]: https://github.com/kettle-dev/kettle-family/compare/v1.1.5...v1.1.6
[1.1.6t]: https://github.com/kettle-dev/kettle-family/releases/tag/v1.1.6
[1.1.5]: https://github.com/kettle-dev/kettle-family/compare/v1.1.4...v1.1.5
[1.1.5t]: https://github.com/kettle-dev/kettle-family/releases/tag/v1.1.5
[1.1.4]: https://github.com/kettle-dev/kettle-family/compare/v1.1.3...v1.1.4
[1.1.4t]: https://github.com/kettle-dev/kettle-family/releases/tag/v1.1.4
[1.1.3]: https://github.com/kettle-dev/kettle-family/compare/v1.1.2...v1.1.3
[1.1.3t]: https://github.com/kettle-dev/kettle-family/releases/tag/v1.1.3
[1.1.2]: https://github.com/kettle-dev/kettle-family/compare/v1.1.1...v1.1.2
[1.1.2t]: https://github.com/kettle-dev/kettle-family/releases/tag/v1.1.2
[1.1.1]: https://github.com/kettle-dev/kettle-family/compare/v1.1.0...v1.1.1
[1.1.1t]: https://github.com/kettle-dev/kettle-family/releases/tag/v1.1.1
[1.1.0]: https://github.com/kettle-dev/kettle-family/compare/v1.0.6...v1.1.0
[1.1.0t]: https://github.com/kettle-dev/kettle-family/releases/tag/v1.1.0
[1.0.6]: https://github.com/kettle-dev/kettle-family/compare/v1.0.5...v1.0.6
[1.0.6t]: https://github.com/kettle-dev/kettle-family/releases/tag/v1.0.6
[1.0.5]: https://github.com/kettle-dev/kettle-family/compare/v1.0.4...v1.0.5
[1.0.5t]: https://github.com/kettle-dev/kettle-family/releases/tag/v1.0.5
[1.0.4]: https://github.com/kettle-dev/kettle-family/compare/v1.0.3...v1.0.4
[1.0.4t]: https://github.com/kettle-dev/kettle-family/releases/tag/v1.0.4
[1.0.3]: https://github.com/kettle-dev/kettle-family/compare/v1.0.2...v1.0.3
[1.0.3t]: https://github.com/kettle-dev/kettle-family/releases/tag/v1.0.3
[1.0.2]: https://github.com/kettle-dev/kettle-family/compare/v1.0.1...v1.0.2
[1.0.2t]: https://github.com/kettle-dev/kettle-family/releases/tag/v1.0.2
[1.0.1]: https://github.com/kettle-dev/kettle-family/compare/v1.0.0...v1.0.1
[1.0.1t]: https://github.com/kettle-dev/kettle-family/releases/tag/v1.0.1
[1.0.0]: https://github.com/kettle-dev/kettle-family/compare/v0.2.7...v1.0.0
[1.0.0t]: https://github.com/kettle-dev/kettle-family/releases/tag/v1.0.0
[0.2.7]: https://github.com/kettle-dev/kettle-family/compare/v0.2.6...v0.2.7
[0.2.7t]: https://github.com/kettle-dev/kettle-family/releases/tag/v0.2.7
[0.2.6]: https://github.com/kettle-dev/kettle-family/compare/v0.2.5...v0.2.6
[0.2.6t]: https://github.com/kettle-dev/kettle-family/releases/tag/v0.2.6
[0.2.5]: https://github.com/kettle-dev/kettle-family/compare/v0.2.4...v0.2.5
[0.2.5t]: https://github.com/kettle-dev/kettle-family/releases/tag/v0.2.5
[0.2.4]: https://github.com/kettle-dev/kettle-family/compare/v0.2.3...v0.2.4
[0.2.4t]: https://github.com/kettle-dev/kettle-family/releases/tag/v0.2.4
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
