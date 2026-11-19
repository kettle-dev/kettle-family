# frozen_string_literal: true

require "fileutils"
require "open3"
require "tmpdir"

RSpec.describe Kettle::Family::BranchCheckoutCheck do
  around do |example|
    Dir.mktmpdir("kettle-family-branch-checkout-spec") do |dir|
      @tmpdir = dir
      example.run
    end
  end

  before do
    hide_env("K_JEM_TEMPLATING", "BRANCH_SPEC_DEV")
    write_config
  end

  describe ".gated?" do
    it "gates member-mutating commands" do
      expect(described_class.gated?("template")).to be(true)
      expect(described_class.gated?("bup")).to be(true)
      expect(described_class.gated?("bump")).to be(true)
    end

    it "never gates release, which checks out its own target lanes, nor read-only commands" do
      %w[release check test lint bex install bupb update-bundler].each do |command|
        expect(described_class.gated?(command)).to be(false), "expected #{command} to be ungated"
      end
    end
  end

  describe ".call" do
    it "passes when every member is on its default branch" do
      alpha = member("alpha", root: make_repo("alpha"))
      beta = member("beta", root: make_repo("beta"))

      result = check(members: [alpha, beta])

      expect(result).to be_ok
      expect(result.diagnostics).to be_empty
    end

    it "fails when a member is on an unexpected branch, naming current, expected, and the override" do
      alpha = member("alpha", root: make_repo("alpha", branches: ["feat/wip"], current: "feat/wip"))

      result = check(members: [alpha])

      expect(result).not_to be_ok
      expect(result.member_name).to eq(config.family_name)
      expect(result.phase).to eq("branch_checkout_check")
      expect(result.stdout).to include("alpha", "feat/wip", "main", "--branch alpha:feat/wip")
      expect(result.diagnostics).to match([hash_including("kind" => "unexpected_branch", "member" => "alpha")])
    end

    it "passes when the member is on a configured member_target_branches lane" do
      write_config("release:\n  member_target_branches:\n    alpha:\n      - 1-4-stable\n")
      alpha = member("alpha", root: make_repo("alpha", branches: ["1-4-stable"], current: "1-4-stable"))

      result = check(members: [alpha])

      expect(result).to be_ok
    end

    it "passes when the member is on a member-local release target branch" do
      root = make_repo("alpha", branches: ["1-4-stable"], current: "1-4-stable")
      File.write(File.join(root, ".kettle-family.yml"), "release:\n  target_branches:\n    - 1-4-stable\n")
      git(root, "add", ".kettle-family.yml")
      git(root, "commit", "-m", "lane config")
      alpha = member("alpha", root: root)

      result = check(members: [alpha])

      expect(result).to be_ok
    end

    it "passes when the member is on a configured branch lane" do
      write_config("branch_lanes:\n  ruby-3-4:\n    branch: ruby-3-4\n    version: 3.4.0\n    members:\n      - alpha\n")
      alpha = member("alpha", root: make_repo("alpha", branches: ["ruby-3-4"], current: "ruby-3-4"))

      result = check(members: [alpha])

      expect(result).to be_ok
    end

    it "fails on a detached HEAD" do
      alpha = member("alpha", root: make_repo("alpha", detach: true))

      result = check(members: [alpha])

      expect(result).not_to be_ok
      expect(result.stdout).to include("alpha", "detached HEAD")
      expect(result.diagnostics).to match([hash_including("kind" => "detached_head", "member" => "alpha")])
    end

    it "allows the current branch when named in an override" do
      alpha = member("alpha", root: make_repo("alpha", branches: ["feat/wip"], current: "feat/wip"))

      result = check(members: [alpha], overrides: {"alpha" => "feat/wip"})

      expect(result).to be_ok
    end

    it "skips members that are not git repositories" do
      root = File.join(@tmpdir, "alpha")
      FileUtils.mkdir_p(root)
      alpha = member("alpha", root: root)

      result = check(members: [alpha])

      expect(result).to be_ok
    end

    it "skips branch enforcement when no default branch is determinable" do
      alpha = member("alpha", root: make_repo("alpha", branches: ["feat/wip"], current: "feat/wip", origin_head: false))

      result = check(members: [alpha])

      expect(result).to be_ok
    end

    it "skips branch enforcement when lanes are configured but no default branch is determinable" do
      write_config("release:\n  member_target_branches:\n    alpha:\n      - 1-4-stable\n")
      alpha = member("alpha", root: make_repo("alpha", branches: ["feat/wip"], current: "feat/wip", origin_head: false))

      result = check(members: [alpha])

      expect(result).to be_ok
    end

    it "reports a detached HEAD without a switch hint when no default is determinable" do
      alpha = member("alpha", root: make_repo("alpha", origin_head: false, detach: true))

      result = check(members: [alpha])

      expect(result).not_to be_ok
      expect(result.stdout).to include("detached HEAD", "the default branch")
      expect(result.stdout).not_to include("git -C")
    end

    it "falls back to `git remote show origin` when the origin/HEAD symref is unset" do
      root = make_repo("alpha")
      origin = File.join(@tmpdir, "origin.git")
      system("git", "init", "--bare", origin, out: File::NULL, err: File::NULL) || raise("git init --bare failed")
      git(root, "remote", "add", "origin", origin)
      git(root, "push", "-u", "origin", "main")
      git(root, "symbolic-ref", "--delete", "refs/remotes/origin/HEAD")
      git(root, "switch", "-c", "feat/wip")
      alpha = member("alpha", root: root)

      result = check(members: [alpha])

      expect(result).not_to be_ok
      expect(result.stdout).to include("feat/wip", "main")
    end

    it "fails when a sibling checkout cannot satisfy a member requirement under local wiring" do
      stub_env("K_JEM_TEMPLATING" => "true")
      write_config("members:\n  roots:\n    - alpha\n    - beta\n")
      alpha_root = make_repo("alpha")
      beta_root = make_repo("beta", branches: ["1-4-stable"], current: "1-4-stable")
      alpha = member("alpha", root: alpha_root, runtime_dependencies: [["beta", "~> 2.0"]])
      member("beta", root: beta_root, version: "1.4.12", runtime_dependencies: [])

      result = check(members: [alpha])

      expect(result).not_to be_ok
      expect(result.stdout).to include("alpha", "beta", "~> 2.0", "1.4.12", "1-4-stable")
      expect(result.diagnostics).to match([hash_including("kind" => "sibling_version_mismatch", "member" => "alpha", "sibling" => "beta")])
    end

    it "passes when the sibling checkout satisfies the requirement" do
      stub_env("K_JEM_TEMPLATING" => "true")
      write_config("members:\n  roots:\n    - alpha\n    - beta\n")
      alpha_root = make_repo("alpha")
      beta_root = make_repo("beta")
      alpha = member("alpha", root: alpha_root, runtime_dependencies: [["beta", "~> 2.0"]])
      member("beta", root: beta_root, version: "2.1.0", runtime_dependencies: [])

      result = check(members: [alpha])

      expect(result).to be_ok
    end

    it "treats the family local-path env as local wiring" do
      stub_env("BRANCH_SPEC_DEV" => @tmpdir)
      write_config("members:\n  roots:\n    - alpha\n    - beta\n")
      alpha_root = make_repo("alpha")
      beta_root = make_repo("beta")
      alpha = member("alpha", root: alpha_root, runtime_dependencies: [["beta", "~> 2.0"]])
      member("beta", root: beta_root, version: "1.4.12", runtime_dependencies: [])

      result = check(members: [alpha])

      expect(result).not_to be_ok
    end

    it "skips sibling satisfiability when local wiring is inactive, even with a mismatch" do
      write_config("members:\n  roots:\n    - alpha\n    - beta\n")
      alpha_root = make_repo("alpha")
      beta_root = make_repo("beta")
      alpha = member("alpha", root: alpha_root, runtime_dependencies: [["beta", "~> 2.0"]])
      member("beta", root: beta_root, version: "1.4.12", runtime_dependencies: [])

      result = check(members: [alpha])

      expect(result).to be_ok
    end

    it "treats falsey toggle values as inactive" do
      stub_env("K_JEM_TEMPLATING" => "false", "BRANCH_SPEC_DEV" => "0")
      write_config("members:\n  roots:\n    - alpha\n    - beta\n")
      alpha_root = make_repo("alpha")
      beta_root = make_repo("beta")
      alpha = member("alpha", root: alpha_root, runtime_dependencies: [["beta", "~> 2.0"]])
      member("beta", root: beta_root, version: "1.4.12", runtime_dependencies: [])

      result = check(members: [alpha])

      expect(result).to be_ok
    end

    it "ignores dependencies that are not family members" do
      stub_env("K_JEM_TEMPLATING" => "true")
      write_config("members:\n  roots:\n    - alpha\n")
      alpha_root = make_repo("alpha")
      alpha = member("alpha", root: alpha_root, runtime_dependencies: [["rails", "~> 8.0"]])

      result = check(members: [alpha])

      expect(result).to be_ok
    end

    it "skips satisfiability for a member whose gemspec cannot be loaded" do
      stub_env("K_JEM_TEMPLATING" => "true")
      write_config("members:\n  roots:\n    - beta\n")
      alpha_root = make_repo("alpha")
      beta_root = make_repo("beta")
      member("beta", root: beta_root, version: "1.4.12", runtime_dependencies: [])
      gemspec_path = File.join(alpha_root, "alpha.gemspec")
      File.write(gemspec_path, 'raise "broken gemspec"')
      alpha = Kettle::Family::Member.new(name: "alpha", root: alpha_root, gemspec_path: gemspec_path, version_file: nil, version: "1.0.0", dependencies: [])

      result = check(members: [alpha])

      expect(result).to be_ok
    end

    it "skips a sibling whose version is blank" do
      stub_env("K_JEM_TEMPLATING" => "true")
      write_config("members:\n  roots:\n    - beta\n")
      alpha_root = make_repo("alpha")
      beta_root = make_repo("beta")
      member("beta", root: beta_root, version: "1.4.12", runtime_dependencies: [])
      alpha = member("alpha", root: alpha_root, runtime_dependencies: [["beta", "~> 2.0"]])
      check_instance = described_class.new(config: config, members: [alpha])
      blank = Kettle::Family::Member.new(name: "beta", root: beta_root, gemspec_path: nil, version_file: nil, version: "", dependencies: [])
      allow(check_instance).to receive(:all_members_by_name).and_return({"beta" => blank})

      result = check_instance.call

      expect(result).to be_ok
    end

    it "skips a sibling whose version is unparseable" do
      stub_env("K_JEM_TEMPLATING" => "true")
      write_config("members:\n  roots:\n    - beta\n")
      alpha_root = make_repo("alpha")
      beta_root = make_repo("beta")
      member("beta", root: beta_root, version: "1.4.12", runtime_dependencies: [])
      alpha = member("alpha", root: alpha_root, runtime_dependencies: [["beta", "~> 2.0"]])
      check_instance = described_class.new(config: config, members: [alpha])
      broken = Kettle::Family::Member.new(name: "beta", root: beta_root, gemspec_path: nil, version_file: nil, version: "not-a-version", dependencies: [])
      allow(check_instance).to receive(:all_members_by_name).and_return({"beta" => broken})

      result = check_instance.call

      expect(result).to be_ok
    end

    it "skips members when git itself is unavailable" do
      alpha = member("alpha", root: make_repo("alpha"))
      allow(Open3).to receive(:capture3).and_raise(Errno::ENOENT)

      result = check(members: [alpha])

      expect(result).to be_ok
    end

    it "answers branch state once per repo for members sharing a git root (monorepo)" do
      root = make_repo("mono")
      alpha = member("alpha", root: root)
      beta = member("beta", root: root)

      result = check(members: [alpha, beta])

      expect(result).to be_ok
    end

    it "omits the branch note when the sibling checkout is not a git repo" do
      stub_env("K_JEM_TEMPLATING" => "true")
      alpha_root = make_repo("alpha")
      beta_root = File.join(@tmpdir, "beta")
      FileUtils.mkdir_p(beta_root)
      alpha = member("alpha", root: alpha_root, runtime_dependencies: [["beta", "~> 2.0"]])
      check_instance = described_class.new(config: config, members: [alpha])
      beta = Kettle::Family::Member.new(name: "beta", root: beta_root, gemspec_path: nil, version_file: nil, version: "1.4.12", dependencies: [])
      allow(check_instance).to receive(:all_members_by_name).and_return({"beta" => beta})

      result = check_instance.call

      expect(result).not_to be_ok
      expect(result.stdout).to include("provides 1.4.12")
      expect(result.stdout).not_to include("(branch")
    end

    it "skips a member with no gemspec path" do
      stub_env("K_JEM_TEMPLATING" => "true")
      alpha = member("alpha", root: make_repo("alpha"))

      result = check(members: [alpha])

      expect(result).to be_ok
    end
  end

  describe "#default_branch" do
    it "is nil when git itself is unavailable" do
      check_instance = described_class.new(config: config, members: [])
      allow(Open3).to receive(:capture3).and_raise(Errno::ENOENT)

      expect(check_instance.send(:default_branch, @tmpdir)).to be_nil
    end
  end

  def write_config(extra = "")
    File.write(File.join(@tmpdir, ".kettle-family.yml"), "family:\n  name: branch-spec\n#{extra}")
  end

  def config
    Kettle::Family::Config.load(root: @tmpdir)
  end

  def check(members:, overrides: {})
    described_class.call(config: config, members: members, overrides: overrides)
  end

  def git(root, *args)
    system("git", "-C", root, *args, out: File::NULL, err: File::NULL) || raise("git #{args.first} failed for #{root}")
  end

  # A real-git member repo on main, with origin/HEAD pointing at main (the
  # default-branch signal a clone would set), plus any extra branches. The
  # checkout ends on +current+ (or detached when +detach+).
  def make_repo(name, branches: [], current: "main", origin_head: true, detach: false)
    root = File.join(@tmpdir, name)
    FileUtils.mkdir_p(root)
    system("git", "init", "--initial-branch=main", root, out: File::NULL, err: File::NULL) || raise("git init failed")
    git(root, "config", "user.email", "spec@example.test")
    git(root, "config", "user.name", "Spec")
    File.write(File.join(root, "README.md"), "# #{name}\n")
    git(root, "add", "README.md")
    git(root, "commit", "-m", "initial")
    if origin_head
      git(root, "update-ref", "refs/remotes/origin/main", "refs/heads/main")
      git(root, "symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/main")
    end
    branches.each { |branch| git(root, "switch", "-c", branch) }
    git(root, "switch", current)
    git(root, "checkout", "--detach") if detach
    root
  end

  def member(name, root:, version: "1.0.0", runtime_dependencies: nil)
    gemspec_path = nil
    if runtime_dependencies
      gemspec_path = File.join(root, "#{name}.gemspec")
      File.write(gemspec_path, gemspec_source(name, version, runtime_dependencies))
      git(root, "add", "#{name}.gemspec")
      git(root, "commit", "-m", "gemspec")
    end
    Kettle::Family::Member.new(name: name, root: root, gemspec_path: gemspec_path, version_file: nil, version: version, dependencies: [])
  end

  def gemspec_source(name, version, deps)
    lines = [
      "Gem::Specification.new do |spec|",
      "  spec.name = #{name.inspect}",
      "  spec.version = #{version.inspect}"
    ]
    deps.each { |dep_name, requirement| lines << "  spec.add_dependency(#{dep_name.inspect}, #{requirement.inspect})" }
    lines << "end"
    lines.join("\n") + "\n"
  end
end
