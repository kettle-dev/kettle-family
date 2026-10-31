# frozen_string_literal: true

require "fileutils"
require "shellwords"
require "tmpdir"
require "yaml"

RSpec.describe Kettle::Family::Workflow do
  around do |example|
    Dir.mktmpdir("kettle-family-resume-scrub-spec") do |dir|
      @tmpdir = dir
      example.run
    end
  end

  before do
    Kettle::Family.mise_adapter = build_mise_adapter(executable: "mise")
  end

  # The env shape aggregate_github_release_resume_command received in the
  # 2026-10-30 incident: broker-cached signing passphrase embedded verbatim
  # in the printed resume command.
  def incident_env
    {
      "K_CHANGELOG_GEM_NAME" => "structuredmerge-ruby",
      "KETTLE_RELEASE_SECRETS_PROVIDER" => "family",
      "KETTLE_RELEASE_GEM_SIGNING_PASSPHRASE_SOURCE" => "cached",
      "KETTLE_RELEASE_GEM_SIGNING_PASSPHRASE" => "super-secret-passphrase"
    }
  end

  def member_at(name, version: "7.1.6")
    root = File.join(@tmpdir, name)
    FileUtils.mkdir_p(root)
    Kettle::Family::Member.new(
      name: name,
      root: root,
      gemspec_path: File.join(root, "#{name}.gemspec"),
      version: version,
      dependencies: []
    )
  end

  def workflow_for(members:, execute: true)
    File.write(
      File.join(@tmpdir, ".kettle-family.yml"),
      YAML.dump(
        "family" => {"name" => "example", "mode" => "monorepo", "members_root" => "gems"},
        "release" => {"build_command" => [RbConfig.ruby, "-e", "puts 'build'"]},
        "changelog" => {"mode" => "root", "path" => "CHANGELOG.md", "version_file" => "alpha/lib/alpha/version.rb"}
      )
    )
    config = Kettle::Family::Config.load(root: @tmpdir)
    described_class.new(command: "release", config: config, members: members, family_members: members, execute: execute, publish: true)
  end

  def redacted_placeholder
    # The placeholder is shell-escaped into the command so a pasted resume
    # line parses as a literal value rather than redirection tokens.
    Shellwords.escape(described_class::RESUME_COMMAND_REDACTED_VALUE)
  end

  it "redacts the gem signing passphrase from the resume command" do
    workflow = workflow_for(members: [member_at("alpha")], execute: false)

    resume_command = workflow.send(:aggregate_github_release_resume_command, incident_env, %w[bundle exec kettle-gh-release])

    expect(resume_command).not_to include("super-secret-passphrase")
    expect(resume_command).to include("KETTLE_RELEASE_GEM_SIGNING_PASSPHRASE=")
    expect(resume_command).to include(redacted_placeholder)
  end

  it "keeps non-secret env values and the command itself intact" do
    workflow = workflow_for(members: [member_at("alpha")], execute: false)

    resume_command = workflow.send(:aggregate_github_release_resume_command, incident_env, %w[bundle exec kettle-gh-release --release-version 7.1.6])

    expect(resume_command).to include("K_CHANGELOG_GEM_NAME=structuredmerge-ruby")
    expect(resume_command).to include("KETTLE_RELEASE_GEM_SIGNING_PASSPHRASE_SOURCE=cached")
    expect(resume_command).to include("KETTLE_RELEASE_SECRETS_PROVIDER=family")
    expect(resume_command).to end_with("bundle exec kettle-gh-release --release-version 7.1.6")
  end

  it "redacts any secret-shaped env key, not only the known passphrase" do
    workflow = workflow_for(members: [member_at("alpha")], execute: false)
    env = {
      "SAFE_FLAG" => "true",
      "KETTLE_RELEASE_1PASSWORD_RUBYGEMS_OTP_REFERENCE" => "op://vault/otp",
      "SOME_TOKEN" => "tok_123"
    }

    resume_command = workflow.send(:aggregate_github_release_resume_command, env, %w[true])

    expect(resume_command).not_to include("op://vault/otp")
    expect(resume_command).not_to include("tok_123")
    expect(resume_command).to include("SAFE_FLAG=true")
    expect(resume_command.scan(redacted_placeholder).length).to eq(2)
  end

  it "produces a placeholder the shell parses as a literal value" do
    workflow = workflow_for(members: [member_at("alpha")], execute: false)

    resume_command = workflow.send(:aggregate_github_release_resume_command, incident_env, %w[true])
    assignments = resume_command.shellsplit.grep(/\AKETTLE_RELEASE_GEM_SIGNING_PASSPHRASE=/)

    expect(assignments).to eq(["KETTLE_RELEASE_GEM_SIGNING_PASSPHRASE=#{described_class::RESUME_COMMAND_REDACTED_VALUE}"])
  end

  # The regression this guards: a failed aggregate GitHub release printed a
  # resume command built from the broker-cached env, embedding the signing
  # passphrase in plaintext terminal output and transcripts.
  it "scrubs the passphrase from the resume command of a failed aggregate release" do
    alpha = member_at("alpha")
    beta = member_at("beta")
    workflow = workflow_for(members: [alpha, beta])
    failing_runner = Class.new do
      def call(**kwargs)
        member = kwargs[:member]
        Kettle::Family::CommandResult.new(
          member_name: member.name,
          phase: kwargs[:phase],
          command: kwargs[:command],
          workdir: member.root,
          status: 1,
          success: false,
          stdout: "",
          stderr: "aggregate release failed",
          elapsed_seconds: 0.0,
          skipped: false,
          reason: "command failed"
        )
      end
    end.new
    allow(workflow).to receive_messages(release_env: incident_env, command_runner: failing_runner)

    result = workflow.send(:aggregate_monorepo_github_release, [alpha, beta])

    expect(result).not_to be_ok
    expect(result.resume_command).not_to be_nil
    expect(result.resume_command).not_to include("super-secret-passphrase")
    expect(result.resume_command).to include(redacted_placeholder)
  end
end
