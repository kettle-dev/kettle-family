# Execution Profiles

`kettle-family` has six execution profiles. They are a compatibility policy,
not a convenience layer for environment variables. A workflow must select one
before it invokes Bundler or a release command.

| Profile | Path gems | Lockfile role | Install location | Mutation boundary |
| --- | --- | --- | --- | --- |
| `development_local` | configured siblings | canonical development lock | member | development source, tests, and lockfiles |
| `template_local` | configured siblings | canonical development lock | member | template-owned source, generated files, and lockfiles |
| `release_registry` | registry only | canonical release lock | disposable bundle | canonical release lock refresh only |
| `release_monorepo` | declared CI-resident monorepo paths | canonical release lock | disposable bundle | canonical release lock refresh and declared monorepo paths |
| `release_wave_transition` | declared unresolved wave dependencies | canonical release lock | disposable bundle | canonical release lock refresh and declared transition paths |

Every profile requires the active host to install and boot the selected graph.
The platform rule is behavioral: a frozen install and `bundle exec` must work
on that host. It is deliberately not a string comparison against
`Gem::Platform.local`, because Bundler can satisfy a host through a compatible
platform entry such as `x86_64-linux-gnu`.

## Decision Records

### Disposable release installation locks

Release lock normalization may change a canonical lock. Materializing the
bundle needed by pre-release commands must not. The release profile therefore
copies the canonical lock into a process-local disposable location before
`bundle install` and `bundle exec kettle-changelog`. The regression proof is
the real-Bundler registry-only scenario in
`spec/kettle/family/execution_profile_spec.rb`: it installs and boots from the
disposable lock while asserting that the canonical bytes are unchanged.

### Template graph versus release graph

Template bootstrap and recovery are development operations. They must resolve
the configured sibling closure, including unpublished family versions. Release
graph selection is explicit and serialized to every `kettle-release` child;
the child validates the same contract rather than rebuilding policy from its
ambient environment.

| Contract | Use | Local paths in canonical release lock and child commands |
| --- | --- | --- |
| `registry_only` | Default for standalone and ordinary sibling families | Never |
| `wave_transition` | A sibling release wave has an unpublished selected dependency | Only until that selected dependency completes; later waves use the registry |
| `monorepo_ci_local` | CI checks out the family repository and its member graph | Only roots under the declared family CI root |
| `branch_terminal` | A branch stack contains terminal leaf releases | Never |

`monorepo_ci_local` carries both the family CI root and the allowed member-path
root. A child release runs from a subgem, so checking only the child directory
would incorrectly reject valid sibling paths. Conversely, an external parent
workspace is not a CI-resident monorepo root and must use `registry_only`.

`branch_terminal` deliberately does not inherit the main family graph. The
RuboCop-LTS branch stack is an end-node set: no family runtime dependency is
built from it. It releases only after its dependency waves have published.

### Branch worktree template equivalence

A branch-target worktree uses `template_local` exactly as its ordinary-member
counterpart. The common template workflow includes debugger, Appraisal, and
Nomono bootstrap; lockfile preparation and recovery; dependency preparation;
template execution; normalization; and commit handling. Worktree creation,
Mise trust, target-branch upstream synchronization, result tagging, and
cleanup are checkout mechanics only. They must wrap the common workflow and
must not select a different dependency graph or bypass any common phase.

### Scenario gate

Policy changes require a real-Bundler regression scenario for the original
failure shape. Unit tests that inspect constructed commands or environments are
supporting tests, not a substitute for this gate.
