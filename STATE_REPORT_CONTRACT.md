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
- Member-local changelogs retain their independent release identity.

For exact-tag queries, `missing` means GitHub explicitly reported that no release
exists. `error` means lookup failed, for example due to authentication or rate
limits. JSON retains the expected tag and diagnostic. `unknown` means no release
value was obtained without a classified exact-tag result. Missing releases must
not be replaced by an unrelated newer release, and inspection must not create
releases or move tags.

## Count Scope

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
