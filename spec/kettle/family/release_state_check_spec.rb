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
    expect(result.command).to include("-S", "kettle-changelog", "--release-state", "--json")
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

  it "reports invalid release state JSON as a failed result" do
    member = member("alpha")
    allow(Open3).to receive(:capture3).and_return(["not-json", "", status(0, true)])

    result = described_class.new(members: [member]).results.fetch(0)

    expect(result).not_to be_ok
    expect(result.status).to eq(1)
    expect(result.reason).to start_with("invalid release-state JSON:")
    expect(result.stdout).to eq("not-json")
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

  it "reports configured branch worktree failures as branch results" do
    member = member("alpha")
    config = instance_double(Kettle::Family::Config, root: @tmpdir, release_target_branches: %w[r1])
    check = described_class.new(config: config, members: [member])
    allow(check).to receive(:git_root).and_return(@tmpdir)
    allow(check).to receive(:with_branch_worktree).and_raise(Kettle::Family::Error, "missing branch")

    result = check.results.fetch(0)

    expect(result.member_name).to eq("r1")
    expect(result.branch).to eq("r1")
    expect(result.reason).to eq("branch release state failed")
    expect(result.stderr).to eq("missing branch")
  end

  it "computes git roots and reports git failures" do
    config = instance_double(Kettle::Family::Config, root: @tmpdir, release_target_branches: [])
    check = described_class.new(config: config, members: [])
    allow(Open3).to receive(:capture3).and_return(["#{@tmpdir}\n", "", status(0, true)])

    expect(check.send(:git_root)).to eq(File.realpath(@tmpdir))

    allow(Open3).to receive(:capture3).and_return(["", "not a git repo", status(128, false)])
    expect {
      check.send(:git_root)
    }.to raise_error(Kettle::Family::Error, /could not determine git root/)
  end

  it "adds and removes temporary branch worktrees" do
    config = instance_double(Kettle::Family::Config, root: @tmpdir, release_target_branches: [])
    check = described_class.new(config: config, members: [])
    allow(SecureRandom).to receive(:hex).and_return("abc123")
    allow(check).to receive(:add_branch_worktree)
    allow(check).to receive(:remove_branch_worktree)

    yielded = nil
    check.send(:with_branch_worktree, root: @tmpdir, branch: "main") { |path| yielded = path }

    expect(yielded).to end_with("tmp/kettle-family-release-state/worktree-#{Process.pid}-abc123")
    expect(check).to have_received(:add_branch_worktree).with(root: @tmpdir, branch: "main", worktree_root: yielded)
    expect(check).to have_received(:remove_branch_worktree).with(root: @tmpdir, worktree_root: yielded)
  end

  it "raises when git cannot add a branch worktree" do
    check = described_class.new(members: [])
    allow(Open3).to receive(:capture3).and_return(["", "unknown revision", status(128, false)])

    expect {
      check.send(:add_branch_worktree, root: @tmpdir, branch: "missing", worktree_root: File.join(@tmpdir, "worktree"))
    }.to raise_error(Kettle::Family::Error, /could not add worktree for missing/)
  end

  it "removes existing branch worktrees and ignores missing ones" do
    check = described_class.new(members: [])
    worktree_root = File.join(@tmpdir, "worktree")
    allow(Open3).to receive(:capture3)

    check.send(:remove_branch_worktree, root: @tmpdir, worktree_root: worktree_root)
    expect(Open3).not_to have_received(:capture3)

    FileUtils.mkdir_p(worktree_root)
    check.send(:remove_branch_worktree, root: @tmpdir, worktree_root: worktree_root)
    expect(Open3).to have_received(:capture3).with("git", "worktree", "remove", "--force", worktree_root, chdir: @tmpdir)
  end

  it "computes config roots relative to the git root" do
    git_root = File.join(@tmpdir, "repo")
    subdir = File.join(git_root, "gems")
    outside = File.join(@tmpdir, "outside")
    FileUtils.mkdir_p([subdir, outside])

    root_config = instance_double(Kettle::Family::Config, root: git_root, release_target_branches: [])
    root_check = described_class.new(config: root_config, members: [])
    allow(root_check).to receive(:git_root).and_return(File.realpath(git_root))
    expect(root_check.send(:relative_config_root)).to eq(".")

    subdir_config = instance_double(Kettle::Family::Config, root: subdir, release_target_branches: [])
    subdir_check = described_class.new(config: subdir_config, members: [])
    allow(subdir_check).to receive(:git_root).and_return(File.realpath(git_root))
    expect(subdir_check.send(:relative_config_root)).to eq("gems")

    outside_config = instance_double(Kettle::Family::Config, root: outside, release_target_branches: [])
    outside_check = described_class.new(config: outside_config, members: [])
    allow(outside_check).to receive(:git_root).and_return(File.realpath(git_root))
    expect {
      outside_check.send(:relative_config_root)
    }.to raise_error(Kettle::Family::Error, /is outside git root/)
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
