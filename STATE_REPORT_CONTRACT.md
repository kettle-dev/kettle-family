# Release State Report Contract

`state` is a read-only inspection command, not a release gate. A successful
inspection does not mean every target is published or ready for release.

## Ordering and Progress

Use configured dependency order or fixed order, including hints. A cyclic
dependency graph must remain inspectable: only for state inspection, fall back
to hints followed by alphabetical order when topological ordering fails.
Commands that execute dependency-ordered work must still reject cycles.

Each target completes five phases: changelog probe, computed booleans, Git
state, GitHub release, and transfer changelog. Shared-changelog subgems and
branch targets must emit the same phase events as ordinary members.

## Release Identity

- Ordinary independently versioned repositories use their latest GitHub release.
- Shared-root changelog members query the exact registry release version's tag.
- Branch-stack targets also query their exact release version's tag, never the
  repository-wide latest release belonging to another branch.
- Member-local changelogs in a shared-changelog monorepo also query their exact
  released version: publishing the cohort later must not replace their identity
  with the repository-wide latest release.

For exact-tag queries, `missing` means GitHub explicitly reported that no release
exists. `error` means lookup failed, for example due to authentication or rate
limits. JSON retains the expected tag and diagnostic. `unknown` means no release
value was obtained without a classified exact-tag result. Missing releases must
not be replaced by an unrelated newer release, and inspection must not create
releases or move tags.

## Count Scope

Text output reports identical shared checkout, changelog version, GitHub
release, and Git counts on the first selected row of each explicitly shared
changelog/version/branch cohort. Later matching cells display `-`. Independently
versioned members retain their own cells. Member versions, registry versions,
transfer applicability and release-selection flags are never suppressed. JSON
retains every value and identifies the shared changelog root.

Git ahead/behind counts compare repository refs against the selected version's
tag. They are not path-filtered member change counts. Subgems sharing a tag and
repository therefore legitimately share counts; independent versions can have
different counts in the same repository. Parenthesized values are remote-ref
counts, not additional local commits.

Transfer lag currently comes from Kettle Jem's project-root status API. It
applies member-specific filters and reads transfer keys from that project's
`CHANGELOG.md`. It does not infer applied entries from the historical replay
cursor when the status API is available. A subgem without a local changelog can
therefore report all applicable entries missing. Shared-changelog transfer
ownership needs to be represented by that API before those counts can be
interpreted as family-root replay status; changing the root blindly would also
change member-specific applicability filters.

## Regression Coverage

CLI specs exercise dependency ordering and cyclic inspection. State-check specs
exercise shared-root phase parity, independent member changelogs, branch targets,
and exact-tag missing/error results. Report specs distinguish missing, error,
and unknown values. Existing shared-version selection tests protect release
selection independently of GitHub release presentation.

## Incremental Shared GitHub Releases

Aggregate monorepo member commands delegate GitHub publication to the family.
That delegation is per member, not conditional on the entire train succeeding.
After each member finalizes, push the shared ref and invoke `kettle-gh-release`
with that member's gem and available SHA-256/SHA-512 files. The existing uploader
creates the release if absent and preserves existing assets while adding missing
ones. Never collect artifacts from unexecuted members merely because their
package files exist locally.

In a partially failed worktree wave, finalize successfully published and
materialized members before returning the worker failure. Do not advance to the
next wave. A GitHub upload failure is also a hard failure, with the aggregate
command retained as the recovery command. A process killed before finalization
can still require explicit reconciliation; no in-memory scheduler can guarantee
completion after process termination.

Sibling repositories and independent monorepo members retain their own GitHub
release lifecycle. Branch-stack releases retain their branch-specific identity.
Read-only state inspection never publishes or reconciles a release itself.

Regression specs cover sequential interruption, partial worker failure,
per-member shared release updates, upload failure propagation and shared-cell
rendering without mutation of the underlying state.
