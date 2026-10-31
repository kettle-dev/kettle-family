# frozen_string_literal: true

require "fileutils"
require "tmpdir"

RSpec.describe Kettle::Family::ReleaseStateCheck do
  around do |example|
    Dir.mktmpdir("kettle-family-independent-state-spec") do |dir|
      @tmpdir = dir
      example.run
    end
  end

  # Independently versioned members (release.version_series.
  # independent_members) must never be captured by lockstep bump
  # normalization: not force-marked pending by the shared cohort, and their
  # own (possibly higher) series version must not drag the cohort line
  # (#18).
  def independent_config(members:)
    config = instance_double(
      Kettle::Family::Config,
      release_aggregate_validation_excluded_members: [],
      release_version_series_independent_members: members
    )
    allow(config).to receive(:independent_version_series_member?) do |member|
      members.include?(member.name.to_s)
    end
    config
  end

  def member(name)
    root = File.join(@tmpdir, name)
    FileUtils.mkdir_p(root)
    Kettle::Family::Member.new(name: name, root: root, gemspec_path: nil, version_file: nil, version: "1.0.0", dependencies: [])
  end

  def release_state_result(member_name, state)
    Kettle::Family::ReleaseStateResult.new(
      member_name: member_name,
      command: [],
      workdir: member_name,
      status: 0,
      success: true,
      stdout: "",
      stderr: "",
      elapsed_seconds: 0.0,
      state: state
    )
  end

  it "does not force-mark an independent-series member pending when the shared cohort owes a bump" do
    config = independent_config(members: ["indy"])
    check = described_class.new(members: [member("alpha"), member("beta"), member("indy")], config: config)
    results = [
      release_state_result("alpha", "version" => "1.0.0", "latest_released" => "1.0.0", "unreleased_entries" => true, "bump_release_pending" => true),
      release_state_result("beta", "version" => "1.0.0", "latest_released" => "1.0.0", "unreleased_entries" => true, "bump_release_pending" => true),
      release_state_result("indy", "version" => "2.0.0", "latest_released" => "2.0.0", "unreleased_entries" => false, "bump_release_pending" => false)
    ]

    normalized = check.send(:normalize_shared_version_bump, results)
    normalized = check.send(:normalize_lockstep_version_bump, normalized)

    expect(normalized.map { |result| result.state["bump_release_pending"] }).to eq([true, true, false])
  end

  it "keeps an independent-series member's higher version from dragging the shared cohort line" do
    config = independent_config(members: ["indy"])
    check = described_class.new(members: [member("alpha"), member("indy")], config: config)
    # The independent member is mid-release on its own line; without the
    # exclusion its 2.0.0 became the cohort maximum and made alpha look
    # perpetually behind, force-marking it for a catch-up bump it did not
    # need.
    results = [
      release_state_result("alpha", "version" => "1.0.0", "latest_released" => "1.0.0", "unreleased_entries" => false, "bump_release_pending" => false),
      release_state_result("indy", "version" => "2.0.0", "latest_released" => "1.9.0", "unreleased_entries" => true, "bump_release_pending" => false)
    ]

    normalized = check.send(:normalize_lockstep_version_bump, results)

    expect(normalized.map { |result| result.state["bump_release_pending"] }).to eq([false, false])
  end

  it "keeps an independent-series member without a local changelog out of shared bump propagation" do
    config = independent_config(members: ["indy"])
    allow(config).to receive(:shared_changelog?).and_return(true)
    check = described_class.new(members: [member("alpha"), member("indy")], config: config)
    results = [
      release_state_result("alpha", "version" => "1.0.0", "latest_released" => "1.0.0", "unreleased_entries" => true, "bump_release_pending" => true),
      release_state_result("indy", "version" => "2.0.0", "latest_released" => "2.0.0", "unreleased_entries" => false, "bump_release_pending" => false)
    ]

    normalized = check.send(:normalize_shared_version_bump, results)

    expect(normalized.map { |result| result.state["bump_release_pending"] }).to eq([true, false])
  end

  it "still marks independent members pending from their own unreleased entries" do
    config = independent_config(members: ["indy"])
    check = described_class.new(members: [member("alpha"), member("indy")], config: config)
    results = [
      release_state_result("alpha", "version" => "1.0.0", "latest_released" => "1.0.0", "unreleased_entries" => false, "bump_release_pending" => false),
      release_state_result("indy", "version" => "2.0.0", "latest_released" => "2.0.0", "unreleased_entries" => true, "bump_release_pending" => true)
    ]

    normalized = check.send(:normalize_lockstep_version_bump, results)

    expect(normalized.map { |result| result.state["bump_release_pending"] }).to eq([false, true])
  end
end
