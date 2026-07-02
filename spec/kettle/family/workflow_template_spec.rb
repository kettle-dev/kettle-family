# frozen_string_literal: true

require "fileutils"
require "tmpdir"
require "yaml"

RSpec.describe Kettle::Family::Workflow do
  around do |example|
    Dir.mktmpdir("kettle-family-template-workflow-spec") do |dir|
      @tmpdir = dir
      example.run
    end
  end

  it "allows member templating commits by default and adds lockfile normalization" do
    write_template_config
    config = Kettle::Family::Config.load(root: @tmpdir)
    member = member_at("alpha")

    results = described_class.new(command: "template", config: config, members: [member]).results

    expect(results.map(&:phase)).to eq(%w[prepare_lockfiles template normalize_lockfiles])
    expect(results.fetch(1).command).not_to include("--skip-commit")
    expect(results.fetch(1).command).not_to include("--quiet")
    expect(results).to all(satisfy(&:skipped))
  end

  it "passes skip-commit to member templating when commits are disabled" do
    write_template_config
    config = Kettle::Family::Config.load(root: @tmpdir)
    member = member_at("alpha")

    results = described_class.new(command: "template", config: config, members: [member], commit: false).results

    expect(results.map(&:phase)).to eq(%w[prepare_lockfiles template normalize_lockfiles])
    expect(results.fetch(1).command).to end_with("--skip-commit")
  end

  it "passes template profile and repository topology environment when executing" do
    write_template_config(
      command: [
        RbConfig.ruby,
        "-e",
        "puts [ENV['KETTLE_JEM_TEMPLATE_PROFILE'], ENV['KJ_REPOSITORY_TOPOLOGY']].join('/')",
        "--",
        "--skip-commit"
      ]
    )
    config = Kettle::Family::Config.load(root: @tmpdir)
    member = member_at("alpha")

    results = described_class.new(command: "template", config: config, members: [member], execute: true).results

    expect(results.fetch(1).stdout).to eq("full/standalone\n")
  end

  it "adds quiet JSON flags and disables noisy debug environment for kettle-jem family templating" do
    config = Kettle::Family::Config.load(root: @tmpdir)
    member = member_at("alpha")
    File.write(File.join(member.root, "Gemfile"), <<~RUBY)
      eval_gemfile "gemfiles/modular/templating.gemfile" if ENV.fetch("K_JEM_TEMPLATING", "false").casecmp("true").zero?
    RUBY

    results = described_class.new(command: "template", config: config, members: [member]).results

    expect(results.fetch(0).command).to eq(["sh", "-lc", "bundle exec kettle-jem install --quiet --json"])
  end

  it "passes explicit environment overrides through member mise execution" do
    write_template_config(command: ["bundle", "exec", "kettle-jem", "install"])
    config = Kettle::Family::Config.load(root: @tmpdir)
    member = member_at("alpha")
    File.write(File.join(member.root, "mise.toml"), "[env]\nK_JEM_TEMPLATING = \"false\"\n")

    results = described_class.new(
      command: "template",
      config: config,
      members: [member],
      env_overrides: {
        "K_JEM_TEMPLATING" => "true",
        "SMORG_RB_DEV" => "/workspace/structuredmerge/ruby/gems",
        "RUBOCOP_LTS_LOCAL" => "/workspace/rubocop-lts"
      }
    ).results

    expect(results.fetch(1).command).to eq(
      [
        "mise",
        "exec",
        "-C",
        member.root,
        "--",
        "env",
        "-u",
        "DEBUG",
        "-u",
        "DEBUG_RESOLVER",
        "-u",
        "DEBUG_RESOLVER_TREE",
        "-u",
        "BUNDLER_DEBUG_RESOLVER",
        "-u",
        "BUNDLER_DEBUG_RESOLVER_TREE",
        "-u",
        "DEBUG_COMPACT_INDEX",
        "-u",
        "MOLINILLO_DEBUG",
        "KETTLE_JEM_TEMPLATE_PROFILE=full",
        "KJ_REPOSITORY_TOPOLOGY=standalone",
        "K_JEM_TEMPLATING=true",
        "SMORG_RB_DEV=/workspace/structuredmerge/ruby/gems",
        "RUBOCOP_LTS_LOCAL=/workspace/rubocop-lts",
        "KETTLE_JEM_QUIET=true",
        "KETTLE_JEM_DEBUG=false",
        "KETTLE_DEV_DEBUG=false",
        "SMORG_RB_DEBUG=false",
        "BUNDLE_QUIET=true",
        "BUNDLE_DEBUG=false",
        "BUNDLER_DEBUG=false",
        "BUNDLE_VERBOSE=false",
        "BUNDLE_SILENCE_DEPRECATIONS=true",
        "BUNDLE_SILENCE_ROOT_WARNING=true",
        "BUNDLE_SUPPRESS_INSTALL_USING_MESSAGES=true",
        "bundle",
        "exec",
        "kettle-jem",
        "install",
        "--quiet",
        "--json"
      ]
    )

    [results.fetch(0), results.fetch(2)].each do |result|
      expect(result.command).to include(
        "K_JEM_TEMPLATING=true",
        "SMORG_RB_DEV=/workspace/structuredmerge/ruby/gems",
        "RUBOCOP_LTS_LOCAL=/workspace/rubocop-lts",
        "BUNDLE_QUIET=true"
      )
      expect(result.command.last(3)).to eq([RbConfig.ruby, "-e", "puts 'normalized'"])
    end
  end

  it "overrides noisy template debug environment unless debug is enabled" do
    write_template_config(command: ["bundle", "exec", "kettle-jem", "install"])
    config = Kettle::Family::Config.load(root: @tmpdir)
    member = member_at("alpha")
    File.write(File.join(member.root, "mise.toml"), "[env]\nDEBUG = \"true\"\n")

    quiet_results = described_class.new(
      command: "template",
      config: config,
      members: [member],
      env_overrides: {
        "DEBUG" => "true",
        "BUNDLE_DEBUG" => "true",
        "BUNDLER_DEBUG" => "true",
        "DEBUG_RESOLVER" => "true",
        "SMORG_RB_DEBUG" => "true"
      }
    ).results
    debug_results = described_class.new(
      command: "template",
      config: config,
      members: [member],
      env_overrides: {
        "DEBUG" => "true",
        "BUNDLE_DEBUG" => "true",
        "BUNDLER_DEBUG" => "true",
        "DEBUG_RESOLVER" => "true",
        "SMORG_RB_DEBUG" => "true"
      },
      debug: true
    ).results

    quiet_command = quiet_results.find { |result| result.phase == "template" }.command
    quiet_env = quiet_command.grep(/DEBUG|RESOLVER/)
    debug_env = debug_results.find { |result| result.phase == "template" }.command.grep(/DEBUG|RESOLVER/)
    expect(quiet_command).to include(
      "-u",
      "DEBUG",
      "-u",
      "DEBUG_RESOLVER",
      "BUNDLE_DEBUG=false",
      "BUNDLER_DEBUG=false",
      "SMORG_RB_DEBUG=false"
    )
    expect(quiet_env).not_to include(
      "DEBUG=true",
      "DEBUG=false",
      "BUNDLE_DEBUG=true",
      "BUNDLER_DEBUG=true",
      "DEBUG_RESOLVER=true",
      "DEBUG_RESOLVER=false",
      "SMORG_RB_DEBUG=true"
    )
    expect(debug_env).to include(
      "DEBUG=true",
      "BUNDLE_DEBUG=true",
      "BUNDLER_DEBUG=true",
      "DEBUG_RESOLVER=true",
      "SMORG_RB_DEBUG=true"
    )
  end

  it "runs executed templating members in parallel and emits compact progress" do
    write_template_config(command: [
      RbConfig.ruby,
      "-e",
      "puts '{\"changed_files\":[\"Gemfile\"]}'"
    ])
    config = Kettle::Family::Config.load(root: @tmpdir)
    members = [member_at("alpha"), member_at("beta")]
    progress = StringIO.new

    results = described_class.new(
      command: "template",
      config: config,
      members: members,
      execute: true,
      jobs: 2,
      progress_io: progress
    ).results

    expect(results.count { |result| result.phase == "template" }).to eq(2)
    expect(progress.string).to include("templating 2 members with 2 jobs:")
    expect(progress.string).to include("..")
    expect(progress.string).to include("template summary: 2/2 members ok, 2 files changed")
  end

  it "plans templating across configured release target branches" do
    write_template_config(
      release_target_branches: %w[r1_8-even-v0 r1_9-even-v2]
    )
    config = Kettle::Family::Config.load(root: @tmpdir)
    member = member_at("alpha")

    results = described_class.new(command: "template", config: config, members: [member]).results

    expect(results.map(&:phase)).to eq(
      %w[
        release_checkout
        prepare_lockfiles
        template
        normalize_lockfiles
        commit_normalized_lockfiles
        release_checkout
        prepare_lockfiles
        template
        normalize_lockfiles
        commit_normalized_lockfiles
      ]
    )
    expect(results.fetch(0).command).to eq(["git", "checkout", "r1_8-even-v0"])
    expect(results.fetch(5).command).to eq(["git", "checkout", "r1_9-even-v2"])
  end

  it "plans member workflow commands across configured release target branches" do
    write_template_config(
      release_target_branches: %w[r1_8-even-v0 r1_9-even-v2]
    )
    config = Kettle::Family::Config.load(root: @tmpdir)
    member = member_at("alpha")
    workflow = described_class.new(command: "test", config: config, members: [member])
    allow(workflow).to receive(:rediscovered_selected_members).and_return([member])

    results = workflow.results

    expect(results.map(&:phase)).to eq(%w[
      release_checkout test
      release_checkout test
    ])
    expect(results.select { |result| result.phase == "release_checkout" }.map(&:command)).to eq([
      ["git", "checkout", "r1_8-even-v0"],
      ["git", "checkout", "r1_9-even-v2"]
    ])
  end

  it "fails before templating when member target branch checkout would be blocked by local changes" do
    write_template_config
    config = Kettle::Family::Config.load(root: @tmpdir)
    member = member_at("alpha")
    write_template_config(root: member.root, release_target_branches: %w[r1 r2])
    initialize_git_repo(member.root, branches: %w[r1 r2])
    File.write(File.join(member.root, "Gemfile.lock"), "dirty\n")

    results = described_class.new(command: "template", config: config, members: [member], execute: true).results

    expect(results.map(&:phase)).to eq(["release_checkout_preflight"])
    expect(results.first).not_to be_ok
    expect(results.first.member_name).to eq("alpha")
    expect(results.first.stderr).to include("local changes would block release target branch checkout")
    expect(results.first.stderr).to include("Gemfile.lock")
  end

  it "allows dirty member target branch checkout preflight when explicitly requested" do
    write_template_config
    config = Kettle::Family::Config.load(root: @tmpdir)
    member = member_at("alpha")
    write_template_config(root: member.root, release_target_branches: %w[r1 r2])
    initialize_git_repo(member.root, branches: %w[r1 r2])
    File.write(File.join(member.root, "scratch.txt"), "dirty\n")

    results = described_class.new(
      command: "template",
      config: config,
      members: [member],
      execute: true,
      allow_dirty: true
    ).results

    expect(results.map(&:phase)).to include("release_checkout")
    expect(results.map(&:phase)).not_to include("release_checkout_preflight")
    expect(results).to all(be_ok)
  end

  it "bootstraps legacy members without bundle exec when templating wiring is absent" do
    config = Kettle::Family::Config.load(root: @tmpdir)
    member = member_at("alpha")

    results = described_class.new(command: "template", config: config, members: [member]).results

    expect(results.fetch(0).command).to eq(["sh", "-lc", "kettle-jem install --quiet --json"])
  end

  def write_template_config(root: @tmpdir, command: [RbConfig.ruby, "-e", "puts 'templated'"], release_target_branches: nil)
    config = {
      "template" => {
        "command" => command,
        "profile" => "full",
        "repository_topology" => "standalone",
        "normalize_lockfiles" => true,
        "normalize_lockfiles_command" => [RbConfig.ruby, "-e", "puts 'normalized'"]
      }
    }
    config["release"] = {"target_branches" => release_target_branches} if release_target_branches
    File.write(
      File.join(root, ".kettle-family.yml"),
      YAML.dump(config)
    )
  end

  def member_at(name)
    root = File.join(@tmpdir, name)
    FileUtils.mkdir_p(root)
    Kettle::Family::Member.new(name: name, root: root, gemspec_path: File.join(root, "#{name}.gemspec"), version: "1.0.0", dependencies: [])
  end

  def initialize_git_repo(root, branches:)
    run_git(root, "init", "--quiet")
    run_git(root, "config", "user.email", "kettle-family@example.test")
    run_git(root, "config", "user.name", "Kettle Family")
    File.write(File.join(root, "Gemfile.lock"), "clean\n")
    run_git(root, "add", ".")
    run_git(root, "commit", "--quiet", "-m", "Initial")
    branches.each { |branch| run_git(root, "branch", branch) }
  end

  def run_git(root, *args)
    system("git", *args, chdir: root, exception: true)
  end
end
