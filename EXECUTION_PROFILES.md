# Execution Profiles

`kettle-family` has five execution profiles. They are a compatibility policy,
not a convenience layer for environment variables. A workflow must select one
before it invokes Bundler or a release command.

| Profile | Path gems | Lockfile role | Install location | Mutation boundary |
| --- | --- | --- | --- | --- |
| `development_local` | configured siblings | canonical development lock | member | development source, tests, and lockfiles |
| `template_local` | configured siblings | canonical development lock | member | template-owned source, generated files, and lockfiles |
| `release_registry` | registry only | canonical release lock | disposable bundle | canonical release lock refresh only |
| `release_monorepo` | configured release wave only | canonical release lock | disposable bundle | canonical release lock refresh and configured-wave paths |
| `release_recovery` | configured release wave only | canonical release lock | disposable bundle | the same boundary as the interrupted release |

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
the configured sibling closure, including unpublished family versions.
Release-registry operations must disable that closure, except that an explicit
monorepo release wave uses `release_monorepo`. `kettle-changelog` is not a
general exemption: excluding it is valid only for a demonstrated optional
dependency constraint conflict.

### Scenario gate

Policy changes require a real-Bundler regression scenario for the original
failure shape. Unit tests that inspect constructed commands or environments are
supporting tests, not a substitute for this gate.
