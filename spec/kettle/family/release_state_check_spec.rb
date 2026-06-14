# frozen_string_literal: true

require "fileutils"
require "json"
require "tmpdir"

RSpec.describe Kettle::Family::ReleaseStateCheck do
  around do |example|
    Dir.mktmpdir("kettle-family-release-state-spec") do |dir|
      @tmpdir = dir
      example.run
    end
  end

  it "collects release state JSON for each member using the active kettle-dev API" do
    member = member("alpha")
    state = {
      "gem_name" => "alpha",
      "version" => "1.2.4",
      "latest_released" => "1.2.3",
      "latest_changelog_version" => "1.2.4",
      "unreleased_entries" => false,
      "prepared_release_pending" => true,
      "pending_release" => true
    }
    allow(Open3).to receive(:capture3).and_return([JSON.generate(state), "", status(0, true)])

    result = described_class.new(members: [member]).results.fetch(0)

    expect(result).to be_ok
    expect(result.command.first).to eq(RbConfig.ruby)
    expect(result.command).to include("-e")
    expect(result.workdir).to eq(member.root)
    expect(result.state).to include("latest_released" => "1.2.3", "pending_release" => true)
  end

  it "reports command failures without treating pending release work as an error" do
    member = member("alpha")
    allow(Open3).to receive(:capture3).and_return(["", "boom", status(1, false)])

    result = described_class.new(members: [member]).results.fetch(0)

    expect(result).not_to be_ok
    expect(result.reason).to eq("release state check failed")
    expect(result.stderr).to eq("boom")
  end

  it "checks each configured release target branch independently" do
    member = member("alpha")
    config = instance_double(Kettle::Family::Config, root: @tmpdir, release_target_branches: %w[r1 r2])
    check = described_class.new(config: config, members: [member])
    branch_members = [member]
    allow(check).to receive_messages(git_root: @tmpdir, discover_branch_members: branch_members)
    allow(check).to receive(:with_branch_worktree).and_yield(@tmpdir)
    allow(Open3).to receive(:capture3).and_return(
      [JSON.generate("gem_name" => "alpha", "version" => "1.0.1", "pending_release" => false), "", status(0, true)],
      [JSON.generate("gem_name" => "alpha", "version" => "1.0.2", "pending_release" => true), "", status(0, true)]
    )

    results = check.results

    expect(results.map(&:branch)).to eq(%w[r1 r2])
    expect(results.map { |result| result.state.fetch("version") }).to eq(%w[1.0.1 1.0.2])
  end

  def member(name)
    root = File.join(@tmpdir, name)
    FileUtils.mkdir_p(root)
    Kettle::Family::Member.new(name: name, root: root, gemspec_path: nil, version_file: nil, version: "1.0.0", dependencies: [])
  end

  def status(exitstatus, success)
    instance_double(Process::Status, exitstatus: exitstatus, success?: success)
  end
end
