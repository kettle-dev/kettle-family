# frozen_string_literal: true

require "fileutils"
require "open3"
require "pathname"
require "tmpdir"
require "yaml"

RSpec.describe "Mise execution across family checkout shapes" do
  let(:project_tmp) { File.expand_path("../../tmp", __dir__) }
  let(:mise_config_names) { %w[mise.toml .mise.toml] }

  around do |example|
    FileUtils.mkdir_p(project_tmp)
    Dir.mktmpdir("mise-family-shapes-", project_tmp) do |dir|
      @tmpdir = dir
      example.run
    end
  end

  before do
    stub_env(
      "MISE_PARANOID" => "1",
      "MISE_STATE_DIR" => File.join(@tmpdir, "mise-state"),
      "MISE_YES" => "1"
    )
    skip "mise is required for worktree trust integration scenarios" unless executable_on_path?("mise")
  end

  it "executes an ordinary sibling repository through its trusted Mise config" do
    member = build_sibling_member("alpha")
    initialize_git_repo(member.root)
    trust_primary_checkout(member.root)

    result = mise_probe(member)

    expect(result).to be_ok
    expect(result.stdout).to eq("family-root:alpha")
  end

  it "turns a genuinely untrusted linked worktree into an executable checkout" do
    config, members = build_monorepo_family
    workflow = described_workflow(config: config, members: members)
    original_member = members.first
    worktree_root = File.join(@tmpdir, "manual-untrusted-worktree")
    run_git(@tmpdir, "worktree", "add", "--detach", worktree_root, "HEAD")
    worktree_member = workflow.send(
      :relocate_member_to_worktree,
      original_member,
      worktree_root,
      source_root: @tmpdir
    )

    before_trust = mise_probe(worktree_member)
    trust_results = workflow.send(
      :worktree_mise_trust_results,
      {member: worktree_member, original_member: original_member, worktree_root: worktree_root},
      runner: Kettle::Family::CommandRunner.new(execute: true, accept: true),
      phase: "worktree_mise_trust"
    )
    after_trust = mise_probe(worktree_member)

    expect(before_trust).not_to be_ok
    expect(before_trust.stderr).to include("not trusted")
    expect(trust_results).to all(be_ok)
    expect(after_trust).to be_ok
    expect(after_trust.stdout).to eq("family-root:alpha")
  ensure
    run_git(@tmpdir, "worktree", "remove", "--force", worktree_root) if worktree_root && Dir.exist?(worktree_root)
  end

  {
    "monorepo template workers" => {
      setup: :monorepo_template_worktree_entries,
      cleanup: :cleanup_monorepo_template_worktrees,
      trust_phase: "template_member_worktree_mise_trust"
    },
    "monorepo test workers" => {
      setup: :monorepo_test_worktree_entries,
      cleanup: :cleanup_monorepo_test_worktrees,
      trust_phase: "test_member_worktree_mise_trust"
    },
    "monorepo release workers" => {
      setup: :monorepo_release_worktree_entries,
      cleanup: :cleanup_monorepo_release_worktrees,
      trust_phase: "release_worktree_mise_trust"
    }
  }.each do |shape, scenario|
    it "executes #{shape} after trusting root and member configs" do
      config, members = build_monorepo_family
      workflow = described_workflow(config: config, members: members)
      entries = []

      entries, setup_results = workflow.send(scenario.fetch(:setup), members)
      probe_results = entries.map { |entry| mise_probe(entry.fetch(:member)) }

      expect(setup_results).to all(be_ok)
      expect(setup_results.count { |result| result.phase == scenario.fetch(:trust_phase) }).to eq(4)
      expect(probe_results).to all(be_ok)
      expect(probe_results.map(&:stdout)).to contain_exactly("family-root:alpha", "family-root:beta")
    ensure
      workflow&.send(scenario.fetch(:cleanup), entries)
    end
  end

  it "executes every sibling branch-stack checkout through Mise" do
    member = build_sibling_member("alpha")
    initialize_git_repo(member.root, branches: ["legacy"])
    trust_primary_checkout(member.root)
    family_config = write_family_config(mode: "sibling_repos")
    member_config = Kettle::Family::Config.new(
      root: member.root,
      path: nil,
      data: {"release" => {"target_branches" => %w[main legacy]}}
    )
    workflow = described_workflow(config: family_config, members: [member])
    probe_results = []
    allow(workflow).to receive(:template_branch_worktree_entries_results) do |entries|
      probe_results = entries.map do |entry|
        mise_probe(entry.fetch(:member)).tap { |result| result.branch = entry.fetch(:branch) }
      end
    end

    results = workflow.send(:template_branch_worktree_results, member: member, member_config: member_config)

    expect(results).to all(be_ok)
    expect(results.count { |result| result.phase == "template_worktree_mise_trust" }).to eq(1)
    expect(probe_results).to all(be_ok)
    expect(probe_results.map(&:branch)).to contain_exactly("main", "legacy")
    expect(probe_results.map(&:stdout)).to all(eq("family-root:alpha"))
  end

  def build_monorepo_family
    config = write_family_config(mode: "monorepo", members_root: "gems")
    members = %w[alpha beta].map do |name|
      root = File.join(@tmpdir, "gems", name)
      FileUtils.mkdir_p(root)
      write_mise_config(root, "KETTLE_FAMILY_MEMBER_MISE_PROBE" => name)
      member(name, root)
    end
    write_mise_config(@tmpdir, "KETTLE_FAMILY_ROOT_MISE_PROBE" => "family-root")
    initialize_git_repo(@tmpdir)
    trust_primary_checkout(members.last.root)
    [config, members]
  end

  def build_sibling_member(name)
    root = File.join(@tmpdir, name)
    FileUtils.mkdir_p(root)
    write_mise_config(root, {
      "KETTLE_FAMILY_ROOT_MISE_PROBE" => "family-root",
      "KETTLE_FAMILY_MEMBER_MISE_PROBE" => name
    })
    member(name, root)
  end

  def member(name, root)
    Kettle::Family::Member.new(
      name: name,
      root: root,
      gemspec_path: File.join(root, "#{name}.gemspec"),
      version: "1.0.0",
      dependencies: []
    )
  end

  def described_workflow(config:, members:)
    Kettle::Family::Workflow.new(
      command: "template",
      config: config,
      members: members,
      family_members: members,
      execute: true,
      jobs: members.length
    )
  end

  def write_family_config(mode:, members_root: nil)
    family = {"name" => "mise-family-shapes", "mode" => mode}
    family["members_root"] = members_root if members_root
    File.write(File.join(@tmpdir, ".kettle-family.yml"), YAML.dump("family" => family))
    Kettle::Family::Config.load(root: @tmpdir)
  end

  def write_mise_config(root, env)
    body = env.map { |name, value| "#{name} = #{value.inspect}" }.join("\n")
    File.write(File.join(root, "mise.toml"), "[env]\n#{body}\n")
  end

  def initialize_git_repo(root, branches: [])
    run_git(root, "init", "--quiet", "--initial-branch", "main")
    run_git(root, "config", "user.email", "kettle-family@example.test")
    run_git(root, "config", "user.name", "Kettle Family")
    run_git(root, "add", ".")
    run_git(root, "commit", "--quiet", "-m", "Initial")
    branches.each { |branch| run_git(root, "branch", branch) }
  end

  def trust_primary_checkout(path)
    mise_configs_between_filesystem_root_and(path).each do |config_path|
      _stdout, stderr, status = Open3.capture3("mise", "trust", "--yes", config_path)
      raise "mise trust failed for #{config_path}: #{stderr}" unless status.success?
    end
  end

  def mise_configs_between_filesystem_root_and(path)
    Pathname.new(path).expand_path.ascend.each_with_object([]) do |directory, configs|
      mise_config_names.each do |name|
        config_path = directory.join(name)
        configs << config_path.to_s if config_path.file?
      end
    end.reverse
  end

  def mise_probe(target_member)
    Kettle::Family::CommandRunner.new(execute: true, accept: true).call(
      member: target_member,
      phase: "mise_probe",
      command: [
        RbConfig.ruby,
        "-e",
        "print [ENV.fetch('KETTLE_FAMILY_ROOT_MISE_PROBE'), ENV.fetch('KETTLE_FAMILY_MEMBER_MISE_PROBE')].join(':')"
      ]
    )
  end

  def executable_on_path?(name)
    ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).any? do |directory|
      File.executable?(File.join(directory, name))
    end
  end

  def run_git(root, *arguments)
    system("git", *arguments, chdir: root, exception: true)
  end
end
