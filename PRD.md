# Kettle::Family PRD

## Summary

Kettle::Family is a RubyGem that ships reusable command-line tooling for managing a related set of Ruby gems as one operational family. It should replace bespoke workspace scripts with a configurable, tested, gem-installed CLI that can discover member gems, run ordered workflows, enforce safety gates, and produce machine-readable reports.

The initial product should preserve the practical patterns from:

- `rubocop-lts/meta/scripts`: multi-repository version planning, branch-aware release sequencing, dry-run-first publishing, and explicit execution gates.
- `structuredmerge/ruby/workspace-scripts`: dependency-ordered gem discovery, selected family operations, templating, lockfile normalization, readiness checks, version alignment, docs, lint, tests, git push, and release orchestration.

## Problem

The current family-management scripts work, but they are local to specific workspaces and encode project-specific assumptions directly in scripts. That creates several recurring problems:

- Operators must copy or adapt scripts between gem families.
- Family membership and ordering are hard-coded.
- Dry-run, selection, reporting, and safety behavior varies by script.
- Release and templating workflows are difficult to test as product behavior.
- Workflows are not available through a single installed executable.
- There is no shared configuration contract for describing a gem family.

Kettle::Family should make these workflows portable while keeping the current operator-grade safety constraints.

## Goals

- Provide one installed CLI for gem-family operations.
- Support both single-repository workspaces and sibling multi-repository workspaces.
- Discover family members from gemspecs, Git remotes, and/or explicit config.
- Run family workflows in deterministic order.
- Prefer dependency order when local gem dependencies define a valid DAG.
- Support fixed custom order when release order differs from dependency order.
- Provide `--only`, `--start-at`, and future `--exclude` selection controls.
- Default to plan/dry-run behavior for destructive or publishing actions.
- Require explicit `--execute` for operations that publish, push, tag, or mutate multiple repos.
- Emit concise human output and optional JSON reports.
- Keep commands self-contained per repository, especially for `mise exec -C`.
- Preserve release-compatible dependency state by default.
- Make failures resumable through selection controls and structured reports.

## Non-Goals

- Do not replace `kettle-dev`, `kettle-release`, `kettle-changelog`, or `kettle-jem`.
- Do not implement source-code templating directly; call `kettle-jem` or its public Ruby APIs.
- Do not manage arbitrary non-Ruby package ecosystems in the first release.
- Do not introduce a GUI.
- Do not require every family to use a monorepo layout.
- Do not bypass each member gem's own Bundler, mise, git, or release tooling.

## Users

- Gem maintainers managing a family of related Ruby gems.
- Release managers who need ordered, resumable, auditable workflows.
- Template maintainers applying `kettle-jem` across many gems.
- CI maintainers who need repeatable readiness checks for a gem family.

## Primary Use Cases

### Family Discovery

As a maintainer, I can run a command in a workspace and see the member gems Kettle::Family would operate on, including their root paths, gem names, versions, local dependencies, and selected execution order.

### Template All Gems

As a template maintainer, I can run one command to apply `kettle-jem` to every selected family member, optionally normalize lockfiles afterward, and commit the combined result only when the worktree was clean before the run.

### Run Quality Gates

As a maintainer, I can run lint, tests, docs generation, and release-readiness checks across a family with consistent selection and reporting.

### Align Family Versions

As a release manager, I can update all family member `VERSION` constants and exact intra-family gemspec dependency pins to a target version, with `--check`, `--dry-run`, and `--execute` modes.

### Release Family

As a release manager, I can preview or execute a release sequence across selected gems in the correct order, with optional readiness checks, changelog preparation, local-path dependency controls, and resumability from a named member.

### Multi-Repo Branch Releases

As a release manager, I can model a family where one repository has branch lanes and related repositories map to those lanes, then plan bumps/releases without hand-editing scripts.

## Product Surface

The gem should expose an executable:

```sh
kettle-family COMMAND [options]
```

Initial commands:

- `kettle-family discover`
- `kettle-family plan`
- `kettle-family template`
- `kettle-family check`
- `kettle-family test`
- `kettle-family lint`
- `kettle-family docs`
- `kettle-family bump-version VERSION`
- `kettle-family release`
- `kettle-family report`

Command options should be consistent where applicable:

- `--config PATH`
- `--root PATH`
- `--only MEMBER`
- `--start-at MEMBER`
- `--json`
- `--report PATH`
- `--dry-run`
- `--execute`
- `--allow-dirty`
- `--[no-]commit`

## Configuration

The product should support a family config file. Proposed default path:

```text
.kettle-family.yml
```

Open question: also support `.structuredmerge/kettle-family.yml` for projects that prefer StructuredMerge-style config colocation.

The config should describe:

