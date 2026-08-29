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

  it "skips family and member changelog commands when requested" do
    write_release_config(
      publish_command: "bundle exec kettle-release",
      family_changelog: {"enabled" => true, "command" => "bundle exec kettle-changelog"}
    )
    config = Kettle::Family::Config.load(root: @tmpdir)
    member = ready_member("alpha")

    results = described_class.new(
      command: "release",
      config: config,
      members: [member],
      publish: true,
      skip_changelog: true
    ).results

    expect(results.map(&:phase)).to eq(%w[check release_changelog release_publish])
    expect(results.map(&:command).join(" ")).to include("--skip-changelog")
    expect(results.map(&:phase)).not_to include("family_changelog")
  end

  it "does not execute the aggregate monorepo release during a dry-run" do
    write_release_config(
      changelog: {
        "mode" => "root",
        "path" => "CHANGELOG.md",
        "version_file" => "alpha/lib/alpha/version.rb"
      }
    )
    config = Kettle::Family::Config.load(root: @tmpdir)
    member = ready_member("alpha")
    workflow = described_class.new(command: "release", config: config, members: [member], publish: true)

    result = workflow.send(:aggregate_monorepo_github_release, [member])

    expect(result).to be_ok
    expect(result.skipped).to be(true)
    expect(result.reason).to eq("dry-run; pass --execute to run")
  end

  it "keeps raw kettle-release output in the transcript by default" do
    write_release_config
    config = Kettle::Family::Config.load(root: @tmpdir)
    workflow = described_class.new(command: "release", config: config, members: [ready_member("alpha")])

    expect(workflow.send(:release_command_passthrough_output?)).to be(false)
  end

  it "streams raw kettle-release output when verbose output is requested" do
    write_release_config
    config = Kettle::Family::Config.load(root: @tmpdir)
    workflow = described_class.new(command: "release", config: config, members: [ready_member("alpha")], verbose: true)

    expect(workflow.send(:release_command_passthrough_output?)).to be(true)
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
        "version_file" => "alpha/lib/alpha/version.rb"
      },
      release_env: {"KETTLE_DEV_DEV" => false}
    )
    File.write(File.join(@tmpdir, "CHANGELOG.md"), "## [Unreleased]\n")
    File.write(File.join(@tmpdir, "mise.toml"), "[env]\n")
    config = Kettle::Family::Config.load(root: @tmpdir)
    member = ready_member("alpha", changelog: false, version_file: File.join(@tmpdir, "alpha", "lib", "alpha", "version.rb"))

    workflow = described_class.new(command: "release", config: config, members: [member], publish: true)
    results = workflow.results

    expect(results.map(&:phase)).to eq(%w[family_changelog check release_changelog release_publish])
    expect(results.first.command).to end_with(RbConfig.ruby, "-e", "puts 'changelog'")
    expect(results.first.workdir).to eq(member.root)
    expect(results.first.skipped).to be(true)
    expect(workflow.send(:family_changelog_env)).to include(
      "K_CHANGELOG_GEM_NAME" => config.family_name,
      "K_CHANGELOG_COVERAGE_ROOT" => @tmpdir,
      "K_CHANGELOG_PATH" => File.join(@tmpdir, "CHANGELOG.md"),
      "K_CHANGELOG_VERSION_FILE" => File.join(@tmpdir, "alpha", "lib", "alpha", "version.rb")
    )
    expect(workflow.send(:release_env_for_member, member)).to include(
      "K_CHANGELOG_GEM_NAME" => "alpha",
      "K_CHANGELOG_PATH" => File.join(@tmpdir, "CHANGELOG.md"),
      "K_CHANGELOG_VERSION_FILE" => File.join(@tmpdir, "alpha", "lib", "alpha", "version.rb"),
      "K_RELEASE_CI_ROOT" => @tmpdir,
      "K_RELEASE_CI_WORKFLOWS" => "current.yml"
    )
    expect(results.last.command).to eq([RbConfig.ruby, "-e", "puts 'publish'"])
  end

  it "skips the shared family changelog for an independent member-local release" do
    write_release_config(
      publish_command: [RbConfig.ruby, "-e", "puts 'publish'"],
      family_changelog: {"enabled" => true, "command" => [RbConfig.ruby, "-e", "puts 'changelog'"]},
      changelog: {
        "mode" => "root",
        "path" => "CHANGELOG.md",
        "version_file" => "alpha/lib/alpha/version.rb"
      }
    )
    File.write(File.join(@tmpdir, "CHANGELOG.md"), "## [Unreleased]\n")
    config = Kettle::Family::Config.load(root: @tmpdir)
    member = ready_member("alpha", changelog: true, version_file: File.join(@tmpdir, "alpha", "lib", "alpha", "version.rb"))

    results = described_class.new(command: "release", config: config, members: [member], publish: true).results

    expect(results.map(&:phase)).to eq(%w[check release_changelog release_publish])
  end

  it "keeps local monorepo siblings available to the shared changelog suite" do
    write_release_config(
      changelog: {
        "mode" => "root",
        "path" => "CHANGELOG.md",
        "version_file" => "alpha/lib/alpha/version.rb"
      },
      release_env: {"STRUCTUREDMERGE_DEV" => false}
    )
    File.write(
      File.join(@tmpdir, ".kettle-family.yml"),
      YAML.dump(
        "family" => {
          "name" => "structuredmerge-ruby",
          "mode" => "monorepo",
          "local_path_env" => "STRUCTUREDMERGE_DEV",
          "members_root" => "alpha"
        },
        "release" => {"env" => {"STRUCTUREDMERGE_DEV" => false}},
        "changelog" => {
          "mode" => "root",
          "path" => "CHANGELOG.md",
          "version_file" => "alpha/lib/alpha/version.rb"
        }
      )
    )
    File.write(File.join(@tmpdir, "CHANGELOG.md"), "## [Unreleased]\n")
    config = Kettle::Family::Config.load(root: @tmpdir)
    member = ready_member(
      "alpha",
      changelog: false,
      version_file: File.join(@tmpdir, "alpha", "lib", "alpha", "version.rb")
    )
    workflow = described_class.new(
      command: "release",
      config: config,
      members: [member],
      env_overrides: {"STRUCTUREDMERGE_DEV" => File.join(@tmpdir, "gems")}
    )

    expect(workflow.send(:family_changelog_env)).to include(
      "STRUCTUREDMERGE_DEV" => File.join(@tmpdir, "gems")
    )
  end

  it "uses the configured monorepo member root for the shared changelog suite by default" do
    write_release_config(
      changelog: {
        "mode" => "root",
        "path" => "CHANGELOG.md",
        "version_file" => "alpha/lib/alpha/version.rb"
      },
      release_env: {"STRUCTUREDMERGE_DEV" => false}
    )
    File.write(
      File.join(@tmpdir, ".kettle-family.yml"),
      YAML.dump(
        "family" => {
          "name" => "structuredmerge-ruby",
          "mode" => "monorepo",
          "local_path_env" => "STRUCTUREDMERGE_DEV",
          "members_root" => "alpha"
        },
        "release" => {"env" => {"STRUCTUREDMERGE_DEV" => false}},
        "changelog" => {
          "mode" => "root",
          "path" => "CHANGELOG.md",
          "version_file" => "alpha/lib/alpha/version.rb"
        }
      )
    )
    File.write(File.join(@tmpdir, "CHANGELOG.md"), "## [Unreleased]\n")
    config = Kettle::Family::Config.load(root: @tmpdir)
    member = ready_member(
      "alpha",
      changelog: false,
      version_file: File.join(@tmpdir, "alpha", "lib", "alpha", "version.rb")
    )
    workflow = described_class.new(command: "release", config: config, members: [member])

    expect(workflow.send(:family_changelog_env)).to include(
      "STRUCTUREDMERGE_DEV" => File.join(@tmpdir, "alpha")
    )
  end

  it "preserves explicitly selected local kettle-dev tooling for the shared changelog suite" do
    local_kettle_dev = File.join(@tmpdir, "kettle-dev-workspace")
    stub_env("KETTLE_DEV_DEV" => local_kettle_dev)
    write_release_config(
      changelog: {
        "mode" => "root",
        "path" => "CHANGELOG.md",
        "version_file" => "alpha/lib/alpha/version.rb"
      },
      release_env: {"KETTLE_DEV_DEV" => false}
    )
    File.write(File.join(@tmpdir, "CHANGELOG.md"), "## [Unreleased]\n")
    config = Kettle::Family::Config.load(root: @tmpdir)
    member = ready_member(
      "alpha",
      changelog: false,
      version_file: File.join(@tmpdir, "alpha", "lib", "alpha", "version.rb")
    )
    workflow = described_class.new(command: "release", config: config, members: [member])

    expect(workflow.send(:family_changelog_env)).to include(
      "KETTLE_DEV_DEV" => local_kettle_dev
    )
  end

  it "passes accept mode through configured kettle-changelog family changelog commands" do
    write_release_config(
      family_changelog: {"enabled" => true, "command" => "bundle exec kettle-changelog"},
      changelog: {
        "mode" => "root",
        "path" => "CHANGELOG.md",
        "version_file" => "alpha/lib/alpha/version.rb"
      }
    )
    File.write(File.join(@tmpdir, "CHANGELOG.md"), "## [Unreleased]\n")
    config = Kettle::Family::Config.load(root: @tmpdir)
    member = ready_member("alpha", changelog: false, version_file: File.join(@tmpdir, "alpha", "lib", "alpha", "version.rb"))

    workflow = described_class.new(command: "release", config: config, members: [member], publish: true)
    stub_standalone_kettle_changelog(workflow)
    results = workflow.results

    expect(results.first.command.first).to eq(RbConfig.ruby)
    expect(results.first.command[1]).to end_with("/exe/kettle-changelog")
    expect(results.first.command).to include("--yes")
    expect(results.first.command).not_to include("bundle", "exec")
  end

  it "does not duplicate accept mode for configured kettle-changelog family changelog commands" do
    write_release_config(
      family_changelog: {"enabled" => true, "command" => "bundle exec kettle-changelog --yes"},
      changelog: {
        "mode" => "root",
        "path" => "CHANGELOG.md",
        "version_file" => "alpha/lib/alpha/version.rb"
      }
    )
    File.write(File.join(@tmpdir, "CHANGELOG.md"), "## [Unreleased]\n")
    config = Kettle::Family::Config.load(root: @tmpdir)
    member = ready_member("alpha", changelog: false, version_file: File.join(@tmpdir, "alpha", "lib", "alpha", "version.rb"))

    workflow = described_class.new(command: "release", config: config, members: [member], publish: true)
    stub_standalone_kettle_changelog(workflow)
    results = workflow.results

    expect(results.first.command.first).to eq(RbConfig.ruby)
    expect(results.first.command[1]).to end_with("/exe/kettle-changelog")
    expect(results.first.command).to include("--yes")
    expect(results.first.command).not_to include("bundle", "exec")
  end

  it "does not pass accept mode to kettle-changelog when accept mode is disabled" do
    write_release_config(
      family_changelog: {"enabled" => true, "command" => "bundle exec kettle-changelog"},
      changelog: {
        "mode" => "root",
        "path" => "CHANGELOG.md",
        "version_file" => "alpha/lib/alpha/version.rb"
      }
    )
    File.write(File.join(@tmpdir, "CHANGELOG.md"), "## [Unreleased]\n")
    config = Kettle::Family::Config.load(root: @tmpdir)
    member = ready_member("alpha", changelog: false, version_file: File.join(@tmpdir, "alpha", "lib", "alpha", "version.rb"))

    workflow = described_class.new(command: "release", config: config, members: [member], publish: true, accept: false)
    stub_standalone_kettle_changelog(workflow)
    results = workflow.results

    expect(results.first.command.first).to eq(RbConfig.ruby)
    expect(results.first.command[1]).to end_with("/exe/kettle-changelog")
    expect(results.first.command).not_to include("bundle", "exec", "--yes")
  end

  it "falls back to a selected member version file for partial shared root releases" do
    write_release_config(
      family_changelog: {"enabled" => true, "command" => "bundle exec kettle-changelog"},
      changelog: {
        "mode" => "root",
        "path" => "CHANGELOG.md",
        "version_file" => "gems/tree_haver/lib/tree_haver/version.rb"
      }
    )
    File.write(File.join(@tmpdir, "CHANGELOG.md"), "## [Unreleased]\n")
    config = Kettle::Family::Config.load(root: @tmpdir)
    member = ready_member(
      "alpha",
      changelog: false,
      version_file: File.join(@tmpdir, "alpha", "lib", "alpha", "version.rb")
    )

    results = described_class.new(command: "release", config: config, members: [member], publish: true).results

    expect(results.first).to be_ok
  end

  it "uses the selected member version file when a shared root version file is unset" do
    write_release_config(
      family_changelog: {"enabled" => true, "command" => "bundle exec kettle-changelog"},
      changelog: {"mode" => "root", "path" => "CHANGELOG.md"}
    )
    File.write(File.join(@tmpdir, "CHANGELOG.md"), "## [Unreleased]\n")
    config = Kettle::Family::Config.load(root: @tmpdir)
    member = ready_member(
      "alpha",
      changelog: false,
      version_file: File.join(@tmpdir, "alpha", "lib", "alpha", "version.rb")
    )
    workflow = described_class.new(command: "release", config: config, members: [member], publish: true)

    expect(workflow.send(:family_changelog_member)).to eq(member)
    expect(workflow.send(:family_changelog_env).fetch("K_CHANGELOG_VERSION_FILE"))
      .to end_with("alpha/lib/alpha/version.rb")
  end

  it "rejects an out-of-selection shared version file when no selected member has one" do
    write_release_config(
      family_changelog: {"enabled" => true, "command" => "bundle exec kettle-changelog"},
      changelog: {
        "mode" => "root",
        "path" => "CHANGELOG.md",
        "version_file" => "gems/tree_haver/lib/tree_haver/version.rb"
      }
    )
    File.write(File.join(@tmpdir, "CHANGELOG.md"), "## [Unreleased]\n")
    config = Kettle::Family::Config.load(root: @tmpdir)
    member = ready_member("alpha", changelog: false)
    workflow = described_class.new(command: "release", config: config, members: [member], publish: true)

    expect { workflow.send(:family_changelog_member) }
      .to raise_error(Kettle::Family::Error, /shared root changelog release requires changelog.version_file/)
  end

  it "keeps the configured shared root version file when its member was released earlier" do
    write_release_config(
      family_changelog: {"enabled" => true, "command" => "bundle exec kettle-changelog"},
      changelog: {
        "mode" => "root",
        "path" => "CHANGELOG.md",
        "version_file" => "alpha/lib/alpha/version.rb"
      }
    )
    File.write(File.join(@tmpdir, "CHANGELOG.md"), "## [Unreleased]\n")
    config = Kettle::Family::Config.load(root: @tmpdir)
    anchor = ready_member(
      "alpha",
      changelog: false,
      version_file: File.join(@tmpdir, "alpha", "lib", "alpha", "version.rb")
    )
    selected = ready_member("beta", changelog: false)
    kettle_jem = ready_member("kettle-jem")
    workflow = described_class.new(
      command: "release",
      config: config,
      members: [selected, kettle_jem],
      family_members: [anchor, selected, kettle_jem],
      publish: true
    )

    expect(workflow.send(:family_changelog_member)).to eq(anchor)
    expect(workflow.send(:family_changelog_env).fetch("K_CHANGELOG_VERSION_FILE"))
      .to eq(File.join(@tmpdir, "alpha", "lib", "alpha", "version.rb"))
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

  it "uses a member-local changelog inside a shared-changelog monorepo" do
    write_release_config(
      changelog: {
        "mode" => "root",
        "path" => "CHANGELOG.md",
        "version_file" => "alpha/lib/alpha/version.rb"
      }
    )
    File.write(File.join(@tmpdir, "CHANGELOG.md"), "## [Unreleased]\n")
    config = Kettle::Family::Config.load(root: @tmpdir)
    member = ready_member("kettle-jem", version_file: File.join(@tmpdir, "kettle-jem", "lib", "kettle", "jem", "version.rb"))

    workflow = described_class.new(command: "release", config: config, members: [member])

    expect(workflow.send(:release_env_for_member, member)).to include(
      "K_CHANGELOG_GEM_NAME" => "kettle-jem",
      "K_CHANGELOG_PATH" => File.join(member.root, "CHANGELOG.md"),
      "K_CHANGELOG_VERSION_FILE" => member.version_file
    )
    expect(Kettle::Family::ChangelogCheck.call(member: member, config: config)).to be_ok
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
      skip_remotes: "cb",
      required_remotes: "origin"
    ).results

    expect(results.last.command).to eq(["sh", "-lc", "bundle exec kettle-release start_step=10 skip_steps=10 --ci-workflows=current,style.yml --local-ci --skip-bundle-audit --skip-remotes=cb --required-remotes=origin --yes --events"])
  end

  it "lets kettle-release own release lockfile normalization" do
    write_release_config(
      publish_command: "bundle exec kettle-release",
      release_normalize_lockfiles: true
    )
    config = Kettle::Family::Config.load(root: @tmpdir)
    member = ready_member("alpha")
    workflow = described_class.new(command: "release", config: config, members: [member], publish: true, execute: true)

    expect(workflow.send(:normalize_release_lockfiles?, member)).to be(false)
    expect(workflow.send(:release_phase_total, member)).to eq(3)
  end

  it "lets kettle-release normalize existing local path remotes before readiness" do
    write_release_config(publish_command: "bundle exec kettle-release")
    config = Kettle::Family::Config.load(root: @tmpdir)
    member = ready_member("alpha")
    local_root = File.join(@tmpdir, "local-family")
    FileUtils.mkdir_p(File.join(local_root, "beta"))
    File.write(File.join(member.root, "Gemfile.lock"), "PATH\n  remote: #{File.join(local_root, "beta")}\n")

    results = described_class.new(
      command: "release",
      config: config,
      members: [member],
      publish: true
    ).results

    expect(results.map(&:phase)).to eq(%w[check release_changelog release_publish])
    expect(results.first).to be_ok
  end

  it "allows active family roots through readiness when release env disables them" do
    local_root = File.join(@tmpdir, "gems")
    FileUtils.mkdir_p(File.join(local_root, "beta"))
    write_release_config(
      publish_command: "bundle exec kettle-release",
      release_env: {
        family_local_env_name => false,
        "KETTLE_DEV_DEV" => false
      }
    )
    config = Kettle::Family::Config.load(root: @tmpdir)
    member = ready_member("alpha")
    File.write(File.join(member.root, "Gemfile.lock"), "PATH\n  remote: #{File.join(local_root, "beta")}\n")
    workflow = described_class.new(
      command: "release",
      config: config,
      members: [member],
      publish: true,
      execute: true,
      env_overrides: {
        family_local_env_name => local_root,
        "KETTLE_DEV_DEV" => File.join(@tmpdir, "kettle-dev")
      }
    )

    expect(workflow.send(:release_allowed_local_path_roots)).to include(local_root)
    expect(workflow.send(:normalize_release_lockfiles?, member)).to be(false)
    memo = []
    workflow.send(:append_release_internal_checks, member: member, memo: memo)
    expect(memo.first).to be_ok
  end

  it "passes configured required release remotes through kettle-release commands" do
    write_release_config(
      publish_command: "bundle exec kettle-release",
      required_remotes: %w[origin github]
    )
    config = Kettle::Family::Config.load(root: @tmpdir)
    member = ready_member("alpha")

    results = described_class.new(
      command: "release",
      config: config,
      members: [member],
      publish: true
    ).results

    expect(results.last.command).to eq(["sh", "-lc", "bundle exec kettle-release --required-remotes=origin,github --yes --events"])
  end

  it "delegates configured 1Password secrets to kettle-release by default" do
    write_release_config(
      publish_command: "bundle exec kettle-release",
      secrets: {
        "provider" => "1password",
        "cli" => "/opt/1Password/op",
        "item" => "Rubygems",
        "rubygems_otp_field" => "one-time password"
      }
    )
    config = Kettle::Family::Config.load(root: @tmpdir)
    member = ready_member("alpha")
    workflow = described_class.new(command: "release", config: config, members: [member], publish: true)
    workflow.instance_variable_set(:@gem_signing_password, "cached-secret")
    workflow.instance_variable_set(:@secrets_provider, Kettle::Family::Secrets::OnePassword.new(config.release_secrets))
    allow(workflow).to receive(:kettle_release_supports_direct_secrets?).and_return(true)

    results = workflow.results

    expect(results.last.command).to eq(["sh", "-lc", "bundle exec kettle-release --secrets-provider=1password --yes --events"])
    expect(results.last.command).not_to include("cached-secret")
    expect(results.last.command).not_to include("one-time password")
    release_env = workflow.send(:release_env)
    expect(release_env).to include(
      "KETTLE_RELEASE_SECRETS_PROVIDER" => "1password",
      "KETTLE_RELEASE_GEM_SIGNING_PASSPHRASE_SOURCE" => "cached",
      "KETTLE_RELEASE_GEM_SIGNING_PASSPHRASE" => "cached-secret",
      "KETTLE_RELEASE_1PASSWORD_CLI" => "/opt/1Password/op",
      "KETTLE_RELEASE_1PASSWORD_ITEM" => "Rubygems",
      "KETTLE_RELEASE_1PASSWORD_RUBYGEMS_OTP_FIELD" => "one-time password"
    )
  end

  it "does not create a family OTP coordinator for delegated kettle-release commands" do
    write_release_config(
      publish_command: "bundle exec kettle-release",
      secrets: {"provider" => "1password"}
    )
    config = Kettle::Family::Config.load(root: @tmpdir)
    member = ready_member("alpha")
    provider = Kettle::Family::Secrets::OnePassword.new(config.release_secrets)
    workflow = described_class.new(command: "release", config: config, members: [member], publish: true, secrets_provider: provider)
    workflow.instance_variable_set(:@gem_signing_password, "cached-secret")

    runner = workflow.send(:release_command_runner)

    expect(runner.instance_variable_get(:@gem_signing_password)).to be_nil
    expect(runner.instance_variable_get(:@otp_coordinator)).to be_nil
  end

  it "uses one family-owned secrets broker for delegated kettle-release commands" do
    write_release_config(
      publish_command: "bundle exec kettle-release",
      secrets: {"provider" => "1password"}
    )
    config = Kettle::Family::Config.load(root: @tmpdir)
    workflow = described_class.new(command: "release", config: config, members: [ready_member("alpha")], publish: true)
    broker = instance_double(Kettle::Family::Secrets::Broker, path: File.join(@tmpdir, "secrets.sock"))
    workflow.instance_variable_set(:@release_secrets_broker, broker)
    workflow.instance_variable_set(:@gem_signing_password, "cached-secret")
    workflow.instance_variable_set(:@secrets_provider, Kettle::Family::Secrets::OnePassword.new(config.release_secrets))

    command = workflow.send(:append_kettle_release_args, ["bundle", "exec", "kettle-release"])

    expect(command).to include("--secrets-provider=family")
    expect(workflow.send(:release_env)).to include(
      "KETTLE_RELEASE_SECRETS_PROVIDER" => "family",
      "KETTLE_RELEASE_SECRETS_BROKER" => broker.path,
      "KETTLE_RELEASE_GEM_SIGNING_PASSPHRASE" => "cached-secret"
    )
  end

  it "applies fast recovery only to the named release member" do
    write_release_config(publish_command: "bundle exec kettle-release")
    config = Kettle::Family::Config.load(root: @tmpdir)
    alpha = ready_member("alpha")
    beta = ready_member("beta")
    workflow = described_class.new(
      command: "release",
      config: config,
      members: [alpha, beta],
      family_members: [alpha, beta],
      publish: true,
      fast_recovery: "skip-ci",
      fast_recovery_members: "alpha"
    )

    alpha_command = workflow.send(:release_command_for, alpha)
    beta_command = workflow.send(:release_command_for, beta)

    expect(alpha_command.to_s).to include("start_step=11")
    expect(beta_command.to_s).not_to include("start_step=")
  end

  it "supports retrying CI as a named fast recovery mode" do
    write_release_config(publish_command: "bundle exec kettle-release")
    config = Kettle::Family::Config.load(root: @tmpdir)
    alpha = ready_member("alpha")
    workflow = described_class.new(
      command: "release",
      config: config,
      members: [alpha],
      publish: true,
      fast_recovery: "retry-ci"
    )

    expect(workflow.send(:release_command_for, alpha).to_s).to include("start_step=10")
  end

  it "skips remote CI for every selected member without skipping release preparation" do
    write_release_config(publish_command: "bundle exec kettle-release")
    config = Kettle::Family::Config.load(root: @tmpdir)
    alpha = ready_member("alpha")
    workflow = described_class.new(
      command: "release",
      config: config,
      members: [alpha],
      publish: true,
      skip_ci: true
    )

    command = workflow.send(:release_command_for, alpha)

    expect(command.to_s).to include("skip_steps=10")
    expect(command.to_s).not_to include("start_step=")
  end

  it "rejects fast recovery members that are not selected" do
    write_release_config(publish_command: "bundle exec kettle-release")
    config = Kettle::Family::Config.load(root: @tmpdir)
    alpha = ready_member("alpha")
    beta = ready_member("beta")

    expect {
      described_class.new(
        command: "release",
        config: config,
        members: [alpha],
        family_members: [alpha, beta],
        publish: true,
        fast_recovery: "skip-ci",
        fast_recovery_members: "beta"
      )
    }.to raise_error(Kettle::Family::Error, /must be selected/)
  end

  it "delegates secrets to kettle-release when the publish command explicitly includes a secrets provider" do
    write_release_config(
      publish_command: "bundle exec kettle-release --secrets-provider=1password",
      secrets: {
        "provider" => "1password",
        "item" => "Rubygems"
      }
    )
    config = Kettle::Family::Config.load(root: @tmpdir)
    member = ready_member("alpha")
    workflow = described_class.new(command: "release", config: config, members: [member], publish: true)
    workflow.instance_variable_set(:@gem_signing_password, "cached-secret")
    workflow.instance_variable_set(:@secrets_provider, Kettle::Family::Secrets::OnePassword.new(config.release_secrets))
    allow(workflow).to receive(:kettle_release_supports_direct_secrets?).and_return(true)

    results = workflow.results

    expect(results.last.command).to eq(["sh", "-lc", "bundle exec kettle-release --secrets-provider=1password --yes --events"])
    expect(results.last.command).not_to include("cached-secret")
    expect(workflow.send(:release_env)).to include(
      "KETTLE_RELEASE_SECRETS_PROVIDER" => "1password",
      "KETTLE_RELEASE_GEM_SIGNING_PASSPHRASE_SOURCE" => "cached",
      "KETTLE_RELEASE_GEM_SIGNING_PASSPHRASE" => "cached-secret"
    )
  end

  it "does not pass --yes to kettle-release when accept mode is disabled" do
    write_release_config(publish_command: "bundle exec kettle-release")
    config = Kettle::Family::Config.load(root: @tmpdir)
    member = ready_member("alpha")

    results = described_class.new(
      command: "release",
      config: config,
      members: [member],
      publish: true,
      accept: false
    ).results

    expect(results.last.command).to eq(["sh", "-lc", "bundle exec kettle-release --events"])
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

  it "keeps local kettle-dev tooling available to member release commands" do
    local_kettle_dev = File.join(@tmpdir, "kettle-dev-workspace")
    FileUtils.mkdir_p(File.join(local_kettle_dev, "kettle-dev"))
    File.write(File.join(local_kettle_dev, "kettle-dev", "Gemfile"), "source 'https://gem.coop'\n")
    stub_env("KETTLE_DEV_DEV" => local_kettle_dev)
    write_release_config(
      publish_command: "bundle exec kettle-release",
      release_env: {"KETTLE_DEV_DEV" => false}
    )
    config = Kettle::Family::Config.load(root: @tmpdir)
    member = ready_member("alpha")
    workflow = described_class.new(command: "release", config: config, members: [member], publish: true)

    expect(workflow.send(:release_env_for_member, member)).to include(
      "KETTLE_DEV_DEV" => local_kettle_dev,
      "BUNDLE_GEMFILE" => File.join(local_kettle_dev, "kettle-dev", "Gemfile")
    )
  end

  it "shrinks the family-local release environment after selected dependencies complete" do
    write_release_config(
      release_env: {family_local_env_name => @tmpdir}
    )
    File.write(
      File.join(@tmpdir, ".kettle-family.yml"),
      YAML.load_file(File.join(@tmpdir, ".kettle-family.yml")).merge(
        "release" => {
          "env" => {family_local_env_name => @tmpdir},
          "local_path_strategy" => "waves"
        }
      ).to_yaml
    )
    config = Kettle::Family::Config.load(root: @tmpdir)
    alpha = ready_member("alpha", dependencies: ["beta"])
    beta = ready_member("beta")
    workflow = described_class.new(
      command: "release",
      config: config,
      members: [beta, alpha],
      env_overrides: {family_local_env_name => @tmpdir}
    )

    expect(workflow.send(:release_env_for_member, alpha)).to include(family_local_env_name => @tmpdir)

    workflow.instance_variable_set(:@release_completed_member_names, ["beta"])

    expect(workflow.send(:release_env_for_member, alpha)).to include(family_local_env_name => "false")
  end

  it "uses released paths for dependencies outside the selected release set" do
    write_release_config(
      release_env: {family_local_env_name => @tmpdir}
    )
    File.write(
      File.join(@tmpdir, ".kettle-family.yml"),
      YAML.load_file(File.join(@tmpdir, ".kettle-family.yml")).merge(
        "release" => {
          "env" => {family_local_env_name => @tmpdir},
          "local_path_strategy" => "waves"
        }
      ).to_yaml
    )
    config = Kettle::Family::Config.load(root: @tmpdir)
    member = ready_member("alpha", dependencies: ["released-dependency"])
    workflow = described_class.new(
      command: "release",
      config: config,
      members: [member],
      env_overrides: {family_local_env_name => @tmpdir}
    )

    expect(workflow.send(:release_env_for_member, member)).to include(family_local_env_name => "false")
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

  it "uses a configured secrets provider for the gem signing password" do
    write_release_config(
      build_command: [
        RbConfig.ruby,
        "-e",
        "print 'Enter PEM pass phrase:'; $stdout.flush; exit(STDIN.gets&.chomp == 'secret' ? 0 : 1)"
      ]
    )
    config = Kettle::Family::Config.load(root: @tmpdir)
    member = signed_member("alpha")
    provider = instance_double(Kettle::Family::Secrets::Provider, gem_signing_passphrase: "secret")
    workflow = described_class.new(command: "release", config: config, members: [member], execute: true, secrets_provider: provider)

    results = workflow.results

    expect(results).to all(be_ok)
    expect(provider).to have_received(:gem_signing_passphrase).once
  end

  it "authorizes configured release secrets during the first release preflight phase" do
    write_release_config(
      publish_command: [RbConfig.ruby, "-e", "puts 'publish'"],
      secrets: {
        "provider" => "1password",
        "item" => "Rubygems"
      }
    )
    config = Kettle::Family::Config.load(root: @tmpdir)
    member = ready_member("alpha")
    provider = Kettle::Family::Secrets::OnePassword.new(config.release_secrets)
    progress = StringIO.new
    allow(progress).to receive(:tty?).and_return(true)
    workflow = described_class.new(command: "release", config: config, members: [member], execute: true, publish: true, secrets_provider: provider, progress_io: progress)
    allow(provider).to receive(:authorize!).and_return("secret")
    allow(workflow).to receive(:released_version?).and_return(false)

    results = workflow.results

    expect(results).to all(be_ok)
    expect(provider).to have_received(:authorize!).once
    expect(progress.string).to include("release preflight 3 phases:")
    expect(progress.string).to include("preflight")
    expect(progress.string).to include(">.>.>.")
    expect(progress.string).to include("ok")
    expect(progress.string).not_to include("[release preflight] (1/3) > secrets provider authorization")
    expect(progress.string).not_to include("[release preflight] . secrets provider authorization")
    expect(progress.string).not_to include("release preflight summary")
  end

  it "stops release execution when configured release secret authorization fails" do
    write_release_config(
      publish_command: [RbConfig.ruby, "-e", "abort 'should not publish'"],
      secrets: {
        "provider" => "1password",
        "item" => "Rubygems"
      }
    )
    config = Kettle::Family::Config.load(root: @tmpdir)
    member = ready_member("alpha")
    provider = Kettle::Family::Secrets::OnePassword.new(config.release_secrets)
    progress = StringIO.new
    workflow = described_class.new(command: "release", config: config, members: [member], execute: true, publish: true, secrets_provider: provider, progress_io: progress)
    allow(provider).to receive(:authorize!).and_raise(Kettle::Family::Error, "not signed in")

    results = workflow.results

    expect(results.map(&:phase)).to eq(["secrets_provider_authorization"])
    expect(results.first).not_to be_ok
    expect(results.first.stderr).to eq("not signed in")
    expect(progress.string).to include("[preflight]   (1/3)")
    expect(progress.string).to include("F secrets provider authorization")
    expect(progress.string).not_to include("release preflight summary")
  end

  it "runs release preflight without progress output when progress rendering is disabled" do
    write_release_config(build_command: [RbConfig.ruby, "-e", "puts 'build'"])
    config = Kettle::Family::Config.load(root: @tmpdir)
    member = ready_member("alpha")
    workflow = described_class.new(command: "release", config: config, members: [member], execute: true)

    results = workflow.results

    expect(results.map(&:phase)).to eq(%w[check release_changelog release_build])
    expect(results).to all(be_ok)
  end

  it "reviews action pins once and passes the reviewed cache to delegated releases" do
    fake_bin = File.join(@tmpdir, "fake-bin")
    FileUtils.mkdir_p(fake_bin)
    fake_executable = File.join(fake_bin, "kettle-gha-pins")
    File.write(fake_executable, <<~RUBY)
      #!/usr/bin/env ruby
      require "json"

      if ARGV.include?("--list")
        puts JSON.generate("schema_version" => 1, "repositories" => ["actions/checkout"])
      elsif ARGV.include?("--review")
        puts JSON.generate("mode" => "review", "repositories" => [{"repository" => "actions/checkout"}])
      else
        exit 0
      end
    RUBY
    FileUtils.chmod("u+x", fake_executable)
    write_release_config(publish_command: "bundle exec kettle-release")
    config = Kettle::Family::Config.load(root: @tmpdir)
    member = ready_member("alpha")
    workflow = described_class.new(
      command: "release",
      config: config,
      members: [member],
      execute: true,
      publish: true,
      commit: false,
      gem_signing_password: "secret",
      env_overrides: {"PATH" => "#{fake_bin}:#{ENV.fetch("PATH")}"}
    )
    allow(workflow).to receive(:installed_gem_executable).with("kettle-gha-pins", "kettle-gha-pins").and_return(fake_executable)

    results = workflow.send(:release_preflight_gha_sha_pins_results)

    expect(results.map(&:phase)).to eq(%w[gha_sha_pins_list gha_sha_pins_review])
    expect(results).to all(be_ok)
    expect(results.first.command.first).to eq(RbConfig.ruby)
    expect(results.first.command).not_to include("bundle", "exec")
    expect(results.map(&:log_path)).to all(start_with(File.join(@tmpdir, "tmp", "kettle-family")))
    expect(results.map(&:log_path)).to all(satisfy { |path| File.file?(path) })
    expect(workflow.send(:release_preflight_results)).to be_empty
    expect(workflow.send(:release_env_for_member, member)).to include(
      "KETTLE_PRE_RELEASE_GHA_SHA_PINS_OFFLINE" => "true"
    )
  end

  it "renders a singular release preflight phase heading" do
    write_release_config
    config = Kettle::Family::Config.load(root: @tmpdir)
    progress = StringIO.new
    workflow = described_class.new(command: "release", config: config, members: [ready_member("alpha")], execute: true, progress_io: progress)

    progress_renderer = workflow.send(:start_release_preflight_progress, [{label: "check", method: :release_preflight_branch_checkout_dirty_results}])
    progress_renderer.start

    expect(progress.string).to include("release preflight 1 phase:")
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
      "KETTLE_FAMILY_CONFIG=#{File.join(@tmpdir, ".kettle-family.yml")}"
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
      release_bundle_install
      check
      release_changelog
      release_build
    ])
    expect(results.first.command).to eq(["sh", "-lc", "bundle lock"])
    expect(File.read(File.join(member.root, "Gemfile.lock"))).not_to include("PATH")
    expect(results).to all(be_ok)
  end

  it "skips dry-run release readiness when lockfiles require normalization first" do
    write_release_config(build_command: [RbConfig.ruby, "-e", "puts 'build'"])
    config = Kettle::Family::Config.load(root: @tmpdir)
    member = ready_member("alpha")
    external_root = File.join(Dir.home, ".cache", "kettle-family-spec-external")
    File.write(File.join(member.root, "Gemfile.lock"), "PATH\n  remote: #{external_root}/beta\n")

    results = described_class.new(
      command: "release",
      config: config,
      members: [member],
      execute: false,
      env_overrides: fake_bundle_env
    ).results

    expect(results.map(&:phase)).to eq(%w[
      release_normalize_lockfiles
      commit_normalized_lockfiles
      release_build
    ])
    expect(results).to all(be_ok)
    expect(results).to all(have_attributes(skipped: true))
    expect(results.last.reason).to eq("dry-run; release readiness requires lockfile normalization")
  end

  it "re-normalizes lockfiles dirtied by release commands before pushing" do
    write_release_config(
      build_command: [
        RbConfig.ruby,
        "-e",
        "File.write('Gemfile.lock', \"PATH\\n  remote: #{@tmpdir}/beta\\n\")"
      ]
    )
    config = Kettle::Family::Config.load(root: @tmpdir)
    member = ready_member("alpha")

    results = described_class.new(
      command: "release",
      config: config,
      members: [member],
      execute: true,
      commit: false,
      push: true,
      env_overrides: fake_bundle_env
    ).results

    expect(results.map(&:phase)).to eq(%w[
      check
      release_changelog
      release_build
      release_normalize_lockfiles
      release_bundle_install
      release_push
    ])
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
      "RUBOCOP_LTS_LOCAL=false",
      "#{family_local_env_name}=false",
      "STRUCTUREDMERGE_DEV=false"
    )
    expect(results.first.command).not_to include("RUBOCOP_LTS_LOCAL=/workspace/rubocop-lts")
    expect(results.first.command).not_to include("#{family_local_env_name}=/workspace/family")
    expect(results.first.command).not_to include("STRUCTUREDMERGE_DEV=/workspace/structuredmerge/ruby/gems")
  end

  it "forces truthy local path toggles off during lockfile normalization" do
    write_release_config(
      build_command: [RbConfig.ruby, "-e", "puts 'build'"],
      template: {
        "normalize_lockfiles" => true,
        "normalize_lockfiles_command" => %w[bundle lock]
      }
    )
    config = Kettle::Family::Config.load(root: @tmpdir)
    member = ready_member("alpha")

    workflow = described_class.new(
      command: "release",
      config: config,
      members: [member],
      env_overrides: {
        "SOME_TOOL_LOCAL" => "enabled",
        "SOME_TOOL_DEV" => "1",
        "OTHER_TOOL_DEV" => "./vendor/other"
      }
    )

    lockfile_env = workflow.send(:release_lockfile_env)

    expect(lockfile_env).to include("OTHER_TOOL_DEV" => "false")
    expect(lockfile_env).to include("SOME_TOOL_LOCAL" => "false", "SOME_TOOL_DEV" => "false")
  end

  it "keeps truthy local path toggles out of release readiness path roots" do
    write_release_config(build_command: [RbConfig.ruby, "-e", "puts 'build'"])
    config = Kettle::Family::Config.load(root: @tmpdir)
    local_root = File.join(@tmpdir, "rubocop-lts")
    workflow = described_class.new(
      command: "release",
      config: config,
      members: [ready_member("alpha")],
      env_overrides: {
        "SOME_TOOL_LOCAL" => "enabled",
        "SOME_TOOL_DEV" => "1",
        "OTHER_TOOL_DEV" => local_root
      }
    )

    roots = workflow.send(:release_allowed_local_path_roots)
    expect(roots).to include(local_root)
    expect(roots).not_to include("enabled", "1")
  end

  it "infers local path env names from family roots found in lockfile remotes" do
    write_release_config(build_command: [RbConfig.ruby, "-e", "puts 'build'"])
    config = Kettle::Family::Config.load(root: @tmpdir)
    member = ready_member("alpha")
    other_family = File.join(@tmpdir, "families", "ruby-oauth")
    FileUtils.mkdir_p(File.join(other_family, "oauth2"))
    File.write(File.join(other_family, ".kettle-family.yml"), <<~YAML)
      family:
        name: ruby-oauth
        local_path_env: RUBY_OAUTH_DEV
    YAML
    File.write(File.join(member.root, "Gemfile.lock"), "PATH\n  remote: #{File.join(other_family, "oauth2")}\n")
    workflow = described_class.new(command: "release", config: config, members: [member])

    lockfile_env = workflow.send(:release_lockfile_env, member)

    expect(lockfile_env).to include("RUBY_OAUTH_DEV" => "false")
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

  it "allows implicit family-local lockfile paths during release readiness" do
    write_release_config(build_command: [RbConfig.ruby, "-e", "puts 'build'"])
    config = Kettle::Family::Config.load(root: @tmpdir)
    member = ready_member("alpha")
    File.write(File.join(member.root, "Gemfile.lock"), "PATH\n  remote: #{File.join(@tmpdir, "beta")}\n")

    results = described_class.new(command: "release", config: config, members: [member]).results

    check_result = results.find { |result| result.phase == "check" }
    expect(check_result).to be_ok
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

  it "checks published versions through the shared RubyGems version cache API" do
    write_release_config
    config = Kettle::Family::Config.load(root: @tmpdir)
    member = ready_member("alpha")
    workflow = described_class.new(command: "release", config: config, members: [member], execute: true, publish: true)
    allow(Kettle::Dev::RubyGemsVersions).to receive(:fetch)
      .with("alpha", version_hint: "1.0.0")
      .and_return([{"number" => "0.9.0"}, {"number" => "1.0.0"}])

    expect(workflow.send(:released_version?, "alpha", "1.0.0")).to be(true)
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
    expect(progress.string).to match(/\[alpha\]\s+\(3\/3\)\s+\d{2}:\d{2}\s+\.\s+release_build/)
    expect(progress.string).to match(/\[beta\]\s+\(3\/3\)\s+\d{2}:\d{2}\s+\.\s+release_build/)
    expect(progress.string).to include("release summary: 2/2 members ok")
  end

  it "maps release NDJSON events to progress lines" do
    write_release_config
    config = Kettle::Family::Config.load(root: @tmpdir)
    member = ready_member("alpha")
    progress = StringIO.new
    workflow = described_class.new(command: "release", config: config, members: [member], verbose: true, progress_io: progress)

    handler = workflow.send(:release_event_line_handler, member)
    [
      {event_version: 1, type: "run_start", command: "release"},
      {event_version: 1, type: "command_step", phase: "release", name: "bundle_lock", summary: "Gemfile", status: "started", mark: ">"},
      {event_version: 1, type: "secret_provider", action: "keepalive", purpose: "CI monitoring", status: "started", mark: ">"},
      {event_version: 1, type: "remote_parity", action: "fetch", remote: "cb", status: "started", mark: ">"},
      {event_version: 1, type: "ci_monitor", action: "github_wait", provider: "github", completed: 0, total: 2, status: "started", mark: ">"},
      {event_version: 1, type: "ci_monitor", action: "github_workflow", provider: "github", workflow: "ci.yml", status: "started", mark: ">"},
      {event_version: 1, type: "ci_monitor", action: "github_tick", provider: "github", workflow: "style.yml", completed: 1, total: 2, completed_workflow: "ci.yml", status: "started", mark: ">"},
      {event_version: 1, type: "pre_release", action: "check", check: "image_links", status: "started", mark: ">"},
      {event_version: 1, type: "changelog", action: "coverage", status: "started", mark: ">"},
      {
        event_version: 1,
        type: "release_lockfile",
        action: "reset",
        stage: "before release task bundle installs",
        attempt: 1,
        attempts: 2,
        status: "started",
        mark: ">"
      },
      {
        event_version: 1,
        type: "release_probe",
        action: "availability",
        gem: "alpha",
        version: "1.2.3",
        attempt: 1,
        attempts: 3,
        status: "started",
        mark: ">"
      },
      {event_version: 1, type: "diagnostic", kind: "remote_fetch", message: "cb unavailable"},
      {event_version: 1, type: "summary", status: "failed"}
    ].each { |event| handler.call(JSON.generate(event)) }

    expect(progress.string).to include("[alpha] > release")
    expect(progress.string).to include("[alpha] > release:bundle_lock:Gemfile")
    expect(progress.string).to include("[alpha] > secret:keepalive:CI monitoring")
    expect(progress.string).to include("[alpha] > remote:fetch:cb")
    expect(progress.string).to include("[alpha] > ci:github_wait:github:0/2")
    expect(progress.string).to include("[alpha] > ci:github_workflow:github:ci.yml")
    expect(progress.string).to include("[alpha] > ci:github_tick:github:style.yml:1/2:ci.yml")
    expect(progress.string).to include("[alpha] > pre:check:image_links")
    expect(progress.string).to include("[alpha] > changelog:coverage")
    expect(progress.string).to include("[alpha] > lockfile:reset:before_release_task_bundle_installs:1/2")
    expect(progress.string).to include("[alpha] > probe:availability:alpha-1.2.3:1/3")
    expect(progress.string).to include("[alpha] ! cb unavailable")
    expect(progress.string).to include("[alpha] F failed")
  end

  it "consumes release NDJSON events when progress rendering is disabled" do
    write_release_config
    config = Kettle::Family::Config.load(root: @tmpdir)
    member = ready_member("alpha")
    workflow = described_class.new(command: "release", config: config, members: [member])

    handler = workflow.send(:release_event_line_handler, member)

    expect(handler.call(JSON.generate(event_version: 1, type: "summary", status: "ok"))).to be(true)
    expect(handler.call("plain release output")).to be(false)
  end

  it "maps release NDJSON events to TTY progress updates" do
    write_release_config
    config = Kettle::Family::Config.load(root: @tmpdir)
    member = ready_member("alpha")
    updates = []
    notifications = []
    progress = Class.new do
      define_method(:initialize) { |target, notification_target|
        @target = target
        @notification_target = notification_target
      }
      define_method(:tty?) { true }
      define_method(:notification) { |message| @notification_target << message }
      define_method(:update) do |_member, status:, mark:|
        @target << [status, mark]
      end
    end.new(updates, notifications)
    workflow = described_class.new(command: "release", config: config, members: [member], progress_io: StringIO.new)

    handler = workflow.send(:release_event_line_handler, member, progress: progress)
    [
      {event_version: 1, type: "run_start", command: "release"},
      {event_version: 1, type: "command_step", phase: "release", name: "yard", summary: "documentation", status: "ok", mark: "."},
      {event_version: 1, type: "secret_provider", action: "prompt_request", label: "👀 🔒 watch for authorization prompt", source: "1Password", status: "started", mark: ">"},
      {event_version: 1, type: "secret_provider", action: "otp_queue", label: "RubyGems MFA prompts", queued: 1, total: 4, status: "queued", mark: ">"},
      {event_version: 1, type: "secret_provider", action: "prompt_response", label: "RubyGems MFA code", status: "ok", mark: "."},
      {event_version: 1, type: "remote_parity", action: "skip", remote: "cb", status: "skipped", mark: "."},
      {event_version: 1, type: "ci_monitor", action: "github_started", provider: "github", completed: 0, total: 2, started: 2, status: "ok", mark: "."},
      {event_version: 1, type: "ci_monitor", action: "gitlab_pipeline", provider: "gitlab", status: "ok", mark: "."},
      {event_version: 1, type: "pre_release", action: "image_links", status: "ok", mark: "."},
      {event_version: 1, type: "changelog", action: "plan", plan: "create_release", status: "ok", mark: "."},
      {event_version: 1, type: "release_lockfile", action: "validate", stage: "before push", status: "ok", mark: "."},
      {
        event_version: 1,
        type: "release_probe",
        action: "availability",
        gem: "alpha",
        version: "1.2.3",
        attempt: 2,
        attempts: 3,
        status: "ok",
        mark: "."
      },
      {event_version: 1, type: "diagnostic", kind: "remote_fetch", message: ""},
      {event_version: 1, type: "summary", status: "ok"}
    ].each { |event| handler.call(JSON.generate(event)) }

    expect(updates).to include(["release", ">"])
    expect(updates).to include(["release:yard:documentation", "."])
    expect(notifications).to eq(["👀 🔒 watch for authorization prompt", ""])
    expect(updates).not_to include(["secret:prompt_request:👀 🔒 watch for authorization prompt", ">"])
    expect(updates).not_to include(["secret:otp_queue:RubyGems MFA prompts:1/4", ">"])
    expect(updates).not_to include(["secret:prompt_response:RubyGems MFA code", "."])
    expect(updates).to include(["remote:skip:cb", "."])
    expect(updates).to include(["ci:github_started:github:0/2", "."])
    expect(updates).to include(["ci:gitlab_pipeline:gitlab:pipeline", "."])
    expect(updates).to include(["pre:image_links", "."])
    expect(updates).to include(["changelog:plan:create_release", "."])
    expect(updates).to include(["lockfile:validate:before_push", "."])
    expect(updates).to include(["probe:availability:alpha-1.2.3:2/3", "."])
    expect(updates).to include(["remote_fetch", "!"])
    expect(updates).to include(["ok", "."])
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

  it "runs release members sequentially on TruffleRuby" do
    config = Kettle::Family::Config.load(root: @tmpdir)
    members = [ready_member("alpha"), ready_member("beta")]
    workflow = described_class.new(command: "release", config: config, members: members, execute: true, jobs: 2)

    allow(workflow).to receive(:truffleruby?).and_return(true)

    expect(workflow.send(:release_jobs, members)).to eq(1)
    expect(workflow.send(:parallel_release_members?, members)).to be(false)
  end

  it "honors configured release waves for sequential releases" do
    write_release_config(release_waves: [["beta"], ["alpha"]])
    config = Kettle::Family::Config.load(root: @tmpdir)
    alpha = ready_member("alpha")
    beta = ready_member("beta")
    workflow = described_class.new(command: "release", config: config, members: [alpha, beta], execute: true, jobs: 2)
    released = []

    allow(workflow).to receive(:release_results_for_member) do |member, runner:|
      released << member.name
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

    expect(released).to eq(%w[beta alpha])
    expect(wave_results.map(&:stdout)).to eq(["beta", "alpha"])
    expect(wave_results.map(&:reason)).to eq(["jobs=1 total=2", "jobs=1 total=2"])
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

  it "refreshes just-published family dependencies before releasing dependents" do
    write_release_config(release_env: fake_bundle_env)
    config = Kettle::Family::Config.load(root: @tmpdir)
    alpha = ready_member_with_gemspec("alpha", version: "1.2.3")
    beta = ready_member_with_gemspec("beta", dependencies: {"alpha" => ["~> 1.0", ">= 1.0.0"]})
    workflow = described_class.new(command: "release", config: config, members: [alpha, beta], execute: true, publish: true, commit: false, jobs: 1)

    allow(workflow).to receive(:prompt_for_gem_signing_password)
    allow(workflow).to receive(:released_version?).and_return(false)
    allow(workflow).to receive(:sleep)

    results = workflow.results

    expect(results.map(&:phase)).to eq(%w[
      check release_changelog release_publish dependency_floor dependency_floor_lockfiles dependency_floor_bundle_install
      check release_changelog release_publish
    ])
    expect(results.find { |result| result.phase == "release_wait_for_registry" }).to be_nil
    lockfile_refresh = results.find { |result| result.phase == "dependency_floor_lockfiles" }
    expect(lockfile_refresh).to be_ok
    expect(lockfile_refresh.stdout).to include("refreshed dependency floor lockfiles after 1 attempt(s)")
    expect(workflow).not_to have_received(:sleep)
  end

  it "excludes inactive conditional Gemfile dependencies from release lockfile refreshes" do
    write_release_config(release_env: {"KETTLE_DEV_DEV" => "false"})
    config = Kettle::Family::Config.load(root: @tmpdir)
    alpha = ready_member_with_gemspec("alpha", version: "1.2.3")
    optional = ready_member_with_gemspec("optional", version: "4.5.6")
    beta = ready_member_with_gemspec("beta", dependencies: {"alpha" => [">= 1.0.0"]})
    File.write(File.join(beta.root, "Gemfile"), <<~RUBY)
      source "https://gem.coop"
      gemspec
      gem "optional" unless ENV.fetch("KETTLE_DEV_DEV", "false") == "false"
    RUBY
    beta.release_dependencies = %w[alpha optional]
    workflow = described_class.new(command: "release", config: config, members: [alpha, optional, beta], execute: true, publish: true)

    expect(workflow.send(:active_release_dependencies_for, beta, [alpha, optional])).to eq([alpha])
  end

  it "does not probe inactive conditional Gemfile dependencies before a resumed publish" do
    write_release_config(release_env: {"KETTLE_DEV_DEV" => "false"})
    config = Kettle::Family::Config.load(root: @tmpdir)
    alpha = ready_member_with_gemspec("alpha", version: "1.2.3")
    optional = ready_member_with_gemspec("optional", version: "4.5.6")
    beta = ready_member_with_gemspec("beta", dependencies: {"alpha" => [">= 1.0.0"]})
    File.write(File.join(beta.root, "Gemfile"), <<~RUBY)
      source "https://gem.coop"
      gemspec
      gem "optional" unless ENV.fetch("KETTLE_DEV_DEV", "false") == "false"
    RUBY
    beta.release_dependencies = %w[alpha optional]
    workflow = described_class.new(
      command: "release",
      config: config,
      members: [beta],
      family_members: [alpha, optional, beta],
      execute: true,
      publish: true
    )

    allow(workflow).to receive(:released_version?).with("alpha", "1.2.3").and_return(true)
    expect(workflow).not_to receive(:released_version?).with("optional", "4.5.6")

    expect(workflow.send(:published_family_dependencies_for, [beta])).to eq([alpha])
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

    allow(workflow).to receive(:prompt_for_gem_signing_password)
    allow(workflow).to receive(:released_version?).and_return(false)
    allow(workflow).to receive(:sleep)

    results = workflow.results

    expect(results.map(&:phase)).to eq(%w[
      check release_changelog release_publish dependency_floor dependency_floor_lockfiles dependency_floor_bundle_install
      check release_changelog release_publish
    ])
    lockfile_refresh = results.find { |result| result.phase == "dependency_floor_lockfiles" }
    expect(lockfile_refresh).to be_ok
    expect(lockfile_refresh.command).to eq(%w[bundle lock --update alpha --add-checksums])
    expect(lockfile_refresh.member_name).to eq("beta")
    expect(lockfile_refresh.stdout).to include("bundle attempt 3: lock --update alpha --add-checksums")
    expect(lockfile_refresh.stdout).to include("refreshed dependency floor lockfiles after 3 attempt(s)")
    expect(workflow).to have_received(:sleep).with(15).twice
  end

  it "renders startup dependency-floor retry progress before release waves begin" do
    write_release_config
    config = Kettle::Family::Config.load(root: @tmpdir)
    alpha = ready_member_with_gemspec("alpha", version: "1.2.3")
    beta = ready_member_with_gemspec("beta", dependencies: {"alpha" => ["~> 1.0", ">= 1.0.0"]})
    progress = StringIO.new
    workflow = described_class.new(
      command: "release",
      config: config,
      members: [alpha, beta],
      execute: true,
      publish: true,
      commit: false,
      progress_io: progress
    )
    allow(workflow).to receive(:released_version?).with("alpha", "1.2.3").and_return(true)
    runner = lambda do |member:, phase:, command:, **_options|
      if phase == "dependency_floor_lockfiles"
        File.write(File.join(member.root, "Gemfile.lock"), <<~LOCK)
          GEM
            specs:
              alpha (1.2.3)

          CHECKSUMS
            alpha (1.2.3) sha256=abc123
        LOCK
      end
      Kettle::Family::CommandResult.new(member.name, phase, command, member.root, 0, true, "", "", 0.0, false, nil)
    end
    allow(workflow).to receive(:release_command_runner).and_return(runner)

    workflow.send(:release_dependency_floor_reconciliation_results, [beta])

    expect(progress.string).to include("reconciling dependency floors for 1 member with 1 job:")
    expect(progress.string).to include("dependency floors")
    expect(progress.string).to include("lockfiles 1/15")
  end

  it "validates direct CI appraisal gemfiles after just-published dependency floors" do
    write_release_config(
      release_env: fake_bundle_env(<<~BASH)
        if [[ "$BUNDLE_GEMFILE" == *"gemfiles/dep_heads.gemfile" && "$BUNDLE_LOCKFILE" == *"dependency-floor-ci-bundles"* ]]; then
          printf 'ci bundle gemfile: %s\\n' "$BUNDLE_GEMFILE"
          printf 'ci bundle lockfile: %s\\n' "$BUNDLE_LOCKFILE"
          if [ "$*" != "lock --update alpha --add-checksums" ]; then
            printf 'unexpected bundle command: %s\\n' "$*" >&2
            exit 1
          fi
        fi
      BASH
    )
    config = Kettle::Family::Config.load(root: @tmpdir)
    alpha = ready_member_with_gemspec("alpha", version: "1.2.3")
    beta = ready_member_with_gemspec("beta", dependencies: {"alpha" => ["~> 1.0", ">= 1.0.0"]})
    write_direct_bundle_workflow(beta, "gemfiles/dep_heads.gemfile")
    workflow = described_class.new(command: "release", config: config, members: [alpha, beta], execute: true, publish: true, commit: false, jobs: 1)

    allow(workflow).to receive(:prompt_for_gem_signing_password)
    allow(workflow).to receive(:released_version?).and_return(false)
    allow(workflow).to receive(:sleep)

    results = workflow.results

    expect(results.map(&:phase)).to eq(%w[
      check release_changelog release_publish dependency_floor dependency_floor_lockfiles dependency_floor_bundle_install dependency_floor_ci_bundle
      check release_changelog release_publish
    ])
    ci_bundle = results.find { |result| result.phase == "dependency_floor_ci_bundle" }
    expect(ci_bundle).to be_ok
    expect(ci_bundle.stdout).to include("ci bundle gemfile:")
    expect(ci_bundle.stdout).to include("gemfiles/dep_heads.gemfile")
    expect(ci_bundle.stdout).to include("validated CI bundle dep_heads.gemfile after 1 attempt(s)")
    expect(workflow).not_to have_received(:sleep)
  end

  it "validates CI job env BUNDLE_GEMFILE before releasing dependents" do
    write_release_config(
      release_env: fake_bundle_env(<<~BASH)
        if [[ "$BUNDLE_GEMFILE" == *"Appraisal.root.gemfile" && "$BUNDLE_LOCKFILE" == *"dependency-floor-ci-bundles"* ]]; then
          printf 'ci env bundle gemfile: %s\\n' "$BUNDLE_GEMFILE"
          if [ "$*" != "lock --update alpha --add-checksums" ]; then
            printf 'unexpected bundle command: %s\\n' "$*" >&2
            exit 1
          fi
        fi
      BASH
    )
    config = Kettle::Family::Config.load(root: @tmpdir)
    alpha = ready_member_with_gemspec("alpha", version: "1.2.3")
    beta = ready_member_with_gemspec("beta", dependencies: {"alpha" => ["~> 1.0", ">= 1.0.0"]})
    write_env_bundle_workflow(beta, "Appraisal.root.gemfile")
    workflow = described_class.new(command: "release", config: config, members: [alpha, beta], execute: true, publish: true, commit: false, jobs: 1)

    allow(workflow).to receive(:prompt_for_gem_signing_password)
    allow(workflow).to receive(:released_version?).and_return(false)
    allow(workflow).to receive(:sleep)

    results = workflow.results

    expect(results.map(&:phase)).to eq(%w[
      check release_changelog release_publish dependency_floor dependency_floor_lockfiles dependency_floor_bundle_install dependency_floor_ci_bundle
      check release_changelog release_publish
    ])
    ci_bundle = results.find { |result| result.phase == "dependency_floor_ci_bundle" }
    expect(ci_bundle).to be_ok
    expect(ci_bundle.stdout).to include("ci env bundle gemfile:")
    expect(ci_bundle.stdout).to include("Appraisal.root.gemfile")
    expect(ci_bundle.stdout).to include("validated CI bundle Appraisal.root.gemfile after 1 attempt(s)")
    expect(workflow).not_to have_received(:sleep)
  end

  it "excludes root-Gemfile-only family dependencies from an appraisal CI bundle refresh" do
    write_release_config
    config = Kettle::Family::Config.load(root: @tmpdir)
    alpha = ready_member_with_gemspec("alpha", version: "1.2.3")
    nomono = ready_member_with_gemspec("nomono", version: "1.2.3")
    beta = ready_member_with_gemspec("beta", dependencies: {"alpha" => ["~> 1.0", ">= 1.0.0"]})
    beta.release_dependencies = %w[alpha nomono]
    File.write(File.join(beta.root, "Gemfile"), <<~RUBY)
      source "https://gem.coop"
      gemspec
      gem "nomono"
    RUBY
    appraisal_gemfile = File.join(beta.root, "Appraisal.root.gemfile")
    File.write(appraisal_gemfile, "source \"https://gem.coop\"\ngemspec\n")
    workflow = described_class.new(command: "release", config: config, members: [alpha, nomono, beta], execute: true, publish: true)

    active_members = workflow.send(:active_release_dependencies_for_gemfile, beta, appraisal_gemfile, [alpha, nomono])

    expect(active_members).to eq([alpha])
  end

  it "stops before releasing a dependent when direct CI appraisal gemfiles cannot resolve just-published floors" do
    write_release_config(
      release_env: fake_bundle_env(<<~BASH)
        if [[ "$BUNDLE_GEMFILE" == *"gemfiles/dep_heads.gemfile" && "$BUNDLE_LOCKFILE" == *"dependency-floor-ci-bundles"* ]]; then
          printf 'missing alpha from CI bundle\\n' >&2
          exit 1
        fi
      BASH
    )
    config = Kettle::Family::Config.load(root: @tmpdir)
    alpha = ready_member_with_gemspec("alpha", version: "1.2.3")
    beta = ready_member_with_gemspec("beta", dependencies: {"alpha" => ["~> 1.0", ">= 1.0.0"]})
    write_direct_bundle_workflow(beta, "gemfiles/dep_heads.gemfile")
    workflow = described_class.new(command: "release", config: config, members: [alpha, beta], execute: true, publish: true, commit: false, jobs: 1)

    allow(workflow).to receive(:prompt_for_gem_signing_password)
    allow(workflow).to receive(:released_version?).and_return(false)
    allow(workflow).to receive(:sleep)

    results = workflow.results

    expect(results.map(&:phase)).to eq(%w[
      check release_changelog release_publish dependency_floor dependency_floor_lockfiles dependency_floor_bundle_install dependency_floor_ci_bundle
    ])
    ci_bundle = results.last
    expect(ci_bundle).not_to be_ok
    expect(ci_bundle.stderr).to include("missing alpha from CI bundle")
    expect(ci_bundle.reason).to eq("dependency floor CI bundle validation failed for dep_heads.gemfile after 15 attempt(s)")
    expect(workflow).to have_received(:sleep).with(15).exactly(14).times
  end

  it "waits and refreshes dependent lockfiles before committing dependency floors" do
    write_release_config
    config = Kettle::Family::Config.load(root: @tmpdir)
    alpha = ready_member_with_gemspec("alpha", version: "1.2.3")
    beta = ready_member_with_gemspec("beta", dependencies: {"alpha" => ["~> 1.0", ">= 1.0.0"]})
    workflow = described_class.new(command: "release", config: config, members: [alpha, beta], execute: true, publish: true, jobs: 1)
    phases = []
    runner = lambda do |member:, phase:, command:, **_options|
      phases << phase
      if phase == "dependency_floor_lockfiles"
        File.write(File.join(member.root, "Gemfile.lock"), <<~LOCK)
          GEM
            specs:
              alpha (1.2.3)

          CHECKSUMS
            alpha (1.2.3) sha256=abc123
        LOCK
      end
      Kettle::Family::CommandResult.new(
        member.name,
        phase,
        command,
        member.root,
        0,
        true,
        phase,
        "",
        0.0,
        false,
        nil
      )
    end

    memo = []
    workflow.send(:append_dependency_floor_results, released_members: [alpha], dependent_members: [beta], runner: runner, memo: memo)

    expect(memo.map(&:phase)).to eq(%w[
      dependency_floor dependency_floor_lockfiles dependency_floor_bundle_install commit_dependency_floor
    ])
    expect(phases).to eq(%w[dependency_floor_lockfiles dependency_floor_bundle_install commit_dependency_floor])
    expect(memo.last.command.join(" ")).to include("Gemfile.lock")
  end

  it "refreshes and commits dependent lockfiles when the dependency floor is already current" do
    write_release_config
    config = Kettle::Family::Config.load(root: @tmpdir)
    alpha = ready_member_with_gemspec("alpha", version: "1.2.3")
    beta = ready_member_with_gemspec("beta", dependencies: {"alpha" => ["~> 1.0", ">= 1.2.3"]})
    workflow = described_class.new(command: "release", config: config, members: [alpha, beta], execute: true, publish: true, jobs: 1)
    phases = []
    runner = lambda do |member:, phase:, command:, **_options|
      phases << phase
      if phase == "dependency_floor_lockfiles"
        File.write(File.join(member.root, "Gemfile.lock"), <<~LOCK)
          GEM
            specs:
              alpha (1.2.3)

          CHECKSUMS
            alpha (1.2.3) sha256=abc123
        LOCK
      end
      Kettle::Family::CommandResult.new(member.name, phase, command, member.root, 0, true, phase, "", 0.0, false, nil)
    end

    memo = []
    workflow.send(:append_dependency_floor_results, released_members: [alpha], dependent_members: [beta], runner: runner, memo: memo)

    expect(memo.map(&:phase)).to eq(%w[dependency_floor_lockfiles dependency_floor_bundle_install commit_dependency_floor])
    expect(phases).to eq(%w[dependency_floor_lockfiles dependency_floor_bundle_install commit_dependency_floor])
    expect(memo.find { |result| result.phase == "dependency_floor_bundle_install" }.command).to eq(%w[bundle install])
    expect(memo.last.command.join(" ")).to include("Gemfile.lock")
  end

  it "stops dependency reconciliation when installing a refreshed bundle fails" do
    write_release_config
    config = Kettle::Family::Config.load(root: @tmpdir)
    alpha = ready_member_with_gemspec("alpha", version: "1.2.3")
    beta = ready_member_with_gemspec("beta", dependencies: {"alpha" => ["~> 1.0", ">= 1.2.3"]})
    workflow = described_class.new(command: "release", config: config, members: [alpha, beta], execute: true, publish: true, jobs: 1)
    runner = lambda do |member:, phase:, command:, **_options|
      if phase == "dependency_floor_lockfiles"
        File.write(File.join(member.root, "Gemfile.lock"), <<~LOCK)
          GEM
            specs:
              alpha (1.2.3)

          CHECKSUMS
            alpha (1.2.3) sha256=abc123
        LOCK
      end
      failed = phase == "dependency_floor_bundle_install"
      Kettle::Family::CommandResult.new(member.name, phase, command, member.root, failed ? 1 : 0, !failed, "", failed ? "bundle install failed" : "", 0.0, false, failed ? "bundle install failed" : nil)
    end

    memo = []
    workflow.send(:append_dependency_floor_results, released_members: [alpha], dependent_members: [beta], runner: runner, memo: memo)

    expect(memo.map(&:phase)).to eq(%w[dependency_floor_lockfiles dependency_floor_bundle_install])
    expect(memo.last).not_to be_ok
    expect(memo.last.command).to eq(%w[bundle install])
  end

  it "reconciles published family dependencies before a resumed release" do
    write_release_config
    config = Kettle::Family::Config.load(root: @tmpdir)
    alpha = ready_member_with_gemspec("alpha", version: "1.2.3")
    beta = ready_member_with_gemspec("beta", dependencies: {"alpha" => ["~> 1.0", ">= 1.0.0"]})
    workflow = described_class.new(
      command: "release",
      config: config,
      members: [beta],
      family_members: [alpha, beta],
      execute: true,
      publish: true,
      commit: false,
      jobs: 1
    )
    allow(workflow).to receive(:released_version?).with("alpha", "1.2.3").and_return(true)
    runner = lambda do |member:, phase:, command:, **_options|
      if phase == "dependency_floor_lockfiles"
        File.write(File.join(member.root, "Gemfile.lock"), <<~LOCK)
          GEM
            specs:
              alpha (1.2.3)

          CHECKSUMS
            alpha (1.2.3) sha256=abc123
        LOCK
      end
      Kettle::Family::CommandResult.new(
        member.name,
        phase,
        command,
        member.root,
        0,
        true,
        phase,
        "",
        0.0,
        false,
        nil
      )
    end

    memo = []
    allow(workflow).to receive(:release_command_runner).and_return(runner)
    workflow.send(:release_dependency_floor_reconciliation_results, [beta]).each { |result| memo << result }

    expect(memo.map(&:phase)).to eq(%w[dependency_floor dependency_floor_lockfiles dependency_floor_bundle_install])
    expect(File.read(beta.gemspec_path)).to include('"alpha", "~> 1.0", ">= 1.2.3"')
  end

  it "defers dependent lockfile refreshes until all selected sibling dependencies are released" do
    write_release_config
    config = Kettle::Family::Config.load(root: @tmpdir)
    alpha = ready_member_with_gemspec("alpha", version: "1.2.3")
    beta = ready_member_with_gemspec(
      "beta",
      dependencies: {
        "alpha" => ["~> 1.0", ">= 1.0.0"],
        "gamma" => ["~> 1.0", ">= 1.0.0"]
      }
    )
    gamma = ready_member_with_gemspec("gamma", version: "1.2.3")
    workflow = described_class.new(
      command: "release",
      config: config,
      members: [alpha, beta, gamma],
      execute: true,
      publish: true,
      commit: false,
      jobs: 1
    )
    workflow.instance_variable_set(:@release_completed_member_names, ["alpha"])
    runner = ->(**_options) { raise "lockfile refresh should be deferred" }
    memo = []

    workflow.send(
      :append_dependency_floor_results,
      released_members: [alpha],
      dependent_members: [beta],
      runner: runner,
      memo: memo
    )

    expect(memo.map(&:phase)).to eq(["dependency_floor"])
  end

  it "uses a checksum-aware dependent lockfile refresh command" do
    write_release_config(
      release_env: fake_bundle_env(<<~BASH)
        if [ "$*" != "lock --update alpha --add-checksums" ]; then
          printf 'unexpected bundle command: %s\\n' "$*" >&2
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

    allow(workflow).to receive(:prompt_for_gem_signing_password)
    allow(workflow).to receive(:released_version?).and_return(false)
    allow(workflow).to receive(:sleep)

    results = workflow.results

    lockfile_refresh = results.find { |result| result.phase == "dependency_floor_lockfiles" }
    expect(lockfile_refresh).to be_ok
    expect(lockfile_refresh.command).to eq(%w[bundle lock --update alpha --add-checksums])
    expect(lockfile_refresh.stdout).to include("refreshed dependency floor lockfiles after 1 attempt(s)")
    expect(workflow).not_to have_received(:sleep)
  end

  it "rejects dependent lockfile refreshes that still resolve local path sources" do
    write_release_config(
      release_env: fake_bundle_env(<<~BASH)
        cat > Gemfile.lock <<'LOCK'
        PATH
          remote: /workspace/family/alpha
          specs:
            alpha (1.2.3)

        GEM
          specs:

        CHECKSUMS
          alpha (1.2.3) sha256=abc123
        LOCK
        exit 0
      BASH
    )
    config = Kettle::Family::Config.load(root: @tmpdir)
    alpha = ready_member_with_gemspec("alpha", version: "1.2.3")
    beta = ready_member_with_gemspec("beta", dependencies: {"alpha" => ["~> 1.0", ">= 1.0.0"]})
    workflow = described_class.new(command: "release", config: config, members: [alpha, beta], execute: true, publish: true, commit: false, jobs: 1)

    allow(workflow).to receive(:prompt_for_gem_signing_password)
    allow(workflow).to receive(:released_version?).and_return(false)
    allow(workflow).to receive(:sleep)

    results = workflow.results

    lockfile_refresh = results.find { |result| result.phase == "dependency_floor_lockfiles" }
    expect(lockfile_refresh).not_to be_ok
    expect(lockfile_refresh.stderr).to include("Gemfile.lock has local path remote at line 2")
  end

  it "repairs stale checksums before retrying dependent lockfile refreshes" do
    write_release_config(
      release_env: fake_bundle_env(<<~BASH)
        attempts_file="$BUNDLE_ATTEMPTS_FILE"
        attempts=0
        if [ -f "$attempts_file" ]; then
          attempts="$(cat "$attempts_file")"
        fi
        attempts="$((attempts + 1))"
        printf '%s' "$attempts" > "$attempts_file"
        if [ "$attempts" -eq 1 ]; then
          cat > Gemfile.lock <<'LOCK'
        GEM
          specs:
            alpha (1.2.3)

        CHECKSUMS
          alpha (1.2.3) sha256=stale
        LOCK
          printf '%s\n' 'Bundler found mismatched checksums. This is a potential security risk.' >&2
          printf '%s\n' 'sha256=stale from the lockfile CHECKSUMS at Gemfile.lock:6:23' >&2
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

    allow(workflow).to receive(:prompt_for_gem_signing_password)
    allow(workflow).to receive(:released_version?).and_return(false)
    allow(workflow).to receive(:sleep)

    results = workflow.results

    lockfile_refresh = results.find { |result| result.phase == "dependency_floor_lockfiles" }
    expect(lockfile_refresh).to be_ok
    expect(lockfile_refresh.stdout).to include("refreshed dependency floor lockfiles after 2 attempt(s)")
    expect(File.read(File.join(beta.root, "Gemfile.lock"))).to include("alpha (1.2.3) sha256=abc123")
    expect(workflow).not_to have_received(:sleep)
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

    allow(workflow).to receive(:prompt_for_gem_signing_password)
    allow(workflow).to receive(:released_version?).and_return(false)
    allow(workflow).to receive(:sleep)

    results = workflow.results

    expect(results.map(&:phase)).to eq(%w[
      check release_changelog release_publish dependency_floor dependency_floor_lockfiles dependency_floor_bundle_install
      check release_changelog release_publish
    ])
    lockfile_refresh = results.find { |result| result.phase == "dependency_floor_lockfiles" }
    expect(lockfile_refresh).to be_ok
    expect(lockfile_refresh.stdout).to include("bundle attempt 3: lock --update alpha --add-checksums")
    expect(lockfile_refresh.stdout).to include("refreshed dependency floor lockfiles after 3 attempt(s)")
    expect(workflow).to have_received(:sleep).with(15).twice
  end

  it "exhausts dependent bundle refresh retries before continuing release" do
    write_release_config(
      release_env: fake_bundle_env("exit 1"),
      template: {
        "normalize_lockfiles" => true,
        "normalize_lockfiles_command" => [RbConfig.ruby, "-e", "puts 'normalized'"]
      },
      release_normalize_lockfiles: false
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
      check release_changelog release_publish dependency_floor dependency_floor_lockfiles
    ])
    refresh = results.last
    expect(refresh.phase).to eq("dependency_floor_lockfiles")
    expect(refresh).not_to be_ok
    expect(refresh.reason).to eq("dependency floor lockfile refresh failed after 15 attempt(s)")
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

  it "records release worker exceptions as failed member results" do
    config = Kettle::Family::Config.load(root: @tmpdir)
    member = ready_member("alpha")
    workflow = described_class.new(command: "release", config: config, members: [member], execute: true, jobs: 1)

    allow(workflow).to receive(:release_results_for_member).and_raise(Kettle::Family::Error, "1Password RubyGems OTP lookup failed: dismissed")

    results = workflow.send(:run_release_wave, [member]).flatten

    expect(results.size).to eq(1)
    expect(results.first.member_name).to eq("alpha")
    expect(results.first.phase).to eq("release_build")
    expect(results.first).not_to be_ok
    expect(results.first.reason).to eq("1Password RubyGems OTP lookup failed: dismissed")
    expect(results.first.stderr).to include("Kettle::Family::Error")
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

  it "honors configured release waves before inferred waves" do
    config = Kettle::Family::Config.new(
      root: @tmpdir,
      path: nil,
      data: {"release" => {"waves" => [["beta"], ["alpha"]]}}
    )
    alpha = ready_member("alpha")
    beta = ready_member("beta")
    gamma = ready_member("gamma")
    workflow = described_class.new(command: "release", config: config, members: [alpha, beta, gamma], execute: true, jobs: 3)

    waves = workflow.send(:release_waves, [alpha, beta, gamma])

    expect(waves.map { |wave| wave.map(&:name) }).to eq([["beta"], ["alpha"], ["gamma"]])
  end

  it "filters configured release waves to the selected members" do
    config = Kettle::Family::Config.new(
      root: @tmpdir,
      path: nil,
      data: {"release" => {"waves" => [["alpha"], ["beta"], ["gamma"]]}}
    )
    beta = ready_member("beta")
    gamma = ready_member("gamma")
    workflow = described_class.new(command: "release", config: config, members: [beta, gamma], execute: true, jobs: 2)

    waves = workflow.send(:release_waves, [beta, gamma])

    expect(waves.map { |wave| wave.map(&:name) }).to eq([["beta"], ["gamma"]])
  end

  it "rejects configured waves that place a runtime dependency later" do
    config = Kettle::Family::Config.new(
      root: @tmpdir,
      path: nil,
      data: {"release" => {"waves" => [["beta"], ["alpha"]]}}
    )
    alpha = ready_member("alpha")
    beta = ready_member("beta", dependencies: ["alpha"])
    workflow = described_class.new(command: "release", config: config, members: [alpha, beta], execute: true, jobs: 2)

    expect { workflow.send(:release_waves, [alpha, beta]) }
      .to raise_error(
        Kettle::Family::Error,
        "configured release waves violate runtime dependency order: beta (wave 1) requires alpha (wave 2); move alpha to an earlier wave"
      )
  end

  it "rejects configured waves that place a runtime dependency in the same wave" do
    config = Kettle::Family::Config.new(
      root: @tmpdir,
      path: nil,
      data: {"release" => {"waves" => [["alpha", "beta"]]}}
    )
    alpha = ready_member("alpha")
    beta = ready_member("beta", dependencies: ["alpha"])
    workflow = described_class.new(command: "release", config: config, members: [alpha, beta], execute: true, jobs: 2)

    expect { workflow.send(:release_waves, [alpha, beta]) }
      .to raise_error(Kettle::Family::Error, /beta \(wave 1\) requires alpha \(wave 1\)/)
  end

  it "rejects unresolved release-only dependency cycles" do
    config = Kettle::Family::Config.load(root: @tmpdir)
    alpha = ready_member("alpha", release_dependencies: ["beta"])
    beta = ready_member("beta", release_dependencies: ["alpha"])
    workflow = described_class.new(command: "release", config: config, members: [alpha, beta], execute: true, jobs: 2)

    expect { workflow.send(:release_waves, [alpha, beta]) }
      .to raise_error(Kettle::Family::Error, /configure release\.waves to break the cycle/)
  end

  it "uses a configured release wave to break a release-only dependency cycle" do
    config = Kettle::Family::Config.new(
      root: @tmpdir,
      path: nil,
      data: {"release" => {"waves" => [["beta"]]}}
    )
    alpha = ready_member("alpha", release_dependencies: ["beta"])
    beta = ready_member("beta", release_dependencies: ["alpha"])
    workflow = described_class.new(command: "release", config: config, members: [alpha, beta], execute: true, jobs: 2)

    waves = workflow.send(:release_waves, [alpha, beta])

    expect(waves.map { |wave| wave.map(&:name) }).to eq([["beta"], ["alpha"]])
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

  def write_release_config(build_command: [RbConfig.ruby, "-e", "puts 'build'"], publish_command: [RbConfig.ruby, "-e", "puts 'publish'"], target_branches: nil, family_changelog: nil, check: nil, changelog: nil, release_env: nil, template: nil, secrets: nil, required_remotes: nil, release_normalize_lockfiles: nil, release_waves: nil)
    release = {
      "build_command" => build_command,
      "publish_command" => publish_command,
      "tag_command" => [RbConfig.ruby, "-e", "puts 'tag'"],
      "push_command" => [RbConfig.ruby, "-e", "puts 'push'"]
    }
    release["target_branches"] = target_branches if target_branches
    release["family_changelog"] = family_changelog if family_changelog
    release["env"] = release_env if release_env
    release["secrets"] = secrets if secrets
    release["required_remotes"] = required_remotes if required_remotes
    release["normalize_lockfiles"] = release_normalize_lockfiles unless release_normalize_lockfiles.nil?
    release["waves"] = release_waves if release_waves
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

  def stub_standalone_kettle_changelog(workflow)
    allow(workflow).to receive(:installed_gem_executable)
      .with("kettle-changelog", "kettle-changelog")
      .and_return(File.join(@tmpdir, "kettle-changelog", "exe", "kettle-changelog"))
  end

  def ready_member(name, changelog: true, dependencies: [], release_dependencies: nil, version_file: nil)
    root = File.join(@tmpdir, name)
    FileUtils.mkdir_p(File.join(root, "bin"))
    File.write(File.join(root, "Gemfile"), "source \"https://gem.coop\"\n")
    %w[Rakefile README.md LICENSE.md].each { |path| File.write(File.join(root, path), "stub\n") }
    File.write(File.join(root, "CHANGELOG.md"), "## [Unreleased]\n") if changelog
    %w[bin/rake bin/rspec].each do |path|
      full_path = File.join(root, path)
      File.write(full_path, "#!/bin/sh\n")
      FileUtils.chmod("u+x", full_path)
    end
    if version_file
      FileUtils.mkdir_p(File.dirname(version_file))
      File.write(version_file, "module #{name.split(/[-_]/).map(&:capitalize).join}; VERSION = \"1.0.0\"; end\n")
    end
    Kettle::Family::Member.new(name: name, root: root, gemspec_path: nil, version_file: version_file, version: "1.0.0", dependencies: dependencies, release_dependencies: release_dependencies || dependencies)
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
    File.write(File.join(member.root, "Gemfile"), "source \"https://gem.coop\"\ngemspec\n")
    Kettle::Family::Member.new(name: name, root: member.root, gemspec_path: gemspec, version_file: nil, version: version, dependencies: dependencies.keys)
  end

  def write_direct_bundle_workflow(member, bundle_gemfile)
    workflow_path = File.join(member.root, ".github", "workflows", "dep-heads.yml")
    gemfile_path = File.join(member.root, bundle_gemfile)
    FileUtils.mkdir_p(File.dirname(workflow_path))
    FileUtils.mkdir_p(File.dirname(gemfile_path))
    File.write(gemfile_path, <<~RUBY)
      source "https://gem.coop"
      gemspec path: "../"
    RUBY
    File.write(workflow_path, <<~YAML)
      name: Runtime Deps @ HEAD
      jobs:
        ruby:
          strategy:
            matrix:
              include:
                - ruby: "ruby"
                  appraisal: "dep-heads"
                  bundle_gemfile: #{bundle_gemfile.inspect}
                  direct_bundle: true
    YAML
  end

  def write_env_bundle_workflow(member, bundle_gemfile)
    workflow_path = File.join(member.root, ".github", "workflows", "truffleruby-24.2.yml")
    gemfile_path = File.join(member.root, bundle_gemfile)
    FileUtils.mkdir_p(File.dirname(workflow_path))
    File.write(gemfile_path, <<~RUBY)
      source "https://gem.coop"
      gemspec
    RUBY
    File.write(workflow_path, <<~YAML)
      name: TruffleRuby 24.2
      jobs:
        test:
          env:
            BUNDLE_GEMFILE: ${{ github.workspace }}/#{bundle_gemfile}
          steps:
            - uses: appraisal-rb/setup-ruby-flash@b22cb587431e9611d9e0a624a43872e2bbfbcd66
              with:
                bundler-cache: true
    YAML
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
