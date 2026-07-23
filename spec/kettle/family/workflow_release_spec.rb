# frozen_string_literal: true

require "fileutils"
require "stringio"
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

    workflow = described_class.new(command: "release", config: config, members: [member], publish: true, tag: true, push: true)
    results = workflow.results

    expect(results.map(&:phase)).to eq(%w[check release_changelog release_publish release_tag release_push])
    expect(workflow.send(:release_progress_label)).to eq("publishing")
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
      release_env: {"KETTLE_DEV_DEV" => false}
    )
    File.write(File.join(@tmpdir, "CHANGELOG.md"), "## [Unreleased]\n")
    File.write(File.join(@tmpdir, "mise.toml"), "[env]\n")
    config = Kettle::Family::Config.load(root: @tmpdir)
    member = ready_member("alpha", changelog: false)

    results = described_class.new(command: "release", config: config, members: [member]).results

    expect(results.map(&:phase)).to eq(%w[family_changelog check release_changelog release_build])
    expect(results.first.command).to include("K_CHANGELOG_GEM_NAME=#{config.family_name}")
    expect(results.first.command).to include("K_CHANGELOG_VERSION_FILE=gems/tree_haver/lib/tree_haver/version.rb")
    expect(results.first.command).to end_with(RbConfig.ruby, "-e", "puts 'changelog'")
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
      continue_ci_failures: true,
      ci_workflows: "current,style.yml",
      skip_bundle_audit: true,
      skip_remotes: "cb"
    ).results

    expect(results.last.command).to eq(["sh", "-lc", "bundle exec kettle-release start_step=10 skip_steps=10 --ci-workflows=current,style.yml --local-ci --skip-bundle-audit --skip-remotes=cb"])
  end

  it "rejects unsafe ci workflow subset values before building release commands" do
    write_release_config(publish_command: "bundle exec kettle-release")
    config = Kettle::Family::Config.load(root: @tmpdir)
    member = ready_member("alpha")

    expect {
      described_class.new(
        command: "release",
        config: config,
        members: [member],
        publish: true,
        ci_workflows: "current; echo injected"
      ).results
    }.to raise_error(Kettle::Family::Error, /invalid --ci-workflows value/)
  end

  it "rejects unsafe release remote skip values before building release commands" do
    write_release_config(publish_command: "bundle exec kettle-release")
    config = Kettle::Family::Config.load(root: @tmpdir)
    member = ready_member("alpha")

    expect {
      described_class.new(
        command: "release",
        config: config,
        members: [member],
        publish: true,
        skip_remotes: "cb; echo injected"
      ).results
    }.to raise_error(Kettle::Family::Error, /invalid --skip-remotes value/)
  end

  it "passes bundle audit skip through release command environment" do
    write_release_config(publish_command: "bundle exec kettle-release")
    config = Kettle::Family::Config.load(root: @tmpdir)
    member = ready_member("alpha")
    File.write(File.join(member.root, "mise.toml"), "[env]\n")

    results = described_class.new(
      command: "release",
      config: config,
      members: [member],
      publish: true,
      skip_bundle_audit: true
    ).results

    expect(results.last.command).to include("KETTLE_DEV_SKIP_BUNDLE_AUDIT=true")
  end

  it "passes remote skip list through release command environment" do
    write_release_config(publish_command: "bundle exec kettle-release")
    config = Kettle::Family::Config.load(root: @tmpdir)
    member = ready_member("alpha")
    File.write(File.join(member.root, "mise.toml"), "[env]\n")

    results = described_class.new(
      command: "release",
      config: config,
      members: [member],
      publish: true,
      skip_remotes: "cb"
    ).results

    expect(results.last.command).to include("K_RELEASE_SKIP_REMOTES=cb")
  end

  it "disables noisy Bundler, debug, and implicit family-local environment for release commands" do
    write_release_config
    config = Kettle::Family::Config.load(root: @tmpdir)
    member = ready_member("alpha")
    File.write(File.join(member.root, "mise.toml"), "[env]\nDEBUG = \"true\"\n")

    results = described_class.new(command: "release", config: config, members: [member]).results

    release_command = results.find { |result| result.phase == "release_build" }.command
    expect(release_command).to include(
      "KETTLE_FAMILY_CONFIG=#{File.join(@tmpdir, ".kettle-family.yml")}",
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
      "#{family_local_env_name}=#{@tmpdir}",
      "DEBUG=true",
      "DEBUG=false",
      "BUNDLE_DEBUG=true",
      "BUNDLER_DEBUG=true",
      "BUNDLE_VERBOSE=true",
      "DEBUG_RESOLVER=true",
      "DEBUG_RESOLVER=false"
    )
  end

  it "allows explicitly configured family-local environment for release commands" do
    write_release_config(release_env: {family_local_env_name => @tmpdir})
    config = Kettle::Family::Config.load(root: @tmpdir)
    member = ready_member("alpha")
    File.write(File.join(member.root, "mise.toml"), "[env]\n")

    results = described_class.new(command: "release", config: config, members: [member]).results

    release_command = results.find { |result| result.phase == "release_build" }.command
    expect(release_command).to include("#{family_local_env_name}=#{@tmpdir}")
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
    File.write(File.join(member.root, "mise.toml"), "[env]\nSTRUCTUREDMERGE_DEV = \"true\"\n")

    results = described_class.new(command: "release", config: config, members: [member]).results

    expect(results.map(&:phase)).to eq(%w[
      release_normalize_lockfiles
      commit_normalized_lockfiles
      check
      release_changelog
      release_build
    ])
    expect(results.first.command).to start_with("mise", "exec", "-C", member.root, "--", "env")
    expect(results.first.command).to include(
      "#{family_local_env_name}=false",
      "KETTLE_FAMILY_CONFIG=#{File.join(@tmpdir, ".kettle-family.yml")}",
      "K_JEM_TEMPLATING=false",
      "STRUCTUREDMERGE_DEV=false",
      "KETTLE_DEV_DEV=false"
    )
    expect(results.first.command).not_to include("#{family_local_env_name}=#{@tmpdir}")
    expect(results.first.command.last(4)).to eq(%w[bundle update nomono --bundler])
  end

  it "auto-normalizes local path lockfiles before release readiness" do
    write_release_config(build_command: [RbConfig.ruby, "-e", "puts 'build'"])
    config = Kettle::Family::Config.load(root: @tmpdir)
    member = ready_member("alpha")
    File.write(File.join(member.root, "Gemfile.lock"), "PATH\n  remote: #{@tmpdir}/beta\n")

    results = described_class.new(
      command: "release",
      config: config,
      members: [member],
      execute: true,
      commit: false,
      env_overrides: fake_bundle_env
    ).results

    expect(results.map(&:phase)).to eq(%w[
      release_normalize_lockfiles
      check
      release_changelog
      release_build
    ])
    expect(results.first.command).to eq(["sh", "-lc", "bundle lock"])
    expect(File.read(File.join(member.root, "Gemfile.lock"))).not_to include("PATH")
    expect(results).to all(be_ok)
  end

  it "forces configured local path envs off during lockfile normalization" do
    write_release_config(
      build_command: [RbConfig.ruby, "-e", "puts 'build'"],
      template: {
        "normalize_lockfiles" => true,
        "normalize_lockfiles_command" => %w[bundle update nomono --bundler]
      }
    )
    config = Kettle::Family::Config.load(root: @tmpdir)
    member = ready_member("alpha")
    File.write(File.join(member.root, "mise.toml"), "[env]\nSTRUCTUREDMERGE_DEV = \"true\"\nRUBOCOP_LTS_LOCAL = \"false\"\n")

    results = described_class.new(
      command: "release",
      config: config,
      members: [member],
      env_overrides: {
        "RUBOCOP_LTS_LOCAL" => "/workspace/rubocop-lts",
        "STRUCTUREDMERGE_DEV" => "/workspace/structuredmerge/ruby/gems",
        family_local_env_name => "/workspace/family"
      }
    ).results

    expect(results.first.command).to include(
      "RUBOCOP_LTS_LOCAL=/workspace/rubocop-lts",
      "#{family_local_env_name}=false",
      "STRUCTUREDMERGE_DEV=false"
    )
    expect(results.first.command).not_to include("#{family_local_env_name}=/workspace/family")
    expect(results.first.command).not_to include("STRUCTUREDMERGE_DEV=/workspace/structuredmerge/ruby/gems")
    expect(results.first.command).to include("KETTLE_DEV_DEV=false")
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

  it "rejects implicit family-local lockfile paths during release readiness" do
    write_release_config(build_command: [RbConfig.ruby, "-e", "puts 'build'"])
    config = Kettle::Family::Config.load(root: @tmpdir)
    member = ready_member("alpha")
    File.write(File.join(member.root, "Gemfile.lock"), "PATH\n  remote: #{File.join(@tmpdir, "beta")}\n")

    results = described_class.new(command: "release", config: config, members: [member]).results

    check_result = results.find { |result| result.phase == "check" }
    expect(check_result).not_to be_ok
    expect(check_result.stdout).to include("local path remote")
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

  it "fails published-version skips when release state reports unreleased changes" do
    write_release_config(publish_command: [RbConfig.ruby, "-e", "abort 'should not run'"])
    config = Kettle::Family::Config.load(root: @tmpdir)
    member = ready_member("alpha")
    workflow = described_class.new(command: "release", config: config, members: [member], execute: true, publish: true)
    allow(workflow).to receive(:prompt_for_gem_signing_password)
    allow(workflow).to receive(:released_version?).with("alpha", "1.0.0").and_return(true)
    allow(workflow).to receive(:git_work_tree?).with(member.root).and_return(true)
    allow(workflow).to receive(:git_rev_parse).with(member.root, "refs/tags/v1.0.0^{}").and_return("tag-sha")
    allow(workflow).to receive(:git_rev_parse).with(member.root, "HEAD").and_return("head-sha")
    allow(workflow).to receive(:unreleased_changes_pending?).with(member).and_return(true)

    results = workflow.results

    expect(results.map(&:phase)).to eq(["release_skip"])
    expect(results.first).not_to be_ok
    expect(results.first.skipped).to be(false)
    expect(results.first.reason).to eq("published version has unreleased changes")
    expect(results.first.stdout).to include("release-state reports unreleased changes")
    expect(results.first.stdout).to include("bump patch --execute --only alpha")
  end

  it "skips already published versions when local HEAD is newer than the release tag with no unreleased changes" do
    write_release_config(publish_command: [RbConfig.ruby, "-e", "abort 'should not run'"])
    config = Kettle::Family::Config.load(root: @tmpdir)
    member = ready_member("alpha")
    workflow = described_class.new(command: "release", config: config, members: [member], execute: true, publish: true)
    allow(workflow).to receive(:prompt_for_gem_signing_password)
    allow(workflow).to receive(:released_version?).with("alpha", "1.0.0").and_return(true)
    allow(workflow).to receive(:git_work_tree?).with(member.root).and_return(true)
    allow(workflow).to receive(:git_rev_parse).with(member.root, "refs/tags/v1.0.0^{}").and_return("tag-sha")
    allow(workflow).to receive(:git_rev_parse).with(member.root, "HEAD").and_return("head-sha")
    allow(workflow).to receive(:unreleased_changes_pending?).with(member).and_return(false)

    results = workflow.results

    expect(results.map(&:phase)).to eq(["release_skip"])
    expect(results.first).to be_ok
    expect(results.first.skipped).to be(true)
    expect(results.first.reason).to eq("already released; no unreleased changes")
    expect(results.first.stdout).to include("current HEAD is newer than v1.0.0")
    expect(results.first.stdout).to include("no unreleased changes")
  end

  it "continues release after skipping an already published version whose HEAD moved past the tag" do
    write_release_config(publish_command: [RbConfig.ruby, "-e", "puts 'publish'"])
    config = Kettle::Family::Config.load(root: @tmpdir)
    alpha = ready_member("alpha")
    beta = ready_member("beta")
    workflow = described_class.new(command: "release", config: config, members: [alpha, beta], execute: true, publish: true)
    allow(workflow).to receive(:prompt_for_gem_signing_password)
    allow(workflow).to receive(:released_version?).with("alpha", "1.0.0").and_return(true)
    allow(workflow).to receive(:released_version?).with("beta", "1.0.0").and_return(false)
    allow(workflow).to receive(:git_work_tree?).with(alpha.root).and_return(true)
    allow(workflow).to receive(:git_rev_parse).with(alpha.root, "refs/tags/v1.0.0^{}").and_return("tag-sha")
    allow(workflow).to receive(:git_rev_parse).with(alpha.root, "HEAD").and_return("head-sha")
    allow(workflow).to receive(:unreleased_changes_pending?).with(alpha).and_return(false)

    results = workflow.results

    expect(results.map(&:phase)).to include("release_skip", "check", "release_publish")
    alpha_skip = results.find { |result| result.member_name == "alpha" && result.phase == "release_skip" }
    expect(alpha_skip).to be_ok
    expect(alpha_skip.skipped).to be(true)
    expect(results.find { |result| result.member_name == "beta" && result.phase == "release_publish" }).to be_ok
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

  it "lets root member target branches override member-local target branches" do
    File.write(File.join(@tmpdir, ".kettle-family.yml"), <<~YAML)
      release:
        member_target_branches:
          alpha:
            - root-r1
            - root-r2
    YAML
    config = Kettle::Family::Config.load(root: @tmpdir)
    member = ready_member("alpha")
    File.write(File.join(member.root, ".kettle-family.yml"), <<~YAML)
      release:
        target_branches:
          - local-r1
    YAML

    results = described_class.new(command: "release", config: config, members: [member]).results

    expect(results.select { |result| result.phase == "release_checkout" }.map(&:command)).to eq([
      ["git", "checkout", "root-r1"],
      ["git", "checkout", "root-r2"]
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
    progress = StringIO.new

    workflow = described_class.new(command: "release", config: config, members: members, execute: true, jobs: 2, progress_io: progress)
    allow(workflow).to receive(:truffleruby?).and_return(false)

    results = workflow.results

    expect(results).to all(be_ok)
    expect(results.count { |result| result.phase == "release_build" }).to eq(2)
    expect(progress.string).to include("releasing 2 members with 2 jobs:")
    expect(progress.string).to include("[alpha] . release_build")
    expect(progress.string).to include("[beta] . release_build")
    expect(progress.string).to include("release summary: 2/2 members ok")
  end

  it "emits release wave markers for parallel release groups" do
    write_release_config
    config = Kettle::Family::Config.load(root: @tmpdir)
    alpha = ready_member("alpha")
    beta = ready_member("beta", dependencies: ["alpha"])
    gamma = ready_member("gamma")
    workflow = described_class.new(command: "release", config: config, members: [alpha, beta, gamma], execute: true, jobs: 3)

    allow(workflow).to receive(:truffleruby?).and_return(false)
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

    results = workflow.results
    wave_results = results.select { |result| result.phase == "release_wave" }

    expect(wave_results.map(&:stdout)).to eq(["alpha, gamma", "beta"])
    expect(wave_results.map(&:reason)).to eq(["jobs=2 total=2", "jobs=1 total=2"])
    expect(results.map(&:phase)).to start_with("release_wave")
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

    allow(workflow).to receive_messages(release_otp_coordinator: coordinator, truffleruby?: false)
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

  it "runs release members sequentially on TruffleRuby" do
    config = Kettle::Family::Config.load(root: @tmpdir)
    members = [ready_member("alpha"), ready_member("beta")]
    workflow = described_class.new(command: "release", config: config, members: members, execute: true, jobs: 2)

    allow(workflow).to receive(:truffleruby?).and_return(true)

    expect(workflow.send(:release_jobs, members)).to eq(1)
    expect(workflow.send(:parallel_release_members?, members)).to be(false)
  end

  it "plans family dependency floor updates between sequential releases" do
    write_release_config
    config = Kettle::Family::Config.load(root: @tmpdir)
    alpha = ready_member_with_gemspec("alpha", version: "1.2.3")
    beta = ready_member_with_gemspec("beta", dependencies: {"alpha" => ["~> 1.0", ">= 1.0.0"]})

    results = described_class.new(command: "release", config: config, members: [alpha, beta]).results

    expect(results.map(&:phase)).to eq(%w[
      check release_changelog release_build dependency_floor
      check release_changelog release_build
    ])
    expect(results.find { |result| result.phase == "dependency_floor" }.stdout).to include("would update")
    expect(File.read(beta.gemspec_path)).to include('"alpha", "~> 1.0", ">= 1.0.0"')
  end

  it "waits for just-published family dependencies before releasing dependents" do
    write_release_config(release_env: fake_bundle_env)
    config = Kettle::Family::Config.load(root: @tmpdir)
    alpha = ready_member_with_gemspec("alpha", version: "1.2.3")
    beta = ready_member_with_gemspec("beta", dependencies: {"alpha" => ["~> 1.0", ">= 1.0.0"]})
    workflow = described_class.new(command: "release", config: config, members: [alpha, beta], execute: true, publish: true, commit: false, jobs: 1)
    alpha_checks = 0

    allow(workflow).to receive(:prompt_for_gem_signing_password)
    allow(workflow).to receive(:released_version?) do |gem_name, _version|
      next false if gem_name == "beta"

      alpha_checks += 1
      alpha_checks >= 4
    end
    allow(workflow).to receive(:sleep)

    results = workflow.results

    expect(results.map(&:phase)).to eq(%w[
      check release_changelog release_publish dependency_floor release_wait_for_registry
      dependency_floor_lockfiles
      check release_changelog release_publish
    ])
    wait = results.find { |result| result.phase == "release_wait_for_registry" }
    expect(wait).to be_ok
    expect(wait.stdout).to include("alpha 1.2.3")
    expect(wait.stdout).to include("after 3 check(s)")
    expect(workflow).to have_received(:sleep).with(15).twice
  end

  it "retries dependent bundle refreshes after just-published dependency floors" do
    write_release_config(
      release_env: fake_bundle_env(<<~BASH)
        attempts_file="$BUNDLE_ATTEMPTS_FILE"
        attempts=0
        if [ -f "$attempts_file" ]; then
          attempts="$(cat "$attempts_file")"
        fi
        attempts="$((attempts + 1))"
        printf '%s' "$attempts" > "$attempts_file"
        printf 'bundle attempt %s: %s\\n' "$attempts" "$*"
        if [ "$attempts" -lt 3 ]; then
          exit 1
        fi
        cat > Gemfile.lock <<'LOCK'
        GEM
          specs:
            alpha (1.2.3)

        CHECKSUMS
          alpha (1.2.3) sha256=abc123
        LOCK
      BASH
    )
    config = Kettle::Family::Config.load(root: @tmpdir)
    alpha = ready_member_with_gemspec("alpha", version: "1.2.3")
    beta = ready_member_with_gemspec("beta", dependencies: {"alpha" => ["~> 1.0", ">= 1.0.0"]})
    workflow = described_class.new(command: "release", config: config, members: [alpha, beta], execute: true, publish: true, commit: false, jobs: 1)
    alpha_checks = 0

    allow(workflow).to receive(:prompt_for_gem_signing_password)
    allow(workflow).to receive(:released_version?) do |gem_name, _version|
      next false if gem_name == "beta"

      alpha_checks += 1
      alpha_checks > 1
    end
    allow(workflow).to receive(:sleep)

    results = workflow.results

    expect(results.map(&:phase)).to eq(%w[
      check release_changelog release_publish dependency_floor release_wait_for_registry
      dependency_floor_lockfiles check release_changelog release_publish
    ])
    lockfile_refresh = results.find { |result| result.phase == "dependency_floor_lockfiles" }
    expect(lockfile_refresh).to be_ok
    expect(lockfile_refresh.command).to eq(%w[bundle update alpha])
    expect(lockfile_refresh.member_name).to eq("beta")
    expect(lockfile_refresh.stdout).to include("bundle attempt 3: update alpha")
    expect(lockfile_refresh.stdout).to include("refreshed dependency floor lockfiles after 3 attempt(s)")
    expect(workflow).to have_received(:sleep).with(15).twice
  end

  it "retries dependent bundle refreshes when Bundler writes empty checksums for just-published floors" do
    write_release_config(
      release_env: fake_bundle_env(<<~BASH)
        attempts_file="$BUNDLE_ATTEMPTS_FILE"
        attempts=0
        if [ -f "$attempts_file" ]; then
          attempts="$(cat "$attempts_file")"
        fi
        attempts="$((attempts + 1))"
        printf '%s' "$attempts" > "$attempts_file"
        printf 'bundle attempt %s: %s\\n' "$attempts" "$*"
        if [ "$attempts" -lt 3 ]; then
          cat > Gemfile.lock <<'LOCK'
        GEM
          specs:
            alpha (1.2.3)

        CHECKSUMS
          alpha (1.2.3)
        LOCK
          exit 0
        fi
        cat > Gemfile.lock <<'LOCK'
        GEM
          specs:
            alpha (1.2.3)

        CHECKSUMS
          alpha (1.2.3) sha256=abc123
        LOCK
      BASH
    )
    config = Kettle::Family::Config.load(root: @tmpdir)
    alpha = ready_member_with_gemspec("alpha", version: "1.2.3")
    beta = ready_member_with_gemspec("beta", dependencies: {"alpha" => ["~> 1.0", ">= 1.0.0"]})
    workflow = described_class.new(command: "release", config: config, members: [alpha, beta], execute: true, publish: true, commit: false, jobs: 1)
    alpha_checks = 0

    allow(workflow).to receive(:prompt_for_gem_signing_password)
    allow(workflow).to receive(:released_version?) do |gem_name, _version|
      next false if gem_name == "beta"

      alpha_checks += 1
      alpha_checks > 1
    end
    allow(workflow).to receive(:sleep)

    results = workflow.results

    expect(results.map(&:phase)).to eq(%w[
      check release_changelog release_publish dependency_floor release_wait_for_registry
      dependency_floor_lockfiles check release_changelog release_publish
    ])
    lockfile_refresh = results.find { |result| result.phase == "dependency_floor_lockfiles" }
    expect(lockfile_refresh).to be_ok
    expect(lockfile_refresh.stdout).to include("bundle attempt 3: update alpha")
    expect(lockfile_refresh.stdout).to include("refreshed dependency floor lockfiles after 3 attempt(s)")
    expect(workflow).to have_received(:sleep).with(15).twice
  end

  it "times out waiting for just-published family dependencies before lockfile normalization" do
    write_release_config(
      template: {
        "normalize_lockfiles" => true,
        "normalize_lockfiles_command" => [RbConfig.ruby, "-e", "puts 'normalized'"]
      }
    )
    config = Kettle::Family::Config.load(root: @tmpdir)
    alpha = ready_member_with_gemspec("alpha", version: "1.2.3")
    beta = ready_member_with_gemspec("beta", dependencies: {"alpha" => ["~> 1.0", ">= 1.0.0"]})
    workflow = described_class.new(command: "release", config: config, members: [alpha, beta], execute: true, publish: true, commit: false, jobs: 1)

    allow(workflow).to receive(:prompt_for_gem_signing_password)
    allow(workflow).to receive(:released_version?).and_return(false)
    allow(workflow).to receive(:sleep)

    results = workflow.results

    expect(results.map(&:phase)).to eq(%w[
      release_normalize_lockfiles check release_changelog release_publish
      dependency_floor release_wait_for_registry
    ])
    wait = results.last
    expect(wait.phase).to eq("release_wait_for_registry")
    expect(wait).not_to be_ok
    expect(wait.stdout).to include("timed out waiting for alpha 1.2.3 after 15 check(s)")
    expect(workflow).to have_received(:sleep).with(15).exactly(14).times
  end

  it "skips family dependency floor updates when disabled" do
    write_release_config
    config = Kettle::Family::Config.load(root: @tmpdir)
    alpha = ready_member_with_gemspec("alpha", version: "1.2.3")
    beta = ready_member_with_gemspec("beta", dependencies: {"alpha" => ["~> 1.0", ">= 1.0.0"]})

    results = described_class.new(command: "release", config: config, members: [alpha, beta], auto_dependency_floors: false).results

    expect(results.map(&:phase)).not_to include("dependency_floor")
  end

  it "stops assigning queued parallel release members after the first failure" do
    config = Kettle::Family::Config.load(root: @tmpdir)
    members = %w[alpha beta gamma].map { |name| ready_member(name) }
    workflow = described_class.new(command: "release", config: config, members: members, execute: true, jobs: 1)
    released = []

    allow(workflow).to receive(:release_results_for_member) do |member, runner:|
      released << member.name
      [
        Kettle::Family::CommandResult.new(
          member_name: member.name,
          phase: "release_build",
          command: ["release"],
          workdir: member.root,
          status: (member.name == "alpha") ? 1 : 0,
          success: member.name != "alpha",
          stdout: "",
          stderr: "",
          elapsed_seconds: 0.0,
          skipped: false,
          reason: (member.name == "alpha") ? "command failed" : nil
        )
      ]
    end

    results = workflow.send(:run_release_wave, members)

    expect(released).to eq(["alpha"])
    expect(results.flatten.map(&:member_name)).to eq(["alpha"])
    expect(results.flatten.first).not_to be_ok
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

  it "builds release waves from release-only member dependencies" do
    config = Kettle::Family::Config.load(root: @tmpdir)
    soup = ready_member("kettle-soup-cover")
    nomono = ready_member("nomono", release_dependencies: ["kettle-soup-cover"])
    workflow = described_class.new(command: "release", config: config, members: [soup, nomono], execute: true, jobs: 2)

    waves = workflow.send(:release_waves, [soup, nomono])

    expect(waves.map { |wave| wave.map(&:name) }).to eq([["kettle-soup-cover"], ["nomono"]])
  end

  it "breaks release-only dependency cycles by selected member order" do
    config = Kettle::Family::Config.load(root: @tmpdir)
    alpha = ready_member("alpha", release_dependencies: ["beta"])
    beta = ready_member("beta", release_dependencies: ["alpha"])
    workflow = described_class.new(command: "release", config: config, members: [alpha, beta], execute: true, jobs: 2)

    waves = workflow.send(:release_waves, [alpha, beta])

    expect(waves.map { |wave| wave.map(&:name) }).to eq([["alpha"], ["beta"]])
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

  def fake_bundle_env(body = "")
    bin_dir = File.join(@tmpdir, "fake-bin")
    FileUtils.mkdir_p(bin_dir)
    bundle_path = File.join(bin_dir, "bundle")
    File.write(bundle_path, <<~BASH)
      #!/usr/bin/env bash
      #{body}
      cat > Gemfile.lock <<'LOCK'
      GEM
        specs:
          alpha (1.2.3)

      CHECKSUMS
        alpha (1.2.3) sha256=abc123
      LOCK
    BASH
    FileUtils.chmod("u+x", bundle_path)
    {
      "PATH" => "#{bin_dir}:#{ENV.fetch("PATH")}",
      "BUNDLE_ATTEMPTS_FILE" => File.join(@tmpdir, "bundle-attempts")
    }
  end

  def ready_member(name, changelog: true, dependencies: [], release_dependencies: nil)
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
    Kettle::Family::Member.new(name: name, root: root, gemspec_path: nil, version_file: nil, version: "1.0.0", dependencies: dependencies, release_dependencies: release_dependencies || dependencies)
  end

  def ready_member_with_gemspec(name, version: "1.0.0", dependencies: {})
    member = ready_member(name, dependencies: dependencies.keys)
    dependency_lines = dependencies.map do |dependency, requirements|
      %(  spec.add_dependency #{dependency.inspect}, #{Array(requirements).map(&:inspect).join(", ")})
    end
    gemspec = File.join(member.root, "#{name}.gemspec")
    File.write(gemspec, <<~RUBY)
      Gem::Specification.new do |spec|
        spec.name = #{name.inspect}
        spec.version = #{version.inspect}
      #{dependency_lines.join("\n")}
      end
    RUBY
    Kettle::Family::Member.new(name: name, root: member.root, gemspec_path: gemspec, version_file: nil, version: version, dependencies: dependencies.keys)
  end

  def signed_member(name)
    member = ready_member(name)
    gemspec = File.join(member.root, "#{name}.gemspec")
    File.write(gemspec, "Gem::Specification.new do |spec|\n  spec.signing_key = 'key.pem'\nend\n")
    Kettle::Family::Member.new(name: name, root: member.root, gemspec_path: gemspec, version_file: nil, version: member.version, dependencies: [])
  end

  def family_local_env_name
    "#{File.basename(@tmpdir).gsub(/[^A-Za-z0-9]+/, "_").upcase}_DEV"
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
