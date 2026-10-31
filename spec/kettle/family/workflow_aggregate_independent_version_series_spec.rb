# frozen_string_literal: true

require "fileutils"
require "stringio"
require "tmpdir"
require "yaml"

RSpec.describe Kettle::Family::Workflow do
  around do |example|
    Dir.mktmpdir("kettle-family-aggregate-independent-spec") do |dir|
      @tmpdir = dir
      example.run
    end
  end

  before do
    Kettle::Family.mise_adapter = build_mise_adapter(executable: "mise")
  end

  def write_family_config(independent_members: [])
    release = {
      "build_command" => [RbConfig.ruby, "-e", "puts 'build'"],
      "publish_command" => [RbConfig.ruby, "-e", "puts 'publish'"],
      "aggregate_validation" => {"enabled" => true}
    }
    release["version_series"] = {"independent_members" => independent_members} unless independent_members.empty?
    File.write(
      File.join(@tmpdir, ".kettle-family.yml"),
      YAML.dump(
        "family" => {"name" => "example", "mode" => "monorepo", "members_root" => "gems"},
        "changelog" => {
          "mode" => "root",
          "path" => "CHANGELOG.md",
          "version_file" => "gems/alpha/lib/alpha/version.rb"
        },
        "release" => release
      )
    )
    File.write(File.join(@tmpdir, "CHANGELOG.md"), "## [Unreleased]\n")
  end

  def member(name, version:)
    root = File.join(@tmpdir, "gems", name)
    FileUtils.mkdir_p(root)
    Kettle::Family::Member.new(name: name, root: root, gemspec_path: nil, version_file: nil, version: version, dependencies: [])
  end

  def write_member_artifact(member, version:)
    pkg = File.join(member.root, "pkg")
    FileUtils.mkdir_p(pkg)
    gem_path = File.join(pkg, "#{member.name}-#{version}.gem")
    File.write(gem_path, "fake gem\n")
    checksums = File.join(member.root, "checksums")
    FileUtils.mkdir_p(checksums)
    checksum_path = File.join(checksums, "#{member.name}-#{version}.gem.sha256")
    File.write(checksum_path, "fake checksum\n")
  end

  it "excludes independent-series members from the same-version invariant while attaching their assets" do
    write_family_config(independent_members: ["indy"])
    config = Kettle::Family::Config.load(root: @tmpdir)
    alpha = member("alpha", version: "1.0.0")
    beta = member("beta", version: "1.0.0")
    indy = member("indy", version: "2.0.0")
    write_member_artifact(alpha, version: "1.0.0")
    write_member_artifact(beta, version: "1.0.0")
    write_member_artifact(indy, version: "2.0.0")
    workflow = described_class.new(command: "release", config: config, members: [alpha, beta, indy], publish: true)

    result = workflow.send(:aggregate_monorepo_github_release, [alpha, beta, indy])

    expect(result).to be_ok
    expect(result.command).to include("--release-version", "1.0.0")
    # The shared cohort's artifacts attach at the shared version...
    expect(result.command.join(" ")).to include("alpha-1.0.0.gem", "beta-1.0.0.gem")
    # ...and the independent member's artifacts still attach, at its own
    # series version — never filtered out, never renamed to the cohort's.
    expect(result.command.join(" ")).to include("indy-2.0.0.gem", "indy-2.0.0.gem.sha256")
    expect(result.command.join(" ")).not_to include("indy-1.0.0")
  end

  it "still enforces the same-version invariant without independent-series declarations" do
    write_family_config
    config = Kettle::Family::Config.load(root: @tmpdir)
    alpha = member("alpha", version: "1.0.0")
    indy = member("indy", version: "2.0.0")
    workflow = described_class.new(command: "release", config: config, members: [alpha, indy], publish: true)

    result = workflow.send(:aggregate_monorepo_github_release, [alpha, indy])

    expect(result).not_to be_ok
    expect(result.reason).to eq("all selected members must have the same version")
  end
end
