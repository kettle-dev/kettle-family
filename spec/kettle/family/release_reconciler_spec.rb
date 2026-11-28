# frozen_string_literal: true

require "fileutils"
require "tmpdir"

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

  it "attaches local gem and checksum assets when backfilling a missing GitHub Release" do
    Dir.mktmpdir("kettle-family-reconciler-assets") do |dir|
      root = File.join(dir, "kettle-jem")
      FileUtils.mkdir_p(File.join(root, "pkg"))
      FileUtils.mkdir_p(File.join(root, "checksums"))
      gem_path = File.join(root, "pkg", "kettle-jem-7.1.44.gem")
      sha256_path = File.join(root, "checksums", "kettle-jem-7.1.44.gem.sha256")
      sha512_path = File.join(root, "checksums", "kettle-jem-7.1.44.gem.sha512")
      File.write(gem_path, "gem\n")
      File.write(sha256_path, "sha256\n")
      File.write(sha512_path, "sha512\n")

      kettle_jem = Kettle::Family::Member.new(
        name: "kettle-jem",
        root: root,
        gemspec_path: nil,
        version_file: nil,
        version: "7.1.44",
        dependencies: []
      )
      check = Kettle::Family::CommandResult.new("kettle-jem", "reconcile_github_release_check", [], root, 0, true, "{\"type\":\"github_release\",\"message\":\"ready\"}\n", "", 0.0, false, nil)
      create = Kettle::Family::CommandResult.new("kettle-jem", "reconcile_github_release", [], root, 0, true, "", "", 0.0, false, nil)
      runner = instance_double(Kettle::Family::CommandRunner)
      allow(Kettle::Family::ReleaseStateCheck).to receive(:new)
        .and_return(instance_double(Kettle::Family::ReleaseStateCheck, results: [release_state("kettle-jem", latest_released: "7.1.44")]))
      allow(runner).to receive(:call).and_return(check, create)
      reconciler = described_class.new(config: nil, members: [kettle_jem], execute: true, runner: runner)
      allow(reconciler).to receive(:kettle_gh_release_path).and_return("/tools/kettle-gh-release")

      reconciler.results

      expect(runner).to have_received(:call).with(
        member: kettle_jem,
        phase: "reconcile_github_release",
        command: [
          RbConfig.ruby,
          "/tools/kettle-gh-release",
          "--release-version",
          "7.1.44",
          "--events",
          "--asset",
          gem_path,
          "--asset",
          sha256_path,
          "--asset",
          sha512_path
        ]
      )
    end
  end
end
