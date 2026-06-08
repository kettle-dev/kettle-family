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

  def write_release_config(build_command: [RbConfig.ruby, "-e", "puts 'build'"])
    File.write(
      File.join(@tmpdir, ".kettle-family.yml"),
      YAML.dump(
        "release" => {
          "build_command" => build_command,
          "publish_command" => [RbConfig.ruby, "-e", "puts 'publish'"],
          "tag_command" => [RbConfig.ruby, "-e", "puts 'tag'"],
          "push_command" => [RbConfig.ruby, "-e", "puts 'push'"]
        }
      )
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
end
