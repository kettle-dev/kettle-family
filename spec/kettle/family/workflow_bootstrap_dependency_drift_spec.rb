# frozen_string_literal: true

require "fileutils"
require "tmpdir"
require "yaml"

RSpec.describe Kettle::Family::Workflow do
  around do |example|
    Dir.mktmpdir("kettle-family-drift-spec") do |dir|
      @tmpdir = dir
      example.run
    end
  end

  before do
    Kettle::Family.mise_adapter = build_mise_adapter(executable: "mise")
  end

  def write_config(drift_gems: :unset, family: nil)
    release = {"build_command" => [RbConfig.ruby, "-e", "puts 'build'"]}
    release["drift_check"] = {"gems" => drift_gems} unless drift_gems == :unset
    config = {"release" => release}
    config["family"] = family if family
    File.write(File.join(@tmpdir, ".kettle-family.yml"), YAML.dump(config))
    Kettle::Family::Config.load(root: @tmpdir)
  end

  def member_at(name, lockfile: nil)
    root = File.join(@tmpdir, name)
    FileUtils.mkdir_p(root)
    File.write(File.join(root, "Gemfile.lock"), lockfile) if lockfile
    Kettle::Family::Member.new(
      name: name,
      root: root,
      gemspec_path: File.join(root, "#{name}.gemspec"),
      version: "1.0.0",
      dependencies: []
    )
  end

  # The lockfile shape from the 2026-10-30 incident: a loose declared floor
  # (~> 1.1, >= 1.1.16) with the committed lock pinning the floor itself.
  def drift_lock
    <<~LOCK
      GEM
        remote: https://gem.coop/
        specs:
          nomono (1.1.16)

      PLATFORMS
        ruby

      DEPENDENCIES
        nomono (~> 1.1, >= 1.1.16)

      BUNDLED WITH
         2.6
    LOCK
  end

  def stub_registry(versions)
    allow(Kettle::Dev::RubyGemsVersions).to receive(:published_version_numbers).and_return(versions)
  end

  def workflow_for(config:, members:)
    described_class.new(command: "release", config: config, members: members)
  end

  it "blocks the release when the lock lags a published version satisfying the declared floor" do
    config = write_config
    member = member_at("alpha", lockfile: drift_lock)
    workflow = workflow_for(config: config, members: [member])
    stub_registry(%w[1.1.16 1.1.17])

    results = workflow.send(:release_preflight_bootstrap_drift_results)

    expect(results.length).to eq(1)
    result = results.first
    expect(result).not_to be_ok
    expect(result.phase).to eq("bootstrap_dependency_drift")
    expect(result.member_name).to eq("alpha")
    expect(result.stderr).to include("locks nomono 1.1.16 but 1.1.17 satisfies its floor")
    expect(result.stderr).to include("run the family template sweep or `bundle update nomono`")
  end

  it "passes when the lock pins the newest published version satisfying the floor" do
    config = write_config
    member = member_at("alpha", lockfile: drift_lock.sub("nomono (1.1.16)", "nomono (1.1.17)"))
    workflow = workflow_for(config: config, members: [member])
    stub_registry(%w[1.1.16 1.1.17])

    expect(workflow.send(:release_preflight_bootstrap_drift_results)).to be_empty
  end

  it "ignores published versions that do not satisfy the declared floor" do
    config = write_config
    member = member_at("alpha", lockfile: drift_lock.sub("nomono (1.1.16)", "nomono (1.1.17)"))
    workflow = workflow_for(config: config, members: [member])
    stub_registry(%w[1.1.16 1.1.17 2.0.0])

    expect(workflow.send(:release_preflight_bootstrap_drift_results)).to be_empty
  end

  it "ignores prerelease versions when picking the newest satisfying release" do
    config = write_config
    member = member_at("alpha", lockfile: drift_lock)
    workflow = workflow_for(config: config, members: [member])
    stub_registry(%w[1.1.16 1.2.0.rc1])

    expect(workflow.send(:release_preflight_bootstrap_drift_results)).to be_empty
  end

  # Fail-open is load-bearing: a registry outage must not turn every member
  # of a family release into a false block.
  it "skips without blocking when the registry cannot be consulted" do
    config = write_config
    member = member_at("alpha", lockfile: drift_lock)
    workflow = workflow_for(config: config, members: [member])
    allow(Kettle::Dev::RubyGemsVersions).to receive(:published_version_numbers).and_return(nil)
    allow(workflow).to receive(:warn)

    expect(workflow.send(:release_preflight_bootstrap_drift_results)).to be_empty
    expect(workflow).to have_received(:warn).with(/drift check skipped for nomono: registry could not be consulted/)
  end

  it "skips members without a lockfile or without the gem locked" do
    config = write_config
    no_lock = member_at("alpha")
    other_gem = member_at("beta", lockfile: drift_lock.sub("nomono", "other-gem"))
    workflow = workflow_for(config: config, members: [no_lock, other_gem])

    expect(workflow.send(:release_preflight_bootstrap_drift_results)).to be_empty
  end

  # A PATH-sourced pin is local-only state: it has no published counterpart
  # to drift against, and blocking on it would false-positive every
  # local-path development checkout.
  it "ignores a PATH-sourced pin of the gem" do
    config = write_config
    member = member_at("alpha", lockfile: <<~LOCK)
      PATH
        remote: /var/home/example/src/my/kettle-dev/kettle-rb
        specs:
          nomono (1.1.16)

      DEPENDENCIES
        nomono (~> 1.1, >= 1.1.16)
    LOCK
    workflow = workflow_for(config: config, members: [member])
    stub_registry(%w[1.1.16 1.1.17])

    expect(workflow.send(:release_preflight_bootstrap_drift_results)).to be_empty
  end

  it "checks every selected member and reports only the drifting ones" do
    config = write_config
    current = member_at("alpha", lockfile: drift_lock.sub("nomono (1.1.16)", "nomono (1.1.17)"))
    drifting = member_at("beta", lockfile: drift_lock)
    workflow = workflow_for(config: config, members: [current, drifting])
    stub_registry(%w[1.1.16 1.1.17])

    results = workflow.send(:release_preflight_bootstrap_drift_results)

    expect(results.map(&:member_name)).to eq(["beta"])
  end

  describe "phase wiring" do
    it "defaults to checking nomono" do
      config = write_config

      expect(config.release_drift_check_gems).to eq(["nomono"])
    end

    it "runs after the version bump phase and before secrets authorization" do
      config = write_config
      member = member_at("alpha")
      release_state = Kettle::Family::ReleaseStateResult.new(
        member_name: "alpha",
        command: %w[kettle-changelog --release-state --json],
        workdir: member.root,
        status: 0,
        success: true,
        stdout: "",
        stderr: "",
        elapsed_seconds: 0.0,
        state: {}
      )
      workflow = described_class.new(
        command: "release",
        config: config,
        members: [member],
        release_state_results: [release_state],
        secrets_provider: Kettle::Family::Secrets::OnePassword.new({})
      )

      labels = workflow.send(:release_preflight_phases).map { |phase| phase[:label] }

      expect(labels).to include("bootstrap dependency drift")
      expect(labels.index("release version bump")).to be < labels.index("bootstrap dependency drift")
      expect(labels.index("bootstrap dependency drift")).to be < labels.index("secrets provider authorization")
    end

    it "omits the phase when drift checking is disabled by an empty gem list" do
      config = write_config(drift_gems: [])
      workflow = workflow_for(config: config, members: [member_at("alpha")])

      expect(workflow.send(:release_preflight_phases).map { |phase| phase[:label] }).not_to include("bootstrap dependency drift")
    end

    it "honors a configured gem list" do
      config = write_config(drift_gems: %w[other-gem])

      expect(config.release_drift_check_gems).to eq(%w[other-gem])
    end
  end
end
