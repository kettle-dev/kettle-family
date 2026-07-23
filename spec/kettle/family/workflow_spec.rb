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

  it "plans GitHub Actions SHA pin writes with the default patch upgrade" do
    config = Kettle::Family::Config.load(root: @tmpdir)
    member = member_at("alpha")

    results = described_class.new(command: "gha-sha-pins", config: config, members: [member]).results

    expect(results.first.phase).to eq("gha-sha-pins")
    expect(results.first.command).to eq(["sh", "-lc", "bundle exec kettle-gha-sha-pins --write --upgrade patch"])
  end

  it "plans full bundle updates by default" do
    config = Kettle::Family::Config.load(root: @tmpdir)
    member = member_at("alpha")

    results = described_class.new(command: "bup", config: config, members: [member]).results

    expect(results.first.phase).to eq("bup")
    expect(results.first.command).to eq(%w[bundle update --all])
    expect(results.fetch(1).phase).to eq("commit_bundle_update")
  end

  it "plans bundle updates with local path environments disabled" do
    File.write(File.join(@tmpdir, ".kettle-family.yml"), <<~YAML)
      family:
        local_path_env: KETTLE_DEV_DEV
    YAML
    config = Kettle::Family::Config.load(root: @tmpdir)
    member = member_at("alpha")
    File.write(File.join(member.root, "mise.toml"), "[env]\n")

    results = described_class.new(command: "bup", config: config, members: [member]).results

    expect(results.first.command).to include("KETTLE_DEV_DEV=false")
  end

  it "does not commit bundle updates that produce local path lockfile remotes" do
    fake_bin = File.join(@tmpdir, "bin")
    FileUtils.mkdir_p(fake_bin)
    File.write(File.join(fake_bin, "bundle"), <<~RUBY)
      #!/usr/bin/env ruby
      File.write("Gemfile.lock", "PATH\\n  remote: #{@tmpdir}/beta\\n")
      exit(0)
    RUBY
    FileUtils.chmod("+x", File.join(fake_bin, "bundle"))
    config = Kettle::Family::Config.load(root: @tmpdir)
    member = member_at("alpha")

    results = described_class.new(
      command: "bup",
      config: config,
      members: [member],
      execute: true,
      env_overrides: {"PATH" => "#{fake_bin}:#{ENV.fetch("PATH")}"}
    ).results

    expect(results.map(&:phase)).to eq(%w[bup bundle_update_readiness])
    expect(results.last).not_to be_ok
    expect(results.last.reason).to eq("bundle update produced release-invalid lockfile")
    expect(results.last.stdout).to include("release lockfile has local path remote")
  end

  it "plans named bundle updates when bup args are provided" do
    config = Kettle::Family::Config.load(root: @tmpdir)
    member = member_at("alpha")

    results = described_class.new(command: "bup", config: config, members: [member], bup_args: ["rake"]).results

    expect(results.first.command).to eq(%w[bundle update rake])
  end

  it "skips bundle update commits when commits are disabled" do
    config = Kettle::Family::Config.load(root: @tmpdir)
    member = member_at("alpha")

    results = described_class.new(command: "bup", config: config, members: [member], commit: false).results

    expect(results.map(&:phase)).to eq(["bup"])
  end

  it "plans bundler updates" do
    config = Kettle::Family::Config.load(root: @tmpdir)
    member = member_at("alpha")

    results = described_class.new(command: "bupb", config: config, members: [member]).results

    expect(results.first.phase).to eq("bupb")
    expect(results.first.command).to eq(%w[bundle update --bundler])
    expect(results.fetch(1).phase).to eq("commit_bundle_update")
  end

  it "plans bundle exec commands with provided args" do
    config = Kettle::Family::Config.load(root: @tmpdir)
    member = member_at("alpha")

    results = described_class.new(command: "bex", config: config, members: [member], bex_args: %w[rake spec]).results

    expect(results.first.phase).to eq("bex")
    expect(results.first.command).to eq(%w[bundle exec rake spec])
    expect(results.fetch(1).phase).to eq("commit_bex")
  end

  it "skips bundle exec commits when commits are disabled" do
    config = Kettle::Family::Config.load(root: @tmpdir)
    member = member_at("alpha")

    results = described_class.new(command: "bex", config: config, members: [member], bex_args: %w[rake spec], commit: false).results

    expect(results.map(&:phase)).to eq(["bex"])
  end

  it "plans GitHub Actions SHA pin checks with the selected upgrade level" do
    config = Kettle::Family::Config.load(root: @tmpdir)
    member = member_at("alpha")

    results = described_class.new(
      command: "gha-sha-pins",
      config: config,
      members: [member],
      gha_sha_pins_check: true,
      gha_sha_pins_upgrade: "minor"
    ).results

    expect(results.first.command).to eq(["sh", "-lc", "bundle exec kettle-gha-sha-pins --check --upgrade minor"])
  end

  it "plans member workflow commands across member-local target branches" do
    config = Kettle::Family::Config.load(root: @tmpdir)
    member = member_at("alpha")
    File.write(File.join(member.root, ".kettle-family.yml"), <<~YAML)
      release:
        target_branches:
          - r1
          - r2
    YAML

    results = described_class.new(command: "lint", config: config, members: [member]).results

    expect(results.map(&:phase)).to eq(%w[release_checkout lint release_checkout lint])
    expect(results.select { |result| result.phase == "release_checkout" }.map(&:command)).to eq([
      ["git", "checkout", "r1"],
      ["git", "checkout", "r2"]
    ])
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
