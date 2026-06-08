# frozen_string_literal: true

require "fileutils"
require "tmpdir"
require "yaml"

RSpec.describe Kettle::Family::Workflow do
  around do |example|
    Dir.mktmpdir("kettle-family-release-workflow-spec") do |dir|
      @tmpdir = dir
      example.run
    end
  end

  it "plans build releases with readiness and changelog checks" do
    write_release_config
    config = Kettle::Family::Config.load(root: @tmpdir)
    member = ready_member("alpha")

    results = described_class.new(command: "release", config: config, members: [member]).results

    expect(results.map(&:phase)).to eq(%w[check release_changelog release_build])
    expect(results.last.skipped).to be(true)
  end

  it "plans publish, tag, and push only when explicitly requested" do
    write_release_config
    config = Kettle::Family::Config.load(root: @tmpdir)
    member = ready_member("alpha")

    results = described_class.new(command: "release", config: config, members: [member], publish: true, tag: true, push: true).results

    expect(results.map(&:phase)).to eq(%w[check release_changelog release_publish release_tag release_push])
  end

  it "plans releases across configured target branches" do
    write_release_config(target_branches: %w[r1_8-even-v0 r1_9-even-v2])
    config = Kettle::Family::Config.load(root: @tmpdir)
    member = ready_member("alpha")
    workflow = described_class.new(command: "release", config: config, members: [member])
    allow(workflow).to receive(:rediscovered_selected_members).and_return([member])

    results = workflow.results

    expect(results.map(&:phase)).to eq(%w[
      release_checkout check release_changelog release_build
      release_checkout check release_changelog release_build
    ])
    expect(results.select { |result| result.phase == "release_checkout" }.map(&:command)).to eq([
      ["git", "checkout", "r1_8-even-v0"],
      ["git", "checkout", "r1_9-even-v2"]
    ])
  end

  it "passes kettle-release resume and local-ci options through release commands" do
    write_release_config(publish_command: "bundle exec kettle-release")
    config = Kettle::Family::Config.load(root: @tmpdir)
    member = ready_member("alpha")

    results = described_class.new(
      command: "release",
      config: config,
      members: [member],
      publish: true,
      start_step: 10,
      local_ci: true,
      continue_ci_failures: true
    ).results

    expect(results.last.command).to eq(["sh", "-lc", "bundle exec kettle-release start_step=10 --local-ci"])
  end

  it "skips already published versions during executed publish releases" do
    write_release_config(publish_command: [RbConfig.ruby, "-e", "abort 'should not run'"])
    config = Kettle::Family::Config.load(root: @tmpdir)
    member = ready_member("alpha")
    workflow = described_class.new(command: "release", config: config, members: [member], execute: true, publish: true)
    allow(workflow).to receive(:prompt_for_gem_signing_password)
    allow(workflow).to receive(:released_version?).with("alpha", "1.0.0").and_return(true)

    results = workflow.results

    expect(results.map(&:phase)).to eq(["release_skip"])
    expect(results.first.stdout).to include("already published")
  end

  it "rediscovers member metadata after each target branch checkout" do
    write_release_config(target_branches: %w[r1 r2])
    config = Kettle::Family::Config.load(root: @tmpdir)
    member = ready_member("alpha")
    workflow = described_class.new(command: "release", config: config, members: [member])
    rediscovered = [
      [member_with_version("alpha", "1.0.1")],
      [member_with_version("alpha", "1.0.2")]
    ]
    allow(workflow).to receive(:rediscovered_selected_members).and_return(*rediscovered)

    results = workflow.results

    release_checks = results.select { |result| result.phase == "check" }
    expect(release_checks.map(&:workdir)).to eq(rediscovered.flatten.map(&:root))
  end

  it "executes configured build command after checks" do
    marker = File.join(@tmpdir, "built")
    write_release_config(build_command: [RbConfig.ruby, "-e", "File.write(#{marker.dump}, 'built')"])
    config = Kettle::Family::Config.load(root: @tmpdir)
    member = ready_member("alpha")

    results = described_class.new(command: "release", config: config, members: [member], execute: true).results

    expect(results).to all(be_ok)
    expect(File.read(marker)).to eq("built")
  end

  it "stops before release commands when readiness fails" do
    write_release_config
    config = Kettle::Family::Config.load(root: @tmpdir)
    member = Kettle::Family::Member.new(name: "alpha", root: File.join(@tmpdir, "alpha"), gemspec_path: nil, version_file: nil, version: "1.0.0", dependencies: [])
    FileUtils.mkdir_p(member.root)

    results = described_class.new(command: "release", config: config, members: [member]).results

    expect(results.map(&:phase)).to eq(["check"])
    expect(results.first).not_to be_ok
  end

  def write_release_config(build_command: [RbConfig.ruby, "-e", "puts 'build'"], publish_command: [RbConfig.ruby, "-e", "puts 'publish'"], target_branches: nil)
    release = {
      "build_command" => build_command,
      "publish_command" => publish_command,
      "tag_command" => [RbConfig.ruby, "-e", "puts 'tag'"],
      "push_command" => [RbConfig.ruby, "-e", "puts 'push'"]
    }
    release["target_branches"] = target_branches if target_branches
    File.write(
      File.join(@tmpdir, ".kettle-family.yml"),
      YAML.dump("release" => release)
    )
  end

  def ready_member(name)
    root = File.join(@tmpdir, name)
    FileUtils.mkdir_p(File.join(root, "bin"))
    %w[Gemfile Rakefile README.md LICENSE.md].each do |path|
      File.write(File.join(root, path), "stub\n")
    end
    File.write(File.join(root, "CHANGELOG.md"), "## [Unreleased]\n")
    %w[bin/rake bin/rspec].each do |path|
      full_path = File.join(root, path)
      File.write(full_path, "#!/bin/sh\n")
      FileUtils.chmod("u+x", full_path)
    end
    Kettle::Family::Member.new(name: name, root: root, gemspec_path: nil, version_file: nil, version: "1.0.0", dependencies: [])
  end

  def member_with_version(name, version)
    root = File.join(@tmpdir, "#{name}-#{version}")
    FileUtils.mkdir_p(root)
    File.write(File.join(root, "Gemfile"), "stub\n")
    File.write(File.join(root, "Rakefile"), "stub\n")
    File.write(File.join(root, "README.md"), "stub\n")
    File.write(File.join(root, "LICENSE.md"), "stub\n")
    File.write(File.join(root, "CHANGELOG.md"), "## [Unreleased]\n")
    FileUtils.mkdir_p(File.join(root, "bin"))
    %w[bin/rake bin/rspec].each do |path|
      full_path = File.join(root, path)
      File.write(full_path, "#!/bin/sh\n")
      FileUtils.chmod("u+x", full_path)
    end
    Kettle::Family::Member.new(name: name, root: root, gemspec_path: nil, version_file: nil, version: version, dependencies: [])
  end
end
