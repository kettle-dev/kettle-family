# frozen_string_literal: true

require "fileutils"
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
