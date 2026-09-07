# frozen_string_literal: true

RSpec.describe Kettle::Family::ReleaseReconciler do
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

  def release_state(member_name, latest_released:, github_latest_release: nil, success: true, status: 0, stderr: "")
    Kettle::Family::ReleaseStateResult.new(
      member_name: member_name,
      command: %w[kettle-changelog --release-state --json],
      workdir: "/repo/#{member_name}",
      status: status,
      success: success,
      stdout: "",
      stderr: stderr,
      elapsed_seconds: 0.0,
      state: {"latest_released" => latest_released, "github_latest_release" => github_latest_release}
    )
  end

  it "does not check a member whose GitHub Release already matches RubyGems" do
    alpha = member("alpha")
    runner = instance_double(Kettle::Family::CommandRunner)
    allow(runner).to receive(:call)
    allow(Kettle::Family::ReleaseStateCheck).to receive(:new)
      .and_return(instance_double(Kettle::Family::ReleaseStateCheck, results: [release_state("alpha", latest_released: "1.2.3", github_latest_release: "v1.2.3")]))

    results = described_class.new(config: nil, members: [alpha], runner: runner).results

    expect(results.first.stdout).to include("already matches")
    expect(runner).not_to have_received(:call)
  end

  it "creates a release only after the executable check succeeds" do
    alpha = member("alpha")
    check = Kettle::Family::CommandResult.new("alpha", "reconcile_github_release_check", [], alpha.root, 0, true, "{\"type\":\"github_release\",\"message\":\"ready\"}\n", "", 0.0, false, nil)
    create = Kettle::Family::CommandResult.new("alpha", "reconcile_github_release", [], alpha.root, 0, true, "", "", 0.0, false, nil)
    runner = instance_double(Kettle::Family::CommandRunner)
    allow(Kettle::Family::ReleaseStateCheck).to receive(:new)
      .and_return(instance_double(Kettle::Family::ReleaseStateCheck, results: [release_state("alpha", latest_released: "1.2.3")]))
    allow(runner).to receive(:call).and_return(check, create)
    reconciler = described_class.new(config: nil, members: [alpha], execute: true, runner: runner)
    allow(reconciler).to receive(:kettle_gh_release_path).and_return("/tools/kettle-gh-release")

    results = reconciler.results

    expect(results.map(&:phase)).to eq(["reconcile_github_release_check", "reconcile_github_release"])
    expect(results.first.stdout).to eq("ready")
    expect(results.last).to eq(create)
    expect(runner).to have_received(:call).with(
      member: alpha,
      phase: "reconcile_github_release_check",
      command: [RbConfig.ruby, "/tools/kettle-gh-release", "--check", "--release-version", "1.2.3", "--events"]
    )
    expect(runner).to have_received(:call).with(
      member: alpha,
      phase: "reconcile_github_release",
      command: [RbConfig.ruby, "/tools/kettle-gh-release", "--release-version", "1.2.3", "--events"]
    )
  end

  it "uses the requested local kettle-dev checkout before an installed gem" do
    reconciler = described_class.new(config: nil, members: [])
    stub_env("KETTLE_DEV_DEV" => "/home/pboling/src/my/kettle-dev")
    allow(File).to receive(:file?).with("/home/pboling/src/my/kettle-dev/exe/kettle-gh-release").and_return(false)
    allow(File).to receive(:file?).with("/home/pboling/src/my/kettle-dev/kettle-dev/exe/kettle-gh-release").and_return(true)

    expect(reconciler.send(:kettle_gh_release_path)).to eq("/home/pboling/src/my/kettle-dev/kettle-dev/exe/kettle-gh-release")
  end

  it "reports missing and failed release-state results without running a check" do
    alpha = member("alpha")
    beta = member("beta")
    runner = instance_double(Kettle::Family::CommandRunner)
    failed_state = release_state(
      "beta",
      latest_released: nil,
      success: false,
      status: 7,
      stderr: "state failed"
    )
    allow(runner).to receive(:call)
    allow(Kettle::Family::ReleaseStateCheck).to receive(:new)
      .and_return(instance_double(Kettle::Family::ReleaseStateCheck, results: [failed_state]))

    results = described_class.new(config: nil, members: [alpha, beta], runner: runner).results

    expect(results.map(&:status)).to eq([1, 7])
    expect(results.map(&:reason)).to all(eq("release state unavailable"))
    expect(results.last.stderr).to eq("state failed")
    expect(runner).not_to have_received(:call)
  end

  it "does not reconcile unknown RubyGems release versions" do
    members = %w[alpha beta gamma].map { |name| member(name) }
    states = [nil, "", "unknown"].each_with_index.map do |version, index|
      release_state(members.fetch(index).name, latest_released: version)
    end
    runner = instance_double(Kettle::Family::CommandRunner)
    allow(runner).to receive(:call)
    allow(Kettle::Family::ReleaseStateCheck).to receive(:new)
      .and_return(instance_double(Kettle::Family::ReleaseStateCheck, results: states))

    results = described_class.new(config: nil, members: members, runner: runner).results

    expect(results.map(&:stdout)).to all(include("release version is unknown"))
    expect(runner).not_to have_received(:call)
  end

  it "returns a failed prerequisite check without attempting release creation" do
    alpha = member("alpha")
    check = Kettle::Family::CommandResult.new(
      "alpha",
      "reconcile_github_release_check",
      [],
      alpha.root,
      1,
      false,
      "",
      "missing asset",
      0.0,
      false,
      "check failed"
    )
    runner = instance_double(Kettle::Family::CommandRunner)
    allow(Kettle::Family::ReleaseStateCheck).to receive(:new)
      .and_return(instance_double(Kettle::Family::ReleaseStateCheck, results: [release_state("alpha", latest_released: "v1.2.3")]))
    allow(runner).to receive(:call).and_return(check)
    reconciler = described_class.new(config: nil, members: [alpha], execute: true, runner: runner)
    allow(reconciler).to receive(:kettle_gh_release_path).and_return("/tools/kettle-gh-release")

    expect(reconciler.results).to eq([check])
    expect(runner).to have_received(:call).once
  end

  it "summarizes a successful dry-run check when no release event is emitted" do
    alpha = member("alpha")
    check = Kettle::Family::CommandResult.new(
      "alpha",
      "reconcile_github_release_check",
      [],
      alpha.root,
      0,
      true,
      "not json\n{\"type\":\"other\"}\n",
      "",
      0.1,
      false,
      nil
    )
    runner = instance_double(Kettle::Family::CommandRunner)
    allow(Kettle::Family::ReleaseStateCheck).to receive(:new)
      .and_return(instance_double(Kettle::Family::ReleaseStateCheck, results: [release_state("alpha", latest_released: "1.2.3")]))
    allow(runner).to receive(:call).and_return(check)
    reconciler = described_class.new(config: nil, members: [alpha], runner: runner)
    allow(reconciler).to receive(:kettle_gh_release_path).and_return("/tools/kettle-gh-release")

    results = reconciler.results

    expect(results.one?).to be(true)
    expect(results.first.stdout).to eq("GitHub release v1.2.3 is eligible to be created")
  end

  it "uses the first local executable candidate when available" do
    reconciler = described_class.new(config: nil, members: [])
    stub_env("KETTLE_DEV_DEV" => "/workspace/kettle-dev")
    allow(File).to receive(:file?).with("/workspace/kettle-dev/exe/kettle-gh-release").and_return(true)

    expect(reconciler.send(:kettle_gh_release_path)).to eq("/workspace/kettle-dev/exe/kettle-gh-release")
  end

  it "falls back to the installed kettle-dev specification when local checkout use is disabled" do
    reconciler = described_class.new(config: nil, members: [])
    specification = instance_double(Gem::Specification, full_gem_path: "/installed/kettle-dev")
    stub_env("KETTLE_DEV_DEV" => "off")
    allow(Gem.loaded_specs).to receive(:[]).with("kettle-dev").and_return(nil)
    allow(Gem::Specification).to receive(:find_by_name).with("kettle-dev").and_return(specification)

    expect(reconciler.send(:kettle_gh_release_path)).to eq("/installed/kettle-dev/exe/kettle-gh-release")
  end
end
