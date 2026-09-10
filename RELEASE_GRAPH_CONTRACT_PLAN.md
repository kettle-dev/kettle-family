# Release Graph Contract Plan

## Purpose

Replace the current mix of topology checks, inherited `*_DEV` environment
variables, lockfile exceptions, and release profiles with explicit release
graph contracts. The goal is to make Bundler resolution, canonical lockfile
validation, disposable release-task locks, and child-process environment
selection agree for every supported family shape.

This is a corrective design plan. It does not treat all local paths as invalid
at release time. A local path is valid only when the selected contract proves
that the path is intentional, available in CI, and appropriate for the
specific release target.

## Confirmed Constraints

- StructuredMerge is a CI-resident monorepo. Its subgems can require
  unreleased sibling gems from the checked-out `gems/` graph during release.
  Its tracked canonical locks may therefore contain only those declared,
  in-repository `PATH` sources, and release children may receive the matching
  `STRUCTUREDMERGE_DEV` selector.
- RuboCop-LTS is a sibling-repository family with a terminal branch stack on
  `rubocop-lts`. No family gem has a runtime dependency on `rubocop-lts`.
  `standard-rubocop-lts` and `rubocop-lts-rspec` have development dependencies
  on it, which must not turn the branch targets into upstream release nodes.
- A RuboCop-LTS branch target must not resolve `RUBOCOP_LTS_DEV` from the main
  checkout. After its prerequisite waves publish, each target branch can use
  registry dependencies and is an isolated terminal release.
- A monorepo is not automatically CI-resident. For example, a monorepo whose
  configured local root is outside the repository needs explicit CI
  provisioning evidence before it can retain that path during release.
- A disposable lock used by release tooling must represent the same selected
  release graph as the canonical lock. It must not mutate the tracked lock.

## Target Contracts

| Contract | Intended shapes | Canonical tracked lock | Release-child graph |
| --- | --- | --- | --- |
| `registry_only` | standalone and ordinary sibling repositories | registry sources only | registry sources only |
| `wave_transition` | sibling families with an explicitly configured unresolved selected dependency | declared workspace path only until its prerequisite wave publishes; registry afterward | exactly the same per-member graph |
| `monorepo_ci_local` | StructuredMerge-style complete monorepo checkout | declared paths contained in the CI checkout are valid | the same declared contained paths |
| `branch_terminal` | RuboCop-LTS `rubocop-lts@branch` targets | registry sources only after prerequisite waves | registry sources only; no main-checkout selector |

`branch_terminal` is deliberately not a generic branch dependency-builder
contract. A future family that releases branch targets consumed by later
targets would require a separately designed contract and test scenario.

## Phase 1: Establish the Contract Boundary

1. Add a single Kettle Family release-graph resolver that accepts the family,
   member, optional target branch/worktree, selected members, and completed
   waves.
2. Make the resolver return a structured value rather than independent
   "allowed roots", "allowed envs", and override hashes. It must include:
   contract name; exact local-path roots; exact selector environment values;
   canonical-lock policy; disposable-lock policy; and child-process policy.
3. Derive graph selection from configuration and target context. Do not infer
   permission from an ambient `*_DEV` environment variable.
4. Separate two currently conflated predicates:
   `configured_monorepo_release?` for scheduling/layout, and
   `ci_resident_local_release_graph?` for whether local paths are legal.
5. Define a configuration error for contradictory settings, such as a
   `monorepo_ci_local` contract whose root is outside the CI checkout, or a
   branch terminal that requests a main-worktree selector.

Primary owner: `kettle-dev/kettle-family`.

## Phase 2: Refactor Kettle Family Execution

1. Replace `release_registry`, `release_monorepo`, and recovery selection with
   profiles derived from the resolved contract. Keep `release_bootstrap`
   separate: it only boots the orchestration tool and must not silently decide
   the member graph.
2. Route every release operation through the same resolved contract:
   dependency-floor reconciliation; lockfile preparation; Bundler install;
   changelog; pre-release checks; `kettle-release`; normalization; recovery;
   and resume.
3. Make monorepo wave behavior explicit. Resolve the discrepancy between
   StructuredMerge's configured `local_path_strategy: waves` and the current
   unconditional monorepo path short-circuit. The chosen configuration must
   state whether every monorepo wave keeps the local graph or transitions
   per-dependency; code and comments must match it.
4. Materialize a branch target as a target identity such as
   `rubocop-lts@r2_3-even-v10`, then resolve its graph from its worktree rather
   than from the primary checkout.
5. Remove the generic policy-environment handoff from Kettle Family once the
   structured contract is passed to Kettle Dev. Compatibility shims, if
   temporarily required, must be one-way and documented with removal criteria.

Primary owner: `kettle-dev/kettle-family`.

## Phase 3: Make Kettle Dev Enforce, Not Redefine, the Contract

1. Replace the strict global release-lockfile normalization introduced in
   `827efa86`. It rejects valid CI-resident StructuredMerge paths and conflicts
   with Kettle Family's existing `release_monorepo` profile.
2. Give `LockfileReset` and `ReleaseCLI` one structured, validated release
   graph input. They must not independently reinterpret environment variables
   or choose a stricter graph than the caller selected.
3. Validate every `PATH` remote against the selected contract's exact allowed
   roots. Reject any path outside that list, including parent workspaces,
   unrelated sibling repositories, and a primary checkout visible from a
   branch worktree.
