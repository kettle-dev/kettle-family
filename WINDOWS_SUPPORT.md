# Windows Support and Test Policy

## Support Contract

Kettle Family supports native Windows Ruby for the same public family commands
as other supported platforms, subject to individually documented operating
system limitations. A green Windows workflow is evidence only for the behavior
the job actually executes. It is not evidence that a command works natively if
the test substitutes the process, shell, or executable behavior under test.

The Windows CI job runs the same spec suite as Linux and macOS. Keep that job
red when a supported behavior fails. Do not make it green by weakening an
assertion, hiding a failure, or marking a test pending without documenting a
specific unsupported capability and its follow-up.

## Test Boundaries

Classify a test by the behavior it claims to establish:

- Pure Ruby logic and data transformation should use the same examples on all
  platforms.
- Process integration tests must execute through native Windows process
  creation, argument passing, environment handling, and filesystem semantics
  whenever one of those is under test.
- A test double is appropriate for an external service or executable only
  when that dependency is outside the behavior under test. The double must not
  replace the Windows mechanism whose behavior the test claims to verify.
- Tests of Bundler or lockfile behavior should use real Ruby, Bundler, and Git
  against local temporary fixtures. They must not require registry or network
  access. A stubbed `bundle` command may test family orchestration around a
  bundle command, but cannot establish that Bundler works on Windows.
- A native `.cmd` fixture may test Windows command lookup and argument
  forwarding, but it must implement the fixture behavior directly. Do not add
  a Ruby-to-Bash bridge to make a Unix shell fixture appear portable.
- If a Windows capability genuinely is unavailable (for example, PTY), mark
  only the affected example pending, state the limitation in the example, and
  keep the surrounding behavior covered by tests that do run on Windows.

## Failure Handling

For each Windows CI failure, preserve the run URL and commit, exact example,
observed error or mismatch, and the root cause once proven. Separate observed
symptoms from root-cause claims. Before changing an expectation or adding a
platform branch, establish whether the defect is in production behavior, the
test fixture, or an unsupported capability. After a fix, the regression test
must exercise the same boundary that failed; a passing test on another
platform is not Windows validation.

Do not accumulate Windows-only conditionals as a substitute for understanding
the platform contract. Prefer a shared implementation and shared assertions;
use platform-specific setup only where the operating system genuinely requires
it, and keep that setup smaller than the behavior being tested.

## Baseline: Current MRI Workflow

Run [36358393188](https://github.com/kettle-dev/kettle-family/actions/runs/36358393188)
at commit `288729fe` completed with Linux and macOS passing and Windows failing
with 12 failures out of 745 examples (one PTY example was already pending).
The following are observed symptoms; they are not yet root-cause diagnoses:

| Area | Failing example(s) | Observed symptom |
| --- | --- | --- |
| Branch test cleanup | `workflow_template_spec.rb:1948` | Expected `branch_generated_lockfile_recovery` phase was absent. |
| Reset subprocess | `workflow_spec.rb:256`, `:318` | Helper output did not show expected bundle environment/reset state. |
| Branch target config | `release_state_check_spec.rb:685` | Loaded config path did not match the expected member-local config. |
| Discovery exclusions | `discovery_spec.rb:289`, `:305`, `:316`, `:327`, `:347` | Configured/default exclusions failed to exclude fixture or vendored gemspecs; one case raised a duplicate-member error. |
| Release lockfile planning | `workflow_release_spec.rb:2010`, `:2037`, `:2062` | Expected lockfile normalization/recovery phases were absent; planning stopped at `check` or omitted those phases. |

The Windows-specific `fake_bundle_env` in `workflow_release_spec.rb` currently
launches a Bash script through a Ruby `.cmd` wrapper. This is a test-fixture
implementation, not a product requirement. It crosses two command interpreters
and therefore does not provide clean evidence about native Bundler behavior.
Replace it with direct fixture behavior or a local real-Bundler integration
test according to the boundary being tested; do not extend the bridge.

Until each baseline failure has a proven cause and an appropriate regression
test, Windows support for the affected behavior remains unverified. The CI job
must continue to report those failures rather than converting them into passes.
