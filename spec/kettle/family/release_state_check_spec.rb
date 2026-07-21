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
      "ahead" => 3,
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
    expect(result.state).to include("latest_released" => "1.2.3", "ahead" => 3, "pending_release" => true)
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
    config = release_state_config(release_target_branches: %w[r1 r2])
    check = described_class.new(config: config, members: [member])
    branch_members = [member]
    allow(check).to receive_messages(git_root: @tmpdir, discover_branch_members: branch_members)
    allow(check).to receive(:with_branch_worktree).and_yield(@tmpdir)
    allow(check).to receive(:branch_latest_released).and_return("1.0.0", "1.0.1")
    allow(check).to receive(:commits_ahead_of_release).and_return(2, 3)
    allow(Open3).to receive(:capture3).and_return(
      [JSON.generate("gem_name" => "alpha", "version" => "1.0.1", "latest_released" => "9.0.0", "latest_changelog_version" => "1.0.0", "pending_release" => false), "", status(0, true)],
      [JSON.generate("gem_name" => "alpha", "version" => "1.0.2", "latest_released" => "9.0.0", "latest_changelog_version" => "1.0.1", "pending_release" => true), "", status(0, true)]
    )

    results = check.results

    expect(results.map(&:branch)).to eq(%w[r1 r2])
    expect(results.map { |result| result.state.fetch("version") }).to eq(%w[1.0.1 1.0.2])
    expect(results.map { |result| result.state.fetch("latest_released") }).to eq(%w[1.0.0 1.0.1])
    expect(results.map { |result| result.state.fetch("ahead") }).to eq([2, 3])
  end

  it "selects the latest release tag from the branch changelog major line" do
    repo = File.join(@tmpdir, "repo")
    run_git(repo, "init", "--quiet")
    run_git(repo, "config", "user.email", "kettle-family@example.test")
    run_git(repo, "config", "user.name", "Kettle Family")
    run_git(repo, "branch", "-M", "main")
    File.write(File.join(repo, "README.md"), "test\n")
    run_git(repo, "add", ".")
    run_git(repo, "commit", "--quiet", "-m", "Initial")
    %w[v2.0.0 v2.3.1 v24.0.2 v24.2.0].each { |tag| run_git(repo, "tag", "-m", tag, tag) }
    member = Kettle::Family::Member.new(name: "alpha", root: repo, gemspec_path: nil, version_file: nil, version: "2.4.0", dependencies: [])
    check = described_class.new(members: [member])

    expect(check.send(:branch_latest_released, member, "2.4.0")).to eq("2.3.1")
  end

  it "counts commits ahead of the release tag on the checked-out HEAD" do
    repo = File.join(@tmpdir, "repo")
    run_git(repo, "init", "--quiet")
    run_git(repo, "config", "user.email", "kettle-family@example.test")
    run_git(repo, "config", "user.name", "Kettle Family")
    File.write(File.join(repo, "README.md"), "main\n")
    run_git(repo, "add", ".")
    run_git(repo, "commit", "--quiet", "-m", "Initial")
    run_git(repo, "branch", "-M", "main")
    run_git(repo, "tag", "-m", "v1.0.0", "v1.0.0")
    run_git(repo, "checkout", "--quiet", "-b", "release-branch")
    File.write(File.join(repo, "README.md"), "release branch\n")
    run_git(repo, "commit", "--quiet", "-am", "Release branch change")
    File.write(File.join(repo, "README.md"), "release branch again\n")
    run_git(repo, "commit", "--quiet", "-am", "Second release branch change")
    run_git(repo, "checkout", "--quiet", "main")
    File.write(File.join(repo, "README.md"), "main branch\n")
    run_git(repo, "commit", "--quiet", "-am", "Main branch change")
    run_git(repo, "checkout", "--quiet", "release-branch")
    check = described_class.new(members: [])

    expect(check.send(:commits_ahead_of_release, repo, "1.0.0")).to eq(2)
  end

  it "enriches release state with current branch and local default ahead/behind counts" do
    repo = File.join(@tmpdir, "repo")
    run_git(repo, "init", "--quiet")
    run_git(repo, "config", "user.email", "kettle-family@example.test")
    run_git(repo, "config", "user.name", "Kettle Family")
    File.write(File.join(repo, "README.md"), "initial\n")
    run_git(repo, "add", ".")
    run_git(repo, "commit", "--quiet", "-m", "Initial")
    run_git(repo, "branch", "-M", "main")
    run_git(repo, "tag", "-m", "v1.0.0", "v1.0.0")
    File.write(File.join(repo, "README.md"), "main\n")
    run_git(repo, "commit", "--quiet", "-am", "Main change")
    run_git(repo, "switch", "--quiet", "-c", "feature")
    check = described_class.new(members: [])

    state = check.send(:enrich_git_state, repo, {
      "latest_released" => "1.0.0",
      "ahead" => 99
    })

    expect(state).to include(
      "current_branch" => "feature",
      "default_branch" => "main",
      "ahead" => 1,
      "behind" => 0
    )
  end

  it "enriches release state with divergent remote default ahead/behind counts" do
    repo = File.join(@tmpdir, "repo")
    remote = File.join(@tmpdir, "origin.git")
    run_git(remote, "init", "--quiet", "--bare")
    run_git(repo, "init", "--quiet")
    run_git(repo, "config", "user.email", "kettle-family@example.test")
    run_git(repo, "config", "user.name", "Kettle Family")
    File.write(File.join(repo, "README.md"), "initial\n")
    run_git(repo, "add", ".")
    run_git(repo, "commit", "--quiet", "-m", "Initial")
    run_git(repo, "branch", "-M", "main")
    run_git(repo, "tag", "-m", "v1.0.0", "v1.0.0")
    run_git(repo, "remote", "add", "origin", remote)
    run_git(repo, "push", "--quiet", "-u", "origin", "main")
    run_git(repo, "remote", "set-head", "origin", "main")
    File.write(File.join(repo, "README.md"), "local main\n")
    run_git(repo, "commit", "--quiet", "-am", "Local main change")
    check = described_class.new(members: [])

    state = check.send(:enrich_git_state, repo, {
      "latest_released" => "1.0.0"
    })

    expect(state).to include(
      "default_branch" => "main",
      "remote_default_branch" => "origin/main",
      "ahead" => 1,
      "behind" => 0,
      "remote_ahead" => 0,
      "remote_behind" => 0
    )
  end

  it "leaves branch release state unchanged when the line version is unavailable" do
    member = member("alpha")
    check = described_class.new(members: [member])
    state = {"latest_released" => "9.0.0"}

    expect(check.send(:branch_filtered_state, member, state, "r1")).to eq(state)
  end

  it "delegates to member-local release target branches when the active family config has none" do
    member = member("alpha")
    parent_config = release_state_config
    member_config = release_state_config(root: member.root, path: File.join(member.root, ".kettle-family.yml"), release_target_branches: %w[r1 r2])
    branch_result = instance_double(Kettle::Family::ReleaseStateResult)
    check = described_class.new(config: parent_config, members: [member])

    allow(Kettle::Family::Config).to receive(:load).with(root: member.root).and_return(member_config)
    member_check = instance_double(described_class, results: [branch_result])
    allow(described_class).to receive(:new).with(config: member_config, members: [member]).and_return(member_check)

    expect(check.results).to eq([branch_result])
  end

  it "uses root member release target branches before member-local release target branches" do
    member = member("alpha")
    parent_config = Kettle::Family::Config.new(
      root: @tmpdir,
      path: File.join(@tmpdir, ".kettle-family.yml"),
      data: {
        "release" => {
          "member_target_branches" => {
            "alpha" => %w[root-r1 root-r2]
          }
        }
      }
    )
    check = described_class.new(config: parent_config, members: [member])

    member_config = check.send(:member_local_release_config, member)

    expect(member_config.release_target_branches).to eq(%w[root-r1 root-r2])
    expect(member_config.root).to eq(member.root)
  end

  it "loads member-local release target branches from another local branch when the active branch lacks config" do
    repo = File.join(@tmpdir, "repo")
    member_root = File.join(repo, "alpha")
    FileUtils.mkdir_p(member_root)
    run_git(repo, "init", "--quiet")
    run_git(repo, "config", "user.email", "kettle-family@example.test")
    run_git(repo, "config", "user.name", "Kettle Family")
    File.write(File.join(member_root, "alpha.gemspec"), "Gem::Specification.new { |spec| spec.name = 'alpha' }\n")
    run_git(repo, "add", ".")
    run_git(repo, "commit", "--quiet", "-m", "Initial")
    run_git(repo, "switch", "--quiet", "-c", "branch-stack-config")
    File.write(File.join(member_root, ".kettle-family.yml"), <<~YAML)
      release:
        target_branches:
          - r1
          - r2
    YAML
    run_git(repo, "add", ".")
    run_git(repo, "commit", "--quiet", "-m", "Add member branch stack")
    run_git(repo, "switch", "--quiet", "-")

    member = Kettle::Family::Member.new(name: "alpha", root: member_root, gemspec_path: nil, version_file: nil, version: "1.0.0", dependencies: [])
    parent_config = release_state_config(root: repo)
    check = described_class.new(config: parent_config, members: [member])

    member_config = check.send(:member_local_release_config, member)

    expect(member_config.path).to eq("branch-stack-config:alpha/.kettle-family.yml")
    expect(member_config.release_target_branches).to eq(%w[r1 r2])
  end

  it "reports configured branch worktree failures as branch results" do
    member = member("alpha")
    config = release_state_config(release_target_branches: %w[r1])
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
    config = release_state_config
    check = described_class.new(config: config, members: [])
    allow(Open3).to receive(:capture3).and_return(["#{@tmpdir}\n", "", status(0, true)])

    expect(check.send(:git_root)).to eq(File.realpath(@tmpdir))

    allow(Open3).to receive(:capture3).and_return(["", "not a git repo", status(128, false)])
    expect {
      check.send(:git_root)
    }.to raise_error(Kettle::Family::Error, /could not determine git root/)
  end

  it "adds and removes temporary branch worktrees" do
    config = release_state_config
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

  it "checks a shared root changelog once for the family" do
    FileUtils.mkdir_p(File.join(@tmpdir, "gems", "tree_haver", "lib", "tree_haver"))
    File.write(File.join(@tmpdir, "CHANGELOG.md"), <<~MARKDOWN)
      ## [Unreleased]

      ### Fixed

      - Pending fix.

      ## [7.0.0] - 2026-05-05
    MARKDOWN
    File.write(File.join(@tmpdir, "gems", "tree_haver", "lib", "tree_haver", "version.rb"), <<~RUBY)
      module TreeHaver
        VERSION = "7.0.0"
      end
    RUBY
    File.write(File.join(@tmpdir, ".kettle-family.yml"), <<~YAML)
      family:
        name: structuredmerge-ruby
      changelog:
        mode: root
        path: CHANGELOG.md
        version_file: gems/tree_haver/lib/tree_haver/version.rb
    YAML
    config = Kettle::Family::Config.load(root: @tmpdir)
    member = member("alpha")

    result = described_class.new(config: config, members: [member]).results.fetch(0)

    expect(result).to be_ok
    expect(result.member_name).to eq("structuredmerge-ruby")
    expect(result.workdir).to eq(@tmpdir)
    expect(result.command).to eq(["internal", "release-state", "root-changelog"])
    expect(result.state).to include(
      "gem_name" => "structuredmerge-ruby",
      "version" => "7.0.0",
      "latest_changelog_version" => "7.0.0",
      "ahead" => nil,
      "unreleased_entries" => true,
      "prepared_release_pending" => true,
      "pending_release" => true
    )
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

    root_config = release_state_config(root: git_root)
    root_check = described_class.new(config: root_config, members: [])
    allow(root_check).to receive(:git_root).and_return(File.realpath(git_root))
    expect(root_check.send(:relative_config_root)).to eq(".")

    subdir_config = release_state_config(root: subdir)
    subdir_check = described_class.new(config: subdir_config, members: [])
    allow(subdir_check).to receive(:git_root).and_return(File.realpath(git_root))
    expect(subdir_check.send(:relative_config_root)).to eq("gems")

    outside_config = release_state_config(root: outside)
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

  def release_state_config(root: @tmpdir, path: nil, release_target_branches: [])
    instance_double(
      Kettle::Family::Config,
      root: root,
      path: path,
      release_target_branches: release_target_branches,
      shared_changelog?: false,
      changelog_workdir: nil,
      changelog_env: {}
    )
  end

  def run_git(path, *args)
    FileUtils.mkdir_p(path)
    stdout, stderr, status = Open3.capture3("git", *args, chdir: path)
    raise "git #{args.join(" ")} failed: #{stderr}#{stdout}" unless status.success?

    stdout
  end
end
