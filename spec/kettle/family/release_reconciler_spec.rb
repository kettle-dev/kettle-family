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

  def release_state(member_name, latest_released:, github_latest_release: nil)
    Kettle::Family::ReleaseStateResult.new(
      member_name: member_name,
      command: %w[kettle-changelog --release-state --json],
      workdir: "/repo/#{member_name}",
      status: 0,
      success: true,
      stdout: "",
      stderr: "",
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
    check = Kettle::Family::CommandResult.new("alpha", "reconcile_github_release_check", [], alpha.root, 0, true, "", "", 0.0, false, nil)
    create = Kettle::Family::CommandResult.new("alpha", "reconcile_github_release", [], alpha.root, 0, true, "", "", 0.0, false, nil)
    runner = instance_double(Kettle::Family::CommandRunner)
    allow(Kettle::Family::ReleaseStateCheck).to receive(:new)
      .and_return(instance_double(Kettle::Family::ReleaseStateCheck, results: [release_state("alpha", latest_released: "1.2.3")]))
    allow(runner).to receive(:call).and_return(check, create)
    reconciler = described_class.new(config: nil, members: [alpha], execute: true, runner: runner)
    allow(reconciler).to receive(:kettle_gh_release_path).and_return("/tools/kettle-gh-release")

    results = reconciler.results

    expect(results).to eq([check, create])
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
end