4. Ensure copied disposable locks retain valid contract paths when required,
   and assert byte-for-byte that release-task Bundler operations do not alter
   the canonical tracked lock except during an explicit canonical normalization
   action.
5. Keep direct `kettle-release` usable without Kettle Family by selecting
   `registry_only` unless a validated explicit contract is supplied. It must
   never inherit local paths merely because a `*_DEV` variable exists.

Primary owner: `kettle-dev/kettle-dev`.

## Phase 4: Configure Existing Family Shapes Explicitly

1. StructuredMerge:
   document and configure `monorepo_ci_local` for the `gems/` root; list the
   only path selector (`STRUCTUREDMERGE_DEV`); keep unrelated tooling selectors
   disabled unless independently declared. Verify Kettle Jem's template mode
   is treated as a declared part of this graph only when necessary.
2. RuboCop-LTS:
   configure `branch_terminal` for `rubocop-lts` target branches. Ensure every
   branch worktree's release graph is registry-only after waves 1-3 and cannot
   observe `RUBOCOP_LTS_DEV` from the main checkout.
3. UR Brain adapters:
   audit its `local_path_root: ..`. Either prove CI provisions that external
   root and configure an explicit contract, or select `registry_only`/a
   transition contract. Do not inherit StructuredMerge semantics merely from
   `mode: monorepo`.
4. Audit every workspace `.kettle-family.yml` with `local_path_env`, explicit
   release environment selectors, lockfile normalization, or release waves:
   Resque, Ruby OpenID, UR Brain, and future family roots. Assign a contract or
   remove stale local-release wiring.
5. Update Kettle Jem's generated family/template configuration only where it
   owns the relevant policy defaults. Do not inject a monorepo contract into
   unrelated standalone or sibling-repository destinations.

Owners: `structuredmerge/ruby`, `rubocop-lts`, `ur-brain`, affected family
roots, and `structuredmerge/ruby/gems/kettle-jem` for generated defaults.

## Phase 5: Build Real-Bundler Scenario Coverage

Each scenario must launch the actual command chain, run Bundler, inspect the
resulting locks, and verify child environment behavior. Command-construction
unit specs are supplemental only.

1. `registry_only`: an ambient local selector is set, but canonical and
   disposable release locks resolve registry sources only.
2. `wave_transition`: a dependent member resolves an unpublished selected
   predecessor from the declared local root before its wave, then resolves the
   published registry gem after the wave and on resume.
3. `monorepo_ci_local`: a StructuredMerge-shaped member requires an
   unpublished sibling, its canonical and disposable locks retain only
   contained paths, and release children boot and execute against that graph.
4. `monorepo_external_root`: a monorepo-layout fixture points outside its
   checkout and is rejected unless explicit CI provisioning is declared.
5. `branch_terminal`: create a branch worktree with a conflicting main
   checkout. Prove the target release uses registry dependencies, never reads
   the main checkout, and releases all target branches independently.
6. Direct-release fallback: run `kettle-release` outside Kettle Family with
   ambient local selectors and prove it selects `registry_only` unless given a
   validated explicit contract.
7. Resume and recovery: repeat scenarios 2, 3, and 5 from a pre-existing
   release commit and prove the graph remains stable.
8. Canonical-lock integrity: prove release child commands cannot dirty the
   tracked lock; prove an intentional normalization is visible, validated, and
   committed before CI starts.

Owners: Kettle Family and Kettle Dev specs first; retain focused acceptance
fixtures in StructuredMerge and RuboCop-LTS only when they catch wiring the
generic fixtures cannot represent.

## Phase 6: Documentation and Migration

1. Rewrite `kettle-family/EXECUTION_PROFILES.md` and release README sections
   around the four contracts. Remove the false claim that every release child
   is registry-only.
2. Document contract selection, CI-provisioning proof, exact allowed paths,
   branch-target isolation, direct-release fallback, and recovery behavior.
3. Add a migration diagnostic that reports the inferred legacy behavior and
   required explicit contract before changing behavior for existing families.
4. Update generated Kettle Jem documentation/configuration only after the
   contract schema and migration diagnostics are stable.

## Phase 7: Release and Rollout

1. Implement and test Kettle Dev's contract consumer locally with Kettle
   Family's producer wired from the same checkout.
2. Release Kettle Dev first, because Kettle Family's new producer depends on
   the consumer understanding the contract.
3. Release Kettle Family next, then update its floor in Kettle Jem and any
   affected family roots.
4. Apply generated template changes through the normal Kettle Jem template
   workflow; validate a clean rerun before committing each family.
5. Run a dry-run and then a real release rehearsal for each supported shape:
   ordinary sibling, wave transition, StructuredMerge monorepo, and
   RuboCop-LTS branch terminal.
6. Do not release the current strict Kettle Dev change as the final policy.
   Supersede it with the tested contract implementation and record the
   corrective behavior in the appropriate Unreleased changelogs.

## Completion Criteria

- Every active family has an assigned release graph contract or an explicit
  documented reason to remain on the default `registry_only` contract.
- No release behavior depends on ambient local-path environment variables.
- StructuredMerge can release a subgem against its declared CI-resident
  sibling graph without canonical-lock churn or path-policy failure.
- RuboCop-LTS branch releases cannot resolve from the main checkout and do not
  need support for downstream runtime consumers.
- Direct Kettle Release, Kettle Family release, restart, and recovery all use
  the same graph contract for a given target.
- Real-Bundler scenarios cover every supported contract and CI enforces them.
