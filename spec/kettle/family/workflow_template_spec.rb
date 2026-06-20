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
        "SMORG_RB_DEV" => "/workspace/structuredmerge/ruby/gems"
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
        "KETTLE_JEM_TEMPLATE_PROFILE=full",
        "KJ_REPOSITORY_TOPOLOGY=standalone",
        "K_JEM_TEMPLATING=true",
        "SMORG_RB_DEV=/workspace/structuredmerge/ruby/gems",
        "bundle",
        "exec",
        "kettle-jem",
        "install"
      ]
    )
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

  it "bootstraps legacy members without bundle exec when templating wiring is absent" do
    config = Kettle::Family::Config.load(root: @tmpdir)
    member = member_at("alpha")

    results = described_class.new(command: "template", config: config, members: [member]).results

    expect(results.fetch(0).command).to eq(["sh", "-lc", "kettle-jem install"])
  end

  it "uses bundle exec for members with generated templating wiring" do
    config = Kettle::Family::Config.load(root: @tmpdir)
    member = member_at("alpha")
    File.write(File.join(member.root, "Gemfile"), <<~RUBY)
      eval_gemfile "gemfiles/modular/templating.gemfile" if ENV.fetch("K_JEM_TEMPLATING", "false").casecmp("true").zero?
    RUBY

    results = described_class.new(command: "template", config: config, members: [member]).results

    expect(results.fetch(0).command).to eq(["sh", "-lc", "bundle exec kettle-jem install"])
  end

  def write_template_config(command: [RbConfig.ruby, "-e", "puts 'templated'"], release_target_branches: nil)
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
      File.join(@tmpdir, ".kettle-family.yml"),
      YAML.dump(config)
    )
  end

  def member_at(name)
    root = File.join(@tmpdir, name)
    FileUtils.mkdir_p(root)
    Kettle::Family::Member.new(name: name, root: root, gemspec_path: File.join(root, "#{name}.gemspec"), version: "1.0.0", dependencies: [])
  end
end
