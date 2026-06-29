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

  it "plans a configured family changelog phase and shared root changelog checks" do
    write_release_config(
      build_command: [RbConfig.ruby, "-e", "puts 'build'"],
      family_changelog: {"enabled" => true, "command" => [RbConfig.ruby, "-e", "puts 'changelog'"]},
      check: {
        "required_files" => %w[Gemfile Rakefile README.md LICENSE.md],
        "required_bins" => %w[bin/rake bin/rspec],
        "root_required_files" => ["CHANGELOG.md"]
      },
      changelog: {
        "mode" => "root",
        "path" => "CHANGELOG.md",
        "version_file" => "gems/tree_haver/lib/tree_haver/version.rb"
      },
      release_env: {"KETTLE_RB_DEV" => false}
    )
    File.write(File.join(@tmpdir, "CHANGELOG.md"), "## [Unreleased]\n")
    config = Kettle::Family::Config.load(root: @tmpdir)
    member = ready_member("alpha", changelog: false)

    results = described_class.new(command: "release", config: config, members: [member]).results

    expect(results.map(&:phase)).to eq(%w[family_changelog check release_changelog release_build])
    expect(results.first.command).to eq([RbConfig.ruby, "-e", "puts 'changelog'"])
    expect(results.first.workdir).to eq(@tmpdir)
    expect(results.first.skipped).to be(true)
    expect(results.last.command).to eq([RbConfig.ruby, "-e", "puts 'build'"])
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

  it "starts configured target branch releases at the requested branch" do
    write_release_config(target_branches: %w[r1_8-even-v0 r1_9-even-v2 r2_0-even-v4])
    config = Kettle::Family::Config.load(root: @tmpdir)
    member = ready_member("alpha")
    workflow = described_class.new(command: "release", config: config, members: [member], start_branch: "r1_9-even-v2")
    allow(workflow).to receive(:rediscovered_selected_members).and_return([member])

    results = workflow.results

    expect(results.select { |result| result.phase == "release_checkout" }.map(&:command)).to eq([
      ["git", "checkout", "r1_9-even-v2"],
      ["git", "checkout", "r2_0-even-v4"]
    ])
    expect(results.map(&:branch).uniq).to eq(%w[r1_9-even-v2 r2_0-even-v4])
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
      skip_steps: "10",
      local_ci: true,
      continue_ci_failures: true
    ).results

    expect(results.last.command).to eq(["sh", "-lc", "bundle exec kettle-release start_step=10 skip_steps=10 --local-ci"])
  end

  it "disables noisy Bundler and debug environment for release commands" do
    write_release_config
    config = Kettle::Family::Config.load(root: @tmpdir)
    member = ready_member("alpha")
    File.write(File.join(member.root, "mise.toml"), "[env]\nDEBUG = \"true\"\n")

    results = described_class.new(command: "release", config: config, members: [member]).results

    release_command = results.find { |result| result.phase == "release_build" }.command
    expect(release_command).to include(
      "-u",
      "DEBUG",
      "BUNDLE_QUIET=true",
      "BUNDLE_DEBUG=false",
      "BUNDLER_DEBUG=false",
      "BUNDLE_VERBOSE=false",
      "-u",
      "DEBUG_RESOLVER",
      "BUNDLE_SUPPRESS_INSTALL_USING_MESSAGES=true"
    )
    expect(release_command).not_to include(
      "DEBUG=true",
      "DEBUG=false",
      "BUNDLE_DEBUG=true",
      "BUNDLER_DEBUG=true",
      "BUNDLE_VERBOSE=true",
      "DEBUG_RESOLVER=true",
      "DEBUG_RESOLVER=false"
    )
  end

  it "preserves release debug environment when debug is enabled" do
    write_release_config(
      release_env: {
        "DEBUG" => "true",
        "BUNDLE_DEBUG" => "true",
        "BUNDLER_DEBUG" => "true",
        "BUNDLE_VERBOSE" => "true",
        "DEBUG_RESOLVER" => "true"
      }
    )
    config = Kettle::Family::Config.load(root: @tmpdir)
    member = ready_member("alpha")
    File.write(File.join(member.root, "mise.toml"), "[env]\nDEBUG = \"false\"\n")

    results = described_class.new(command: "release", config: config, members: [member], debug: true).results

    release_command = results.find { |result| result.phase == "release_build" }.command
    expect(release_command).to include(
      "DEBUG=true",
      "BUNDLE_DEBUG=true",
      "BUNDLER_DEBUG=true",
      "BUNDLE_VERBOSE=true",
      "DEBUG_RESOLVER=true"
    )
  end

  it "prompts once for gem signing before executed build releases" do
    write_release_config
    config = Kettle::Family::Config.load(root: @tmpdir)
    member = signed_member("alpha")
    workflow = described_class.new(command: "release", config: config, members: [member], execute: true)
    allow(workflow).to receive(:prompt_for_gem_signing_password)

    workflow.results

    expect(workflow).to have_received(:prompt_for_gem_signing_password).once
  end

  it "uses the cached gem signing password for executed build prompts" do
    write_release_config(
      build_command: [
        RbConfig.ruby,
        "-e",
        "print 'Enter PEM pass phrase:'; $stdout.flush; exit(STDIN.gets&.chomp == 'secret' ? 0 : 1)"
      ]
    )
    config = Kettle::Family::Config.load(root: @tmpdir)
    member = signed_member("alpha")
    workflow = described_class.new(command: "release", config: config, members: [member], execute: true)
    allow(workflow).to receive(:prompt_for_gem_signing_password) do
      workflow.instance_variable_set(:@gem_signing_password, "secret")
    end

    results = workflow.results

    expect(results).to all(be_ok)
    expect(results.last.stdout).to include("Enter PEM pass phrase:")
  end

  it "passes the cached gem signing password to member-local branch workflows" do
    config = Kettle::Family::Config.load(root: @tmpdir)
    member = signed_member("alpha")
    member_config_path = File.join(member.root, ".kettle-family.yml")
    File.write(member_config_path, <<~YAML)
      release:
        target_branches:
          - r1
          - r2
    YAML
    member_config = Kettle::Family::Config.load(root: member.root, path: member_config_path)
    workflow = described_class.new(command: "release", config: config, members: [member])
    workflow.instance_variable_set(:@gem_signing_password, "secret")

    child = workflow.send(:member_local_workflow, member: member, member_config: member_config)

    expect(child.instance_variable_get(:@gem_signing_password)).to eq("secret")
  end

  it "normalizes release lockfiles with local path env disabled before readiness" do
    write_release_config(
      build_command: [RbConfig.ruby, "-e", "puts 'build'"],
      template: {
        "normalize_lockfiles" => true,
        "normalize_lockfiles_command" => %w[bundle update nomono --bundler]
      }
    )
    config = Kettle::Family::Config.load(root: @tmpdir)
    member = ready_member("alpha")
    File.write(File.join(member.root, "mise.toml"), "[env]\nSMORG_RB_DEV = \"true\"\n")

    results = described_class.new(command: "release", config: config, members: [member]).results

    expect(results.map(&:phase)).to eq(%w[
      release_normalize_lockfiles
      commit_normalized_lockfiles
      check
      release_changelog
      release_build
    ])
    expect(results.first.command).to eq([
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
      "K_JEM_TEMPLATING=false",
      "SMORG_RB_DEV=false",
      "TSLP_DEV=false",
      "KETTLE_RB_DEV=false",
      "RUBOCOP_LTS_DEV=false",
      "PBOLING_DEV=false",
      "GALTZO_FLOSS_DEV=false",
      "UR_BRAIN_DEV=false",
      "bundle",
      "update",
      "nomono",
      "--bundler"
    ])
  end

  it "lets explicit release environment overrides win during lockfile normalization" do
    write_release_config(
      build_command: [RbConfig.ruby, "-e", "puts 'build'"],
      template: {
        "normalize_lockfiles" => true,
        "normalize_lockfiles_command" => %w[bundle update nomono --bundler]
      }
    )
    config = Kettle::Family::Config.load(root: @tmpdir)
    member = ready_member("alpha")
    File.write(File.join(member.root, "mise.toml"), "[env]\nSMORG_RB_DEV = \"true\"\nRUBOCOP_LTS_LOCAL = \"false\"\n")

    results = described_class.new(
      command: "release",
      config: config,
      members: [member],
      env_overrides: {
        "RUBOCOP_LTS_LOCAL" => "/workspace/rubocop-lts",
        "SMORG_RB_DEV" => "/workspace/structuredmerge/ruby/gems"
      }
    ).results

    expect(results.first.command).to include(
      "RUBOCOP_LTS_LOCAL=/workspace/rubocop-lts",
      "SMORG_RB_DEV=/workspace/structuredmerge/ruby/gems"
    )
    expect(results.first.command).not_to include("SMORG_RB_DEV=false")
    expect(results.first.command).to include("KETTLE_RB_DEV=false")
  end

  it "allows release readiness to use explicitly requested local source roots" do
    write_release_config(build_command: [RbConfig.ruby, "-e", "puts 'build'"])
    config = Kettle::Family::Config.load(root: @tmpdir)
    member = ready_member("alpha")
    local_root = File.join(@tmpdir, "rubocop-lts")
    FileUtils.mkdir_p(File.join(local_root, "rubocop-ruby3_2"))
    File.write(File.join(member.root, "Gemfile.lock"), "PATH\n  remote: #{File.join(local_root, "rubocop-ruby3_2")}\n")

    results = described_class.new(
      command: "release",
      config: config,
      members: [member],
      env_overrides: {
        "RUBOCOP_LTS_LOCAL" => local_root
      }
    ).results

    expect(results.find { |result| result.phase == "check" }).to be_ok
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

  it "plans releases across member-local target branches when the active family config has none" do
    config = Kettle::Family::Config.load(root: @tmpdir)
    member = ready_member("alpha")
    File.write(File.join(member.root, ".kettle-family.yml"), <<~YAML)
      release:
        target_branches:
          - r1
          - r2
    YAML

    results = described_class.new(command: "release", config: config, members: [member]).results

    expect(results.map(&:phase)).to eq(%w[
      release_checkout check release_changelog release_build
      release_checkout check release_changelog release_build
    ])
    expect(results.select { |result| result.phase == "release_checkout" }.map(&:command)).to eq([
      ["git", "checkout", "r1"],
      ["git", "checkout", "r2"]
    ])
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

  it "executes independent release members in parallel when jobs allow it" do
    barrier = File.join(@tmpdir, "release-barrier")
    script = <<~RUBY
      barrier = ENV.fetch("RELEASE_BARRIER")
      File.open("\#{barrier}.lock", "w") do |lock|
        lock.flock(File::LOCK_EX)
        count = File.file?(barrier) ? File.read(barrier).to_i : 0
        File.write(barrier, (count + 1).to_s)
      end
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
      until File.read(barrier).to_i >= 2 || Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
        sleep 0.05
      end
      exit(File.read(barrier).to_i >= 2 ? 0 : 7)
    RUBY
    write_release_config(
      build_command: [RbConfig.ruby, "-e", script],
      release_env: {"RELEASE_BARRIER" => barrier}
    )
    config = Kettle::Family::Config.load(root: @tmpdir)
    members = [ready_member("alpha"), ready_member("beta")]

    results = described_class.new(command: "release", config: config, members: members, execute: true, jobs: 2).results

    expect(results).to all(be_ok)
    expect(results.count { |result| result.phase == "release_build" }).to eq(2)
  end

  it "sets the release MFA queue total to the active wave job count" do
    config = Kettle::Family::Config.load(root: @tmpdir)
    members = [ready_member("alpha"), ready_member("beta"), ready_member("gamma")]
    workflow = described_class.new(command: "release", config: config, members: members, execute: true, jobs: 2)
    coordinator = Class.new do
      attr_reader :queue_totals

      def initialize
        @queue_totals = []
      end

      def queue_total=(value)
        @queue_totals << value
      end
    end.new

    allow(workflow).to receive(:release_otp_coordinator).and_return(coordinator)
    allow(workflow).to receive(:release_results_for_member) do |member, runner:|
      [
        Kettle::Family::CommandResult.new(
          member_name: member.name,
          phase: "release_build",
          command: ["release"],
          workdir: member.root,
          status: 0,
          success: true,
          stdout: "",
          stderr: "",
          elapsed_seconds: 0.0,
          skipped: false,
          reason: nil
        )
      ]
    end

    workflow.send(:run_release_wave, members)

    expect(coordinator.queue_totals).to eq([2])
  end

  it "builds release waves from selected member dependencies" do
    config = Kettle::Family::Config.load(root: @tmpdir)
    alpha = ready_member("alpha")
    beta = ready_member("beta", dependencies: ["alpha"])
    gamma = ready_member("gamma")
    workflow = described_class.new(command: "release", config: config, members: [alpha, beta, gamma], execute: true, jobs: 3)

    waves = workflow.send(:release_waves, [alpha, beta, gamma])

    expect(waves.map { |wave| wave.map(&:name) }).to eq([%w[alpha gamma], %w[beta]])
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

  def write_release_config(build_command: [RbConfig.ruby, "-e", "puts 'build'"], publish_command: [RbConfig.ruby, "-e", "puts 'publish'"], target_branches: nil, family_changelog: nil, check: nil, changelog: nil, release_env: nil, template: nil)
    release = {
      "build_command" => build_command,
      "publish_command" => publish_command,
      "tag_command" => [RbConfig.ruby, "-e", "puts 'tag'"],
      "push_command" => [RbConfig.ruby, "-e", "puts 'push'"]
    }
    release["target_branches"] = target_branches if target_branches
    release["family_changelog"] = family_changelog if family_changelog
    release["env"] = release_env if release_env
    config = {"release" => release}
    config["template"] = template if template
    config["check"] = check if check
    config["changelog"] = changelog if changelog
    File.write(
      File.join(@tmpdir, ".kettle-family.yml"),
      YAML.dump(config)
    )
  end

  def ready_member(name, changelog: true, dependencies: [])
    root = File.join(@tmpdir, name)
    FileUtils.mkdir_p(File.join(root, "bin"))
    %w[Gemfile Rakefile README.md LICENSE.md].each do |path|
      File.write(File.join(root, path), "stub\n")
    end
    File.write(File.join(root, "CHANGELOG.md"), "## [Unreleased]\n") if changelog
    %w[bin/rake bin/rspec].each do |path|
      full_path = File.join(root, path)
      File.write(full_path, "#!/bin/sh\n")
      FileUtils.chmod("u+x", full_path)
    end
    Kettle::Family::Member.new(name: name, root: root, gemspec_path: nil, version_file: nil, version: "1.0.0", dependencies: dependencies)
  end

  def signed_member(name)
    member = ready_member(name)
    gemspec = File.join(member.root, "#{name}.gemspec")
    File.write(gemspec, "Gem::Specification.new do |spec|\n  spec.signing_key = 'key.pem'\nend\n")
    Kettle::Family::Member.new(name: name, root: member.root, gemspec_path: gemspec, version_file: nil, version: member.version, dependencies: [])
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
