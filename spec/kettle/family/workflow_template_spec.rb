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

  it "adds skip-commit, template env, lockfile normalization, and family commit plan phases" do
    write_template_config
    config = Kettle::Family::Config.load(root: @tmpdir)
    member = member_at("alpha")

    results = described_class.new(command: "template", config: config, members: [member], commit: true).results

    expect(results.map(&:phase)).to eq(%w[template normalize_lockfiles family_commit])
    expect(results.first.command).to end_with("--skip-commit")
    expect(results).to all(satisfy(&:skipped))
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

    expect(results.first.stdout).to eq("full/standalone\n")
  end

  it "refuses template commit execution when the family worktree starts dirty" do
    write_template_config
    config = Kettle::Family::Config.load(root: @tmpdir)
    member = member_at("alpha")
    allow(Kettle::Family::GitStatus).to receive(:dirty?).and_return(true)

    expect do
      described_class.new(command: "template", config: config, members: [member], execute: true, commit: true).results
    end.to raise_error(Kettle::Family::Error, /dirty worktree/)
  end

  def write_template_config(command: [RbConfig.ruby, "-e", "puts 'templated'"])
    File.write(
      File.join(@tmpdir, ".kettle-family.yml"),
      YAML.dump(
        "template" => {
          "command" => command,
          "profile" => "full",
          "repository_topology" => "standalone",
          "normalize_lockfiles" => true,
          "normalize_lockfiles_command" => [RbConfig.ruby, "-e", "puts 'normalized'"]
        }
      )
    )
  end

  def member_at(name)
    root = File.join(@tmpdir, name)
    FileUtils.mkdir_p(root)
    Kettle::Family::Member.new(name: name, root: root, gemspec_path: File.join(root, "#{name}.gemspec"), version: "1.0.0", dependencies: [])
  end
end