- Family name.
- Workspace mode: `monorepo`, `sibling_repos`, or `explicit`.
- Member discovery roots.
- Explicit members, when discovery is not sufficient.
- Release order override.
- Dependency-order behavior.
- Member-specific command environment.
- Template profile and repository topology defaults.
- Readiness checks and required files.
- Release settings.
- Branch lane mappings for multi-branch families.

Example:

```yaml
family:
  name: structuredmerge-ruby
  mode: monorepo
  members_root: gems

members:
  discover: true
  order:
    mode: dependency
    hints:
      - tree_haver
      - ast-merge
      - kettle-jem

template:
  command: kettle-jem install
  profile: monorepo-subgem-release
  repository_topology: monorepo-subproject
  normalize_lockfiles: true

release:
  default_execute: false
  readiness: true
  changelog: true
  local_path_gems: false
```

## Functional Requirements

### Discovery

- Load member gems from explicit config and/or discovered `*.gemspec` files.
- Validate that each discovered member has one primary gemspec unless config disambiguates it.
- Load gemspec metadata without requiring unrelated local path hacks.
- Discover `lib/**/version.rb` for each member.
- Read local family dependencies from gemspec dependencies.
- Build a dependency graph when possible.
- Detect cycles and report them with actionable member names.
- Support order hints for deterministic sorting.
- Support fixed order for release workflows.

### Selection

- `--only MEMBER` runs exactly one selected member and fails for unknown members.
- `--start-at MEMBER` runs from a selected member through the end of the chosen order.
- Future `--exclude MEMBER` may remove one or more members from a run.
- Selection must be applied after order calculation.
- Empty selections must fail with a clear error.

### Execution

- Commands must run with explicit working directories.
- Prefer `mise exec -C MEMBER_ROOT -- ...` when a member has `mise.toml`.
- Support plain command execution when `mise` is not configured.
- Capture command status, stdout/stderr summaries, elapsed time, and failure reason.
- Stop on first failure by default.
- Future mode may support `--continue-on-failure`.

### Templating

- Call `kettle-jem` through its public CLI or Ruby APIs.
- Support per-family and per-member template profile settings.
- Support repository topology settings.
- Support `--skip-commit` for per-member templating.
- Support one family-level commit when enabled and safe.
- Refuse family-level commit when the relevant worktree is dirty before the run, unless `--allow-dirty` is provided.
- Normalize lockfiles after templating when configured.

### Version Alignment

- Support `bump-version VERSION`.
- Validate target version with `Gem::Version`.
- Optional `--from VERSION` requires every member to currently match.
- Update member `VERSION` constants.
- Update exact intra-family dependency pins.
- Refuse ambiguous dependency requirements unless config allows a strategy.
- Provide `--check`, `--dry-run`, and `--execute`.

### Readiness Checks

- Check required project files.
- Check required release harness files and executable binstubs.
- Check for local path remotes in release lockfiles.
- Check obsolete or legacy config paths.
- Check generated docs presence when configured.
- Check that generated repository URLs match configured/derived repository ownership.
- Report all failures, not just the first.

### Release

- Default to plan-only output.
- Require `--execute` to run release commands.
- Support release order independent from dependency order.
- Support `--only`, `--start-at`, and `--start-step`.
- Support local-path dependency mode only when explicitly enabled.
- Support pre-release readiness checks.
- Support a family/root changelog step.
- Support gem build-only vs publish modes.
- Support optional git push and tag creation, gated by explicit flags.

### Reporting

- Human output should be concise and phase-oriented.
- JSON output should be available through `--json` or `--report PATH`.
- Avoid dumping large JSON reports to stdout by default.
- Reports should include:
  - family name
  - selected members
  - order mode
  - command phases
  - per-member status
  - changed files where available
  - diagnostics
  - elapsed time
  - resumable selection hints

## Safety Requirements

- Never default to publishing, pushing, tagging, or committing across a family.
- Require explicit `--execute` for release and publish actions.
- Require explicit `--commit` or configured commit behavior for family-level commits.
- Refuse multi-repo mutation when selected repos have dirty worktrees, unless `--allow-dirty` is set.
- Never delete or rewrite lockfiles manually.
- Never mutate generated docs except by running the configured generator.
- Preserve each member's own release and template tooling boundaries.
- Keep all scratch/report files under the workspace or member `tmp/` directories.

## UX Requirements

- CLI help must clearly state default dry-run vs execute behavior.
- Every command must print selected members before mutation.
- Every mutating command must print whether it will commit, push, tag, or publish.
- Failures must identify the member, phase, command, working directory, and suggested resume command.
- JSON reports should be stable enough for CI consumption.

## Technical Requirements

