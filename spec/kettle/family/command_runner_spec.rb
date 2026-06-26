# frozen_string_literal: true

require "fileutils"
require "stringio"
require "tmpdir"

RSpec.describe Kettle::Family::CommandRunner do
  around do |example|
    Dir.mktmpdir("kettle-family-runner-spec") do |dir|
      @tmpdir = dir
      example.run
    end
  end

  it "returns skipped dry-run results" do
    member = member_at("alpha")

    result = described_class.new.call(member: member, phase: "test", command: "echo alpha")

    expect(result).to be_ok
    expect(result.skipped).to be(true)
    expect(result.command).to eq(["sh", "-lc", "echo alpha"])
    expect(result.reason).to include("--execute")
  end

  it "wraps commands with mise when a member has mise.toml" do
    member = member_at("alpha")
    File.write(File.join(member.root, "mise.toml"), "[env]\n")

    result = described_class.new.call(member: member, phase: "test", command: ["ruby", "-v"])

    expect(result.command).to start_with("mise", "exec", "-C", member.root, "--")
  end

  it "injects workflow env after mise so member config cannot override it" do
    member = member_at("alpha")
    File.write(File.join(member.root, "mise.toml"), "[env]\nK_JEM_TEMPLATING = \"false\"\n")

    result = described_class.new.call(
      member: member,
      phase: "template",
      command: ["bundle", "exec", "kettle-jem", "install"],
      env: {"K_JEM_TEMPLATING" => "true"}
    )

    expect(result.command).to eq(
      [
        "mise",
        "exec",
        "-C",
        member.root,
        "--",
        "env",
        "K_JEM_TEMPLATING=true",
        "bundle",
        "exec",
        "kettle-jem",
        "install"
      ]
    )
  end

  it "wraps commands with mise when a member has .tool-versions" do
    member = member_at("alpha")
    File.write(File.join(member.root, ".tool-versions"), "ruby 4.0.5\n")

    result = described_class.new.call(
      member: member,
      phase: "template",
      command: ["kettle-jem", "install"],
      env: {"K_JEM_TEMPLATING" => "true"}
    )

    expect(result.command).to eq(
      [
        "mise",
        "exec",
        "-C",
        member.root,
        "--",
        "env",
        "K_JEM_TEMPLATING=true",
        "kettle-jem",
        "install"
      ]
    )
  end

  it "executes commands when requested" do
    member = member_at("alpha")

    result = described_class.new(execute: true).call(
      member: member,
      phase: "test",
      command: [RbConfig.ruby, "-e", "puts 'ran'"]
    )

    expect(result).to be_ok
    expect(result.skipped).to be(false)
    expect(result.stdout).to eq("ran\n")
    expect(result.status).to eq(0)
  end

  it "executes child commands with the parent Bundler environment removed" do
    member = member_at("alpha")

    result = described_class.new(execute: true).call(
      member: member,
      phase: "test",
      command: [
        RbConfig.ruby,
        "-e",
        "puts [ENV['BUNDLE_GEMFILE'], ENV['RUBYOPT'].to_s.include?('bundler/setup')].inspect"
      ],
      env: {"BUNDLE_GEMFILE" => File.join(member.root, "Gemfile")}
    )

    expect(result).to be_ok
    expect(result.stdout).to eq("[\"#{File.join(member.root, "Gemfile")}\", false]\n")
  end

  it "captures failing commands" do
    member = member_at("alpha")

    result = described_class.new(execute: true).call(
      member: member,
      phase: "test",
      command: [RbConfig.ruby, "-e", "warn 'nope'; exit 7"]
    )

    expect(result).not_to be_ok
    expect(result.status).to eq(7)
    expect(result.stderr).to eq("nope\n")
    expect(result.reason).to eq("command failed")
  end

  it "falls back to Open3 for interactive commands when PTY is unavailable" do
    member = member_at("alpha")
    runner = described_class.new(execute: true, gem_signing_password: "secret")
    allow(runner).to receive(:pty_available?).and_return(false)
    allow($stdin).to receive(:tty?).and_return(false)

    result = runner.call(
      member: member,
      phase: "release_publish",
      command: [RbConfig.ruby, "-e", "warn 'interactive'; puts 'fallback'"]
    )

    expect(result).to be_ok
    expect(result.stdout).to eq("fallback\n")
    expect(result.stderr).to eq("interactive\n")
  end

  it "uses PTY for interactive commands when available" do
    member = member_at("alpha")
    runner = described_class.new(execute: true)
    skip "PTY is unavailable on this Ruby engine" unless runner.send(:pty_available?)

    result = runner.call(
      member: member,
      phase: "release_publish",
      command: [RbConfig.ruby, "-e", "puts 'pty'"],
      interactive: true
    )

    expect(result).to be_ok
    expect(result.stdout).to include("pty")
    expect(result.stderr).to eq("")
  end

  it "reports PTY availability from the runtime" do
    runner = described_class.new

    expect(runner.send(:pty_available?)).to be(true).or be(false)
  end

  it "reports missing PTY support" do
    runner = described_class.new
    allow(runner).to receive(:require).with("pty").and_raise(LoadError)

    expect(runner.send(:pty_available?)).to be(false)
  end

  it "writes cached signing passwords when an interactive prompt is detected" do
    runner = described_class.new(gem_signing_password: "secret")
    input = StringIO.new

    runner.send(:write_signing_password, input, "Enter PEM pass phrase: ")

    expect(input.string).to eq("secret\n")
  end

  it "does not write cached signing passwords for informational PEM text" do
    runner = described_class.new(gem_signing_password: "secret")
    input = StringIO.new

    runner.send(:handle_interactive_prompt, input, "TIP: set SKIP_GEM_SIGNING=true to avoid PEM password prompts.\n")

    expect(input.string).to eq("")
  end

  it "does not write cached signing passwords for RubyGems MFA prompts" do
    runner = described_class.new(gem_signing_password: "secret")
    input = StringIO.new

    runner.send(:handle_interactive_prompt, input, "You have enabled multi-factor authentication. Please enter OTP code.\nCode: ")

    expect(input.string).to eq("")
  end

  it "writes shared OTP responses through the coordinator for MFA prompts" do
    otp_input = StringIO.new("123456\n")
    otp_output = StringIO.new
    coordinator = described_class::OtpCoordinator.new(input: otp_input, output: otp_output)
    runner = described_class.new(gem_signing_password: "secret", otp_coordinator: coordinator)
    child_input = StringIO.new

    runner.send(:handle_interactive_prompt, child_input, "You have enabled multi-factor authentication.\nCode: ", member_name: "alpha")

    expect(child_input.string).to eq("123456\n")
    expect(otp_output.string).to include("[alpha] RubyGems MFA requested.")
  end

  it "reuses one queued OTP response for concurrent requests" do
    otp_input = StringIO.new("654321\n")
    otp_output = StringIO.new
    coordinator = described_class::OtpCoordinator.new(input: otp_input, output: otp_output)
    responses = Queue.new

    threads = %w[alpha beta].map do |member_name|
      Thread.new do
        responses << coordinator.request(member_name: member_name, chunk: "Code: ")
      end
    end
    threads.each(&:join)

    expect(2.times.map { responses.pop }).to eq(%w[654321 654321])
    expect(otp_output.string.scan("RubyGems MFA requested").size).to eq(1)
  end

  it "accepts confirmation prompts before signing password prompts" do
    runner = described_class.new(gem_signing_password: "secret")
    input = StringIO.new

    runner.send(:handle_interactive_prompt, input, "Proceed with signing enabled? This may hang waiting for a PEM password. [y/N]: ")

    expect(input.string).to eq("y\n")
  end

  it "waits for user input at confirmation prompts when accept is disabled" do
    runner = described_class.new(accept: false, gem_signing_password: "secret")
    input = StringIO.new

    runner.send(:handle_interactive_prompt, input, "Proceed with signing enabled? This may hang waiting for a PEM password. [y/N]: ")

    expect(input.string).to eq("")
  end

  it "normalizes binary command output to UTF-8" do
    runner = described_class.new
    binary = "ok \xFF".b

    normalized = runner.send(:normalize_output, binary)

    expect(normalized.encoding).to eq(Encoding::UTF_8)
    expect(normalized).to eq("ok ")
  end

  it "rejects unsupported command shapes" do
    member = member_at("alpha")

    expect { described_class.new.call(member: member, phase: "test", command: Object.new) }
      .to raise_error(Kettle::Family::Error, /command must be/)
  end

  def member_at(name)
    root = File.join(@tmpdir, name)
    FileUtils.mkdir_p(root)
    Kettle::Family::Member.new(name: name, root: root, gemspec_path: File.join(root, "#{name}.gemspec"), version: "1.0.0", dependencies: [])
  end
end
