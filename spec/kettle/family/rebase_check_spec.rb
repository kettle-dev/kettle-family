# frozen_string_literal: true

require "fileutils"
require "tmpdir"

RSpec.describe Kettle::Family::RebaseCheck, :real_rebase_check do
  around do |example|
    Dir.mktmpdir("kettle-family-rebase-check-spec") do |dir|
      @tmpdir = dir
      example.run
    end
  end

  before do
    hide_env("KETTLE_REBASE_NESTED")
    write_config
  end

  describe ".gated?" do
    it "gates bundle- and history-mutating commands" do
      %w[bump bup template gha-sha-pins].each do |command|
        expect(described_class.gated?(command)).to be(true), "expected #{command} to be gated"
      end
    end

    it "never gates release (own lane sync), sync commands (they ARE the sync), the bundler remedy, or read-only commands" do
      %w[release bupb update-bundler sync pull up push check test lint docs bex install].each do |command|
        expect(described_class.gated?(command)).to be(false), "expected #{command} to be ungated"
      end
    end
  end

  describe ".nested?" do
    it "is false when the marker is unset" do
      expect(described_class.nested?({})).to be(false)
    end

    it "is false for falsey marker values" do
      %w[false 0 no off FALSE].each do |value|
        expect(described_class.nested?("KETTLE_REBASE_NESTED" => value)).to be(false), "expected #{value} to be non-nested"
      end
    end

    it "is true for truthy marker values" do
      %w[true 1 yes on].each do |value|
        expect(described_class.nested?("KETTLE_REBASE_NESTED" => value)).to be(true), "expected #{value} to be nested"
      end
    end
  end

  describe ".call" do
    it "returns no results when nested inside an outer kettle command" do
      stub_env("KETTLE_REBASE_NESTED" => "true")
      alpha = member("alpha", root: repo_with_origin("alpha"))

      results = described_class.call(config: config, members: [alpha])

      expect(results).to be_empty
    end

    it "returns an ok result per member when every checkout is up to date" do
      alpha = member("alpha", root: repo_with_origin("alpha"))
      beta = member("beta", root: repo_with_origin("beta"))

      results = described_class.call(config: config, members: [alpha, beta])

      expect(results.map(&:member_name)).to eq(%w[alpha beta])
      expect(results).to all(be_ok)
      expect(results.map(&:phase)).to eq(%w[rebase_check rebase_check])
    end

    it "rebases a member that is behind its upstream" do
      root = repo_with_origin("alpha")
      advance_origin("alpha")
      alpha = member("alpha", root: root)

      results = described_class.call(config: config, members: [alpha])

      expect(results).to all(be_ok)
      expect(results.first.stdout).to include("rebased")
    end

    it "fails only the member whose rebase conflicts, with the conflicted paths in diagnostics" do
      conflicted = repo_with_origin("alpha")
      File.write(File.join(conflicted, "f.txt"), "local\n")
      git(conflicted, "add", ".")
      git(conflicted, "commit", "-qm", "local change to f")
      advance_origin("alpha", filename: "f.txt", content: "upstream\n")
      alpha = member("alpha", root: conflicted)
      beta = member("beta", root: repo_with_origin("beta"))

      results = described_class.call(config: config, members: [alpha, beta])

      failed, ok = results.partition { |result| !result.ok? }
      expect(failed.map(&:member_name)).to eq(["alpha"])
      expect(failed.first.phase).to eq("rebase_check")
      expect(failed.first.diagnostics).to match([hash_including("type" => "rebase_conflict", "member" => "alpha", "conflicts" => ["f.txt"])])
      expect(ok.map(&:member_name)).to eq(["beta"])
      # The conflicting member's checkout was restored, not left mid-rebase
      expect(File.directory?(File.join(conflicted, ".git", "rebase-merge"))).to be(false)
    end

    it "marks a member without an upstream as skipped-but-ok (fail-open)" do
      root = repo_with_origin("alpha")
      git(root, "switch", "-c", "local-only")
      alpha = member("alpha", root: root)

      results = described_class.call(config: config, members: [alpha])

      expect(results.first).to be_ok
      expect(results.first.skipped).to be(true)
    end

    it "fails open when the upstream cannot be fetched" do
      root = repo_with_origin("alpha")
      FileUtils.rm_rf(File.join(@tmpdir, "alpha-origin.git"))
      alpha = member("alpha", root: root)

      results = described_class.call(config: config, members: [alpha])

      expect(results.first).to be_ok
      expect(results.first.skipped).to be(true)
      expect(results.first.stdout).to include("proceeding")
    end

    it "syncs a shared git root once for monorepo members" do
      root = repo_with_origin("mono")
      alpha = member("alpha", root: root)
      beta = member("beta", root: root)
      calls = []
      allow(Kettle::Dev::Rebase).to receive(:call) do |root:|
        calls << root
        Kettle::Dev::Rebase::Result.new(status: :ok, message: "up to date")
      end

      results = described_class.call(config: config, members: [alpha, beta])

      expect(calls).to eq([root])
      expect(results.map(&:member_name)).to eq(%w[alpha beta])
      expect(results).to all(be_ok)
    end

    it "emits member_start, command_step, and member_complete events per member on the event tape" do
      alpha = member("alpha", root: repo_with_origin("alpha"))
      events = []
      tape = ->(event) { events << event }

      described_class.call(config: config, members: [alpha], event_tape: tape)

      types = events.map { |event| event["type"] }
      expect(types).to eq(%w[member_start command_step command_step member_complete])
      expect(events).to all(include("command" => "rebase_check", "member" => "alpha"))
      step = events.select { |event| event["type"] == "command_step" }
      expect(step.map { |event| event["status"] }).to eq(%w[started ok])
      expect(step).to all(include("phase" => "rebase_check"))
    end

    it "emits failure events for a member whose rebase fails" do
      conflicted = repo_with_origin("alpha")
      File.write(File.join(conflicted, "f.txt"), "local\n")
      git(conflicted, "add", ".")
      git(conflicted, "commit", "-qm", "local change to f")
      advance_origin("alpha", filename: "f.txt", content: "upstream\n")
      alpha = member("alpha", root: conflicted)
      events = []

      described_class.call(config: config, members: [alpha], event_tape: ->(event) { events << event })

      expect(events.last).to include("type" => "member_complete", "member" => "alpha", "status" => "failed")
    end

    it "emits no tape events when nested (the check is skipped entirely)" do
      stub_env("KETTLE_REBASE_NESTED" => "true")
      alpha = member("alpha", root: repo_with_origin("alpha"))
      events = []

      described_class.call(config: config, members: [alpha], event_tape: ->(event) { events << event })

      expect(events).to be_empty
    end
  end

  def write_config
    File.write(File.join(@tmpdir, ".kettle-family.yml"), "family:\n  name: rebase-spec\n")
  end

  def config
    Kettle::Family::Config.load(root: @tmpdir)
  end

  def member(name, root:)
    Kettle::Family::Member.new(name: name, root: root, gemspec_path: nil, version_file: nil, version: "1.0.0", dependencies: [])
  end

  def git(root, *args)
    system("git", "-C", root, *args, out: File::NULL, err: File::NULL) || raise("git #{args.first} failed for #{root}")
  end

  # A member clone of a fresh bare origin, on main, with one commit pushed
  # and upstream tracking set.
  def repo_with_origin(name)
    origin = File.join(@tmpdir, "#{name}-origin.git")
    system("git", "init", "-q", "--bare", "--initial-branch=main", origin, out: File::NULL, err: File::NULL) || raise("bare init failed")
    root = File.join(@tmpdir, name)
    system("git", "clone", "-q", origin, root, out: File::NULL, err: File::NULL) || raise("clone failed")
    git(root, "config", "user.email", "spec@example.test")
    git(root, "config", "user.name", "Spec")
    File.write(File.join(root, "f.txt"), "v1\n")
    git(root, "add", ".")
    git(root, "commit", "-qm", "v1")
    git(root, "push", "-qu", "origin", "main")
    root
  end

  # Advance the member's origin by one commit (via a second clone).
  def advance_origin(name, filename: "f.txt", content: "v2\n")
    work = File.join(@tmpdir, "#{name}-upstream")
    system("git", "clone", "-q", File.join(@tmpdir, "#{name}-origin.git"), work, out: File::NULL, err: File::NULL) || raise("clone failed")
    git(work, "config", "user.email", "spec@example.test")
    git(work, "config", "user.name", "Spec")
    File.write(File.join(work, filename), content)
    git(work, "add", ".")
    git(work, "commit", "-qm", "upstream change")
    git(work, "push", "-q", "origin", "main")
  end
end
