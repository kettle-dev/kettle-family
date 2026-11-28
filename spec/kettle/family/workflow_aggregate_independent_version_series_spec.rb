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

  it "excludes independent-series members from the shared-cohort aggregate GitHub release" do
    write_family_config(independent_members: ["indy"])
    config = Kettle::Family::Config.load(root: @tmpdir)
    alpha = member("alpha", version: "1.0.0")
    beta = member("beta", version: "1.0.0")
    indy = member("indy", version: "2.0.0")
    write_member_artifact(alpha, version: "1.0.0")
    write_member_artifact(beta, version: "1.0.0")
    write_member_artifact(indy, version: "2.0.0")
    workflow = described_class.new(command: "release", config: config, members: [alpha, beta, indy], publish: true)

    expect(workflow.send(:aggregate_release_members)).to eq([alpha, beta])
    expect(workflow.send(:aggregate_github_release_members)).to eq([alpha, beta])
    expect(workflow.send(:aggregate_release_member?, indy)).to be(false)

    result = workflow.send(:aggregate_monorepo_github_release, [alpha, beta, indy])

    expect(result).to be_ok
    expect(result.command).to include("--release-version", "1.0.0")
    # Only the shared cohort's artifacts attach to the shared release; the
    # independent-series member tracks its own GitHub Release at v2.0.0.
    expect(result.command.join(" ")).to include("alpha-1.0.0.gem", "beta-1.0.0.gem")
    expect(result.command.join(" ")).not_to include("indy-2.0.0")
    expect(result.command.join(" ")).not_to include("indy-1.0.0")
  end

  it "lets an independent-series member create its own GitHub release instead of skipping it" do
    write_family_config(independent_members: ["indy"])
    config = Kettle::Family::Config.load(root: @tmpdir)
    alpha = member("alpha", version: "1.0.0")
    indy = member("indy", version: "2.0.0")
    workflow = described_class.new(command: "release", config: config, members: [alpha, indy], publish: true)

    alpha_env = workflow.send(:release_env_for_member, alpha)
    indy_env = workflow.send(:release_env_for_member, indy)

    expect(alpha_env).to include("KETTLE_RELEASE_SKIP_GITHUB_RELEASE" => "true")
    expect(alpha_env).not_to have_key("KETTLE_RELEASE_REQUIRE_GITHUB_RELEASE")
    expect(indy_env).not_to have_key("KETTLE_RELEASE_SKIP_GITHUB_RELEASE")
    expect(indy_env).to include(
      "KETTLE_RELEASE_REQUIRE_GITHUB_RELEASE" => "true",
      "K_CHANGELOG_GEM_NAME" => "indy",
      "K_CHANGELOG_PATH" => File.join(indy.root, "CHANGELOG.md")
    )
  end

  it "does not require GitHub release on non-publish runs and honors explicit opt-out" do
    write_family_config(independent_members: ["indy"])
    config = Kettle::Family::Config.load(root: @tmpdir)
    alpha = member("alpha", version: "1.0.0")
    indy = member("indy", version: "2.0.0")

    build_only = described_class.new(command: "release", config: config, members: [alpha, indy], publish: false)
    expect(build_only.send(:release_env_for_member, indy)).not_to have_key("KETTLE_RELEASE_REQUIRE_GITHUB_RELEASE")

    opt_out = described_class.new(
      command: "release",
      config: config,
      members: [alpha, indy],
      publish: true,
      env_overrides: {"KETTLE_RELEASE_REQUIRE_GITHUB_RELEASE" => "false"}
    )
    expect(opt_out.send(:release_env_for_member, indy)).to include("KETTLE_RELEASE_REQUIRE_GITHUB_RELEASE" => "false")
  end

  it "routes template prepare, family changelog, and reset changelog handling to the independent member" do
    write_family_config(independent_members: ["indy"])
    config = Kettle::Family::Config.load(root: @tmpdir)
    alpha = member("alpha", version: "1.0.0")
    indy = member("indy", version: "2.0.0")

    template_workflow = described_class.new(command: "template", config: config, members: [alpha, indy])
    expect(template_workflow.send(:template_prepare_env, member: alpha).fetch("K_CHANGELOG_PATH")).to eq(File.join(@tmpdir, "CHANGELOG.md"))
    expect(template_workflow.send(:template_prepare_env, member: indy).fetch("K_CHANGELOG_PATH")).to eq(File.join(indy.root, "CHANGELOG.md"))

    solo_release = described_class.new(command: "release", config: config, members: [indy], family_members: [alpha, indy], publish: true)
    expect(solo_release.send(:family_changelog_applies_to_selected_members?)).to be(false)
    expect(solo_release.send(:reset_skips_member_changelog_dependency?, indy)).to be(false)
    expect(solo_release.send(:reset_skips_member_changelog_dependency?, alpha)).to be(true)
  end

  it "does not invoke the shared-cohort aggregate release when only an independent-series member is released" do
    write_family_config(independent_members: ["indy"])
    config = Kettle::Family::Config.load(root: @tmpdir)
    alpha = member("alpha", version: "1.0.0")
    beta = member("beta", version: "1.0.0")
    indy = member("indy", version: "2.0.0")
    workflow = described_class.new(
      command: "release", config: config, members: [indy], family_members: [alpha, beta, indy], execute: true, publish: true
    )
    published = Kettle::Family::CommandResult.new("indy", "release_publish", ["internal"], indy.root, 0, true, "", "", 0.0, false, nil)

    allow(workflow).to receive_messages(
      release_preflight_results: [],
      release_dependency_floor_reconciliation_results: [],
      release_member_results: [published]
    )
    expect(workflow).not_to receive(:aggregate_monorepo_github_release)

    expect(workflow.results).to eq([published])
  end

  it "refuses to attach an independent-series member alone to the shared-cohort release" do
    write_family_config(independent_members: ["indy"])
    config = Kettle::Family::Config.load(root: @tmpdir)
    alpha = member("alpha", version: "1.0.0")
    beta = member("beta", version: "1.0.0")
    indy = member("indy", version: "2.0.0")
    write_member_artifact(indy, version: "2.0.0")
    workflow = described_class.new(
      command: "release", config: config, members: [indy], family_members: [alpha, beta, indy], publish: true
    )

    result = workflow.send(:aggregate_monorepo_github_release, [indy])

    expect(result).not_to be_ok
    expect(result.reason).to eq("no shared-version members selected for aggregate GitHub release")
  end

  it "does not append an independent-series member to the shared-cohort release during member finalization" do
    write_family_config(independent_members: ["indy"])
    config = Kettle::Family::Config.load(root: @tmpdir)
    alpha = member("alpha", version: "1.0.0")
    indy = member("indy", version: "2.0.0")
    workflow = described_class.new(
      command: "release", config: config, members: [alpha, indy], execute: true, publish: true
    )
    results = []

    expect(workflow).not_to receive(:aggregate_monorepo_github_release)

    workflow.send(:append_member_github_release, indy, results)
    expect(results).to be_empty
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
