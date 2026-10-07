# frozen_string_literal: true

RSpec.describe Kettle::Family::UnreleasedGemCleanup do
  def member(name)
    Kettle::Family::Member.new(
      name: name,
      root: "/repo/#{name}",
      gemspec_path: nil,
      version_file: nil,
      version: "1.2.0",
      dependencies: []
    )
  end

  def release_state(member_name, latest_released:, success: true, status: 0, stderr: "")
    Kettle::Family::ReleaseStateResult.new(
      member_name: member_name,
      command: %w[kettle-changelog --release-state --json],
      workdir: "/repo/#{member_name}",
      status: status,
      success: success,
      stdout: "",
      stderr: stderr,
      elapsed_seconds: 0.0,
      state: {"latest_released" => latest_released}
    )
  end

  # An actually installed gem: full_gem_path sits under a real gem home, so it is
  # what `gem uninstall` can remove.
  def spec_version(version, name: "alpha", installed: true)
    path = if installed
      File.join(Gem.dir, "gems", "#{name}-#{version}")
    else
      # A PATH/git source checkout that bundler put on the load path.
      "/repo/#{name}"
    end
    instance_double(Gem::Specification, version: Gem::Version.new(version), full_gem_path: path)
  end

  it "plans a single batched uninstall of installed versions newer than the latest release" do
    alpha = member("alpha")
    allow(Kettle::Family::ReleaseStateCheck).to receive(:new)
      .and_return(instance_double(Kettle::Family::ReleaseStateCheck, results: [release_state("alpha", latest_released: "1.0.0")]))
    allow(Gem::Specification).to receive(:find_all_by_name).with("alpha")
      .and_return([spec_version("0.9.0"), spec_version("1.0.0"), spec_version("1.0.1"), spec_version("1.1.0")])

    results = described_class.new(config: nil, members: [alpha]).results

    expect(results.map(&:stdout)).to eq(["would uninstall alpha 1.0.1, alpha 1.1.0"])
    expect(results.map(&:skipped)).to eq([true])
    expect(results.map(&:command)).to eq([
      %w[gem uninstall alpha:1.0.1 alpha:1.1.0 --executables]
    ])
  end

  it "runs one gem uninstall for all unreleased installed candidates when executed" do
    alpha = member("alpha")
    runner = instance_double(Kettle::Family::CommandRunner)
    expected = Kettle::Family::CommandResult.new("alpha", "clean_unreleased", %w[gem uninstall alpha], "/repo/alpha", 0, true, "", "", 0.0, false, nil)
    allow(Kettle::Family::ReleaseStateCheck).to receive(:new)
      .and_return(instance_double(Kettle::Family::ReleaseStateCheck, results: [release_state("alpha", latest_released: "1.0.0")]))
    allow(Gem::Specification).to receive(:find_all_by_name).with("alpha")
      .and_return([spec_version("1.0.1")])
    allow(runner).to receive(:call).and_return(expected)

    results = described_class.new(config: nil, members: [alpha], execute: true, runner: runner).results

    expect(results).to eq([expected])
    expect(runner).to have_received(:call).with(
      member: alpha,
      phase: "clean_unreleased",
      command: %w[gem uninstall alpha:1.0.1 --executables]
    )
  end

  # RubyGems' uninstall_specific topologically sorts the whole requested set
  # (strongly_connected_components.flatten.reverse), removing dependents before
  # their dependencies. A per-gem invocation sees one gem, cannot sort, and
  # raises Gem::DependencyRemovalException when an installed gem still depends on
  # it. Family members are interdependent, so this is the difference between
  # succeeding and failing on the foundations.
  it "batches candidates from every member into one invocation" do
    alpha = member("alpha")
    beta = member("beta")
    runner = instance_double(Kettle::Family::CommandRunner)
    allow(Kettle::Family::ReleaseStateCheck).to receive(:new)
      .and_return(instance_double(Kettle::Family::ReleaseStateCheck, results: [
        release_state("alpha", latest_released: "1.0.0"),
        release_state("beta", latest_released: "2.0.0")
      ]))
    allow(Gem::Specification).to receive(:find_all_by_name).with("alpha").and_return([spec_version("1.0.1")])
    allow(Gem::Specification).to receive(:find_all_by_name).with("beta").and_return([spec_version("2.0.1", name: "beta"), spec_version("2.1.0", name: "beta")])
    allow(runner).to receive(:call) do |member:, phase:, command:|
      Kettle::Family::CommandResult.new(member.name, phase, command, member.root, 0, true, "", "", 0.0, false, nil)
    end

    described_class.new(config: nil, members: [alpha, beta], execute: true, runner: runner).results

    expect(runner).to have_received(:call).once
    expect(runner).to have_received(:call).with(
      member: alpha,
      phase: "clean_unreleased",
      command: %w[gem uninstall alpha:1.0.1 beta:2.0.1 beta:2.1.0 --executables]
    )
  end

  # --all with no gem arguments means uninstall_all, which removes every gem in
  # the gem home. Omitting it makes an empty argument list a usage error instead.
  it "never passes --all or --version to gem uninstall" do
    alpha = member("alpha")
    allow(Kettle::Family::ReleaseStateCheck).to receive(:new)
      .and_return(instance_double(Kettle::Family::ReleaseStateCheck, results: [release_state("alpha", latest_released: "1.0.0")]))
    allow(Gem::Specification).to receive(:find_all_by_name).with("alpha").and_return([spec_version("1.0.1")])

    command = described_class.new(config: nil, members: [alpha]).results.first.command

    expect(command).not_to include("--all")
    expect(command).not_to include("--version")
  end

  # Enumerating installed specs twice per member would double the work and could
  # report inconsistently if an install landed between the two passes.
  it "enumerates installed versions once per member" do
    alpha = member("alpha")
    allow(Kettle::Family::ReleaseStateCheck).to receive(:new)
      .and_return(instance_double(Kettle::Family::ReleaseStateCheck, results: [release_state("alpha", latest_released: "1.0.0")]))
    allow(Gem::Specification).to receive(:find_all_by_name).with("alpha").and_return([spec_version("1.0.1")])

    described_class.new(config: nil, members: [alpha]).results

    expect(Gem::Specification).to have_received(:find_all_by_name).with("alpha").once
  end

  # Under `bundle exec`, bundler puts PATH and git sources on the load path, so
  # find_all_by_name also returns specs whose full_gem_path is a source checkout
  # (gems/tree_haver) rather than an installed gem. `gem uninstall` cannot remove
  # those, so offering to would report work that can never succeed — and once
  # batched, one such bogus candidate would abort the whole batch.
  it "ignores source-checkout specs that are not installed gems" do
    alpha = member("alpha")
    allow(Kettle::Family::ReleaseStateCheck).to receive(:new)
      .and_return(instance_double(Kettle::Family::ReleaseStateCheck, results: [release_state("alpha", latest_released: "1.0.0")]))
    # Only the source checkout is present; nothing is actually installed.
    allow(Gem::Specification).to receive(:find_all_by_name).with("alpha")
      .and_return([spec_version("1.0.1", installed: false)])

    result = described_class.new(config: nil, members: [alpha]).results.first

    expect(result).to be_ok
    expect(result.stdout).to eq("no unreleased installed versions found")
  end

  # A bogus source-checkout candidate must not poison the batch that removes
  # genuinely installed gems.
  it "batches installed gems while excluding source-checkout specs" do
    alpha = member("alpha")
    beta = member("beta")
    allow(Kettle::Family::ReleaseStateCheck).to receive(:new)
      .and_return(instance_double(Kettle::Family::ReleaseStateCheck, results: [
        release_state("alpha", latest_released: "1.0.0"),
        release_state("beta", latest_released: "2.0.0")
      ]))
    allow(Gem::Specification).to receive(:find_all_by_name).with("alpha").and_return([spec_version("1.0.1")])
    allow(Gem::Specification).to receive(:find_all_by_name).with("beta")
      .and_return([spec_version("2.0.1", name: "beta", installed: false)])

    result = described_class.new(config: nil, members: [alpha, beta]).results.last

    expect(result.command).to eq(%w[gem uninstall alpha:1.0.1 --executables])
  end

  # Regression guard: `reason` must stay nil for a successful real run, and must
  # be preserved verbatim for a dry run. Neither was previously asserted, which
  # let a refactor silently change it.
  it "reports a nil reason when the executed batch succeeds" do
    alpha = member("alpha")
    runner = instance_double(Kettle::Family::CommandRunner)
    allow(Kettle::Family::ReleaseStateCheck).to receive(:new)
      .and_return(instance_double(Kettle::Family::ReleaseStateCheck, results: [release_state("alpha", latest_released: "1.0.0")]))
    allow(Gem::Specification).to receive(:find_all_by_name).with("alpha").and_return([spec_version("1.0.1")])
    allow(runner).to receive(:call).and_return(
      Kettle::Family::CommandResult.new("alpha", "clean_unreleased", %w[gem uninstall], "/repo/alpha", 0, true, "ok", "", 0.5, false, nil)
    )

    result = described_class.new(config: nil, members: [alpha], execute: true, runner: runner).results.first

    expect(result).to be_ok
    expect(result.skipped).to be(false)
    expect(result.reason).to be_nil
    expect(result.stdout).to eq("ok")
  end

  # A failed batch must name the gems that member contributed, not just say the
  # batch failed, so a multi-member failure is still attributable per member.
  it "names the member's own gems when the executed batch fails" do
    alpha = member("alpha")
    runner = instance_double(Kettle::Family::CommandRunner)
    allow(Kettle::Family::ReleaseStateCheck).to receive(:new)
      .and_return(instance_double(Kettle::Family::ReleaseStateCheck, results: [release_state("alpha", latest_released: "1.0.0")]))
    allow(Gem::Specification).to receive(:find_all_by_name).with("alpha").and_return([spec_version("1.0.1")])
    allow(runner).to receive(:call).and_return(
      Kettle::Family::CommandResult.new("alpha", "clean_unreleased", %w[gem uninstall], "/repo/alpha", 1, false, "", "boom", 0.5, false, "command failed")
    )

    result = described_class.new(config: nil, members: [alpha], execute: true, runner: runner).results.first

    expect(result).not_to be_ok
    expect(result.reason).to eq("batched gem uninstall including alpha 1.0.1 failed")
  end

  it "does not uninstall when the latest released version is unknown" do
    alpha = member("alpha")
    allow(Kettle::Family::ReleaseStateCheck).to receive(:new)
      .and_return(instance_double(Kettle::Family::ReleaseStateCheck, results: [release_state("alpha", latest_released: nil)]))
    allow(Gem::Specification).to receive(:find_all_by_name)

    results = described_class.new(config: nil, members: [alpha]).results

    expect(results.first).to be_ok
    expect(results.first.stdout).to include("latest released version is unknown")
    expect(Gem::Specification).not_to have_received(:find_all_by_name)
  end

  it "reports missing and failed release state without inspecting installed gems" do
    alpha = member("alpha")
    beta = member("beta")
    failed_state = release_state(
      "beta",
      latest_released: nil,
      success: false,
      status: 6,
      stderr: "state unavailable"
    )
    allow(Kettle::Family::ReleaseStateCheck).to receive(:new)
      .and_return(instance_double(Kettle::Family::ReleaseStateCheck, results: [failed_state]))
    allow(Gem::Specification).to receive(:find_all_by_name)

    results = described_class.new(config: nil, members: [alpha, beta]).results

    expect(results.map(&:status)).to eq([1, 6])
    expect(results.map(&:reason)).to all(eq("release state unavailable"))
    expect(results.last.stderr).to eq("state unavailable")
    expect(Gem::Specification).not_to have_received(:find_all_by_name)
  end

  it "treats unknown and malformed released versions as unavailable" do
    members = %w[alpha beta].map { |name| member(name) }
    states = ["unknown", "not-a-version"].each_with_index.map do |version, index|
      release_state(members.fetch(index).name, latest_released: version)
    end
    allow(Kettle::Family::ReleaseStateCheck).to receive(:new)
      .and_return(instance_double(Kettle::Family::ReleaseStateCheck, results: states))
    allow(Gem::Specification).to receive(:find_all_by_name)

    results = described_class.new(config: nil, members: members).results

    expect(results.map(&:stdout)).to all(include("latest released version is unknown"))
    expect(Gem::Specification).not_to have_received(:find_all_by_name)
  end

  it "reports when installed versions contain no unreleased candidates" do
    alpha = member("alpha")
    allow(Kettle::Family::ReleaseStateCheck).to receive(:new)
      .and_return(instance_double(Kettle::Family::ReleaseStateCheck, results: [release_state("alpha", latest_released: "v1.0.0")]))
    allow(Gem::Specification).to receive(:find_all_by_name).with("alpha")
      .and_return([spec_version("0.9.0"), spec_version("1.0.0"), spec_version("1.0.0")])

    result = described_class.new(config: nil, members: [alpha]).results.fetch(0)

    expect(result).to be_ok
    expect(result.stdout).to eq("no unreleased installed versions found")
  end
end
