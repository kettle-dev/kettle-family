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

  def release_state(member_name, latest_released:)
    Kettle::Family::ReleaseStateResult.new(
      member_name: member_name,
      command: %w[kettle-changelog --release-state --json],
      workdir: "/repo/#{member_name}",
      status: 0,
      success: true,
      stdout: "",
      stderr: "",
      elapsed_seconds: 0.0,
      state: {"latest_released" => latest_released}
    )
  end

  def spec_version(version)
    instance_double(Gem::Specification, version: Gem::Version.new(version))
  end

  it "plans installed family gem versions newer than the latest release" do
    alpha = member("alpha")
    allow(Kettle::Family::ReleaseStateCheck).to receive(:new)
      .and_return(instance_double(Kettle::Family::ReleaseStateCheck, results: [release_state("alpha", latest_released: "1.0.0")]))
    allow(Gem::Specification).to receive(:find_all_by_name).with("alpha")
      .and_return([spec_version("0.9.0"), spec_version("1.0.0"), spec_version("1.0.1"), spec_version("1.1.0")])

    results = described_class.new(config: nil, members: [alpha]).results

    expect(results.map(&:stdout)).to eq(["would uninstall alpha 1.0.1", "would uninstall alpha 1.1.0"])
    expect(results.map(&:skipped)).to eq([true, true])
    expect(results.map(&:command)).to eq([
      %w[gem uninstall alpha --version 1.0.1 --executables --all],
      %w[gem uninstall alpha --version 1.1.0 --executables --all]
    ])
  end

  it "runs gem uninstall for each unreleased installed candidate when executed" do
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
      command: %w[gem uninstall alpha --version 1.0.1 --executables --all]
    )
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
end