- Ruby implementation.
- Use `OptionParser` initially unless a stronger CLI framework becomes necessary.
- Use `Open3` for non-interactive command execution.
- Use `PTY` only for interactive release prompts that require passphrases or OTP.
- Use `Prism` for Ruby source edits where practical.
- Avoid regex-based source edits for Ruby when Prism can identify the node.
- Keep code organized under `Kettle::Family`.
- Provide unit specs for discovery, ordering, config loading, selection, and report generation.
- Provide integration/system specs using temporary fixture gems.

## Task List

Use this checklist to track implementation atomically. Mark items complete only after code, specs, and relevant docs are updated.

### M1: Core Model and Discovery

- [x] Add PRD task list for atomic tracking.
- [x] Add executable entrypoint for `kettle-family`.
- [x] Add config loader for `.kettle-family.yml` and `.structuredmerge/kettle-family.yml`.
- [x] Add member model and gemspec discovery.
- [x] Add dependency graph ordering with cycle errors.
- [x] Add `--only` and `--start-at` selection handling.
- [x] Add JSON/human report model with `--report` support.
- [x] Add `kettle-family discover` and `kettle-family plan`.
- [x] Add fixture coverage for explicit config members.
- [x] Add fixture coverage for fixed order and order hints.
- [x] Add CLI executable integration spec.

### M2: Command Runner and Checks

- [x] Add per-member command runner using explicit working directories.
- [x] Prefer `mise exec -C` when a member has `mise.toml`.
- [x] Add command result model with status, elapsed time, and output summaries.
- [x] Add `check`, `test`, `lint`, and `docs` command skeletons.
- [x] Add readiness checks for required files and binstubs.
- [x] Add release lockfile/local-path checks.
- [x] Add concise failure summaries and resume hints.

### M3: Templating Workflow

- [x] Add `template` command.
- [x] Invoke `kettle-jem` through configured CLI command.
- [x] Support template profile and repository topology env/config.
- [x] Support per-member `--skip-commit` templating.
- [x] Add lockfile normalization hook.
- [x] Add family-level commit safety checks.

### M4: Version Alignment

- [x] Add `bump-version VERSION` command.
- [x] Validate target versions with `Gem::Version`.
- [x] Add `--from VERSION` guard.
- [x] Update member `VERSION` constants.
- [x] Update exact intra-family dependency pins.
- [x] Add `--check`, `--dry-run`, and `--execute` modes.

### M5: Release Workflow

- [x] Add release planning command behavior.
- [x] Add fixed release order support for release workflows.
- [x] Add readiness and changelog phases.
- [x] Add build-only vs publish modes.
- [x] Add safe push/tag gates.

### M6: Multi-Repo and Branch Lanes

- [ ] Add sibling repository workspace mode.
- [ ] Add branch-lane release mappings.
- [ ] Add rubocop-lts-style release bump audit support.


## Milestones

### M1: Core Model and Discovery

- Add config loader.
- Add member discovery.
- Add dependency graph and ordering.
- Add selection handling.
- Add JSON report model.
- Add `kettle-family discover`.

### M2: Command Runner and Checks

- Add per-member command runner.
- Add `check`, `test`, `lint`, and `docs` command skeletons.
- Add readiness checks modeled after StructuredMerge Ruby scripts.
- Add concise reports and failure summaries.

### M3: Templating Workflow

- Add `template` command.
- Integrate with `kettle-jem`.
- Support lockfile normalization.
- Support family-level commit safety.

### M4: Version Alignment

- Add `bump-version`.
- Implement Prism-backed version and dependency edits.
- Add `--check`, `--dry-run`, and `--execute`.

### M5: Release Workflow

- Add release planning and execution.
- Support fixed release order.
- Support readiness and changelog steps.
- Support build-only vs publish.
- Support safe push/tag gates.

### M6: Multi-Repo and Branch Lanes

- Add sibling repository workspace mode.
- Add branch-lane release mapping.
- Add release bump audit support for families like `rubocop-lts`.

## Success Metrics

- A StructuredMerge Ruby family workflow can be expressed without bespoke numbered scripts.
- A rubocop-lts-style family workflow can be expressed without hard-coded release scripts.
- `kettle-family discover` produces correct member order for a fixture family.
- `kettle-family template --dry-run` and `--execute` are safe and resumable.
- `kettle-family bump-version --check` can detect required version edits without writing.
- Release commands default to non-mutating plan output.
- CI can consume JSON reports.

## Open Questions

- Should `nomono` be a runtime dependency, an optional integration, or only a config pattern Kettle::Family understands?
- Should the config live at `.kettle-family.yml`, `.structuredmerge/kettle-family.yml`, or both?
- Should `kettle-family` install multiple executable aliases for common workflows?
- How much rubocop-lts branch-lane logic belongs in generic Kettle::Family vs family-specific plugin/config?
- Should family-level commits be supported for sibling multi-repo mode, or only per-repo commits?
- Should release publishing handle interactive MFA directly, or delegate entirely to `kettle-release`?
