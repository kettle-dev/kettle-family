# frozen_string_literal: true

require "fileutils"
require "tmpdir"

RSpec.describe Kettle::Family::Workflow do
  around do |example|
    Dir.mktmpdir("kettle-family-workflow-spec") do |dir|
      @tmpdir = dir
      example.run
    end
  end

  it "uses configured commands and stops on first execution failure" do
    write_config(command: [RbConfig.ruby, "-e", "exit 3"])
    alpha = member_at("alpha")
    beta = member_at("beta")
    config = Kettle::Family::Config.load(root: @tmpdir)

    results = described_class.new(command: "test", config: config, members: [alpha, beta], execute: true).results

    expect(results.size).to eq(1)
    expect(results.first.member_name).to eq("alpha")
    expect(results.first.status).to eq(3)
  end

  it "plans default commands without executing them" do
    config = Kettle::Family::Config.load(root: @tmpdir)
    member = member_at("alpha")

    results = described_class.new(command: "lint", config: config, members: [member]).results

    expect(results.first.skipped).to be(true)
    expect(results.first.command).to eq(["sh", "-lc", "bundle exec rake rubocop_gradual"])
  end

  it "runs internal check results" do
    config = Kettle::Family::Config.load(root: @tmpdir)
    member = member_at("alpha")

    results = described_class.new(command: "check", config: config, members: [member]).results

    expect(results.first.phase).to eq("check")
    expect(results.first.command).to eq(["internal", "readiness"])
  end

  def write_config(command:)
    File.write(File.join(@tmpdir, ".kettle-family.yml"), <<~YAML)
      commands:
        test:
          - #{command[0].dump}
          - #{command[1].dump}
          - #{command[2].dump}
    YAML
  end

  def member_at(name)
    root = File.join(@tmpdir, name)
    FileUtils.mkdir_p(root)
    Kettle::Family::Member.new(name: name, root: root, gemspec_path: File.join(root, "#{name}.gemspec"), version: "1.0.0", dependencies: [])
  end
end
