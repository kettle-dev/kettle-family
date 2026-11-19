# frozen_string_literal: true

require "fileutils"
require "tmpdir"

RSpec.describe Kettle::Family::RebaseCheck, :real_rebase_check do
  # The .call examples stub the Kettle::Dev::Rebase seam (stub_const works
  # whether or not the bundled kettle-dev ships the module), so this spec
  # runs against ANY released kettle-dev — CI resolves the released floor,
  # which predates Rebase. The real-git rebase contract (conflict abort and
  # autostash restore, ahead/behind handling, ...) is covered by kettle-dev's
  # own rebase_spec; one smoke test at the bottom exercises the real module
  # when the local bundle ships it.

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
      alpha = member("alpha", root: member_root("alpha"))

      results = described_class.call(config: config, members: [alpha])

      expect(results).to be_empty
    end

    it "returns an ok result per member when every checkout is up to date" do
      alpha = member("alpha", root: member_root("alpha"))
      beta = member("beta", root: member_root("beta"))
      stub_rebase(
        alpha.root => sync(:ok, "main is up to date with origin/main"),
        beta.root => sync(:ok, "main is up to date with origin/main")
      )

      results = described_class.call(config: config, members: [alpha, beta])

      expect(results.map(&:member_name)).to eq(%w[alpha beta])
      expect(results).to all(be_ok)
      expect(results.map(&:phase)).to eq(%w[rebase_check rebase_check])
    end

    it "reports a member that was rebased onto its upstream" do
      alpha = member("alpha", root: member_root("alpha"))
      stub_rebase(alpha.root => sync(:updated, "rebased main onto origin/main (was behind by 1)"))

      results = described_class.call(config: config, members: [alpha])

      expect(results).to all(be_ok)
      expect(results.first.stdout).to include("rebased")
    end

    it "fails only the member whose rebase conflicts, with the conflicted paths in diagnostics" do
      alpha = member("alpha", root: member_root("alpha"))
      beta = member("beta", root: member_root("beta"))
      stub_rebase(
        alpha.root => sync(:conflict, "rebase of main onto origin/main failed (conflicts: f.txt); the checkout was restored to its pre-rebase state", ["f.txt"]),
        beta.root => sync(:ok, "main is up to date with origin/main")
      )

      results = described_class.call(config: config, members: [alpha, beta])

      failed, ok = results.partition { |result| !result.ok? }
      expect(failed.map(&:member_name)).to eq(["alpha"])
      expect(failed.first.phase).to eq("rebase_check")
      expect(failed.first.reason).to eq("checkout not synced to upstream")
      expect(failed.first.diagnostics).to match([hash_including("type" => "rebase_conflict", "member" => "alpha", "conflicts" => ["f.txt"])])
      expect(ok.map(&:member_name)).to eq(["beta"])
    end

    it "marks a member without an upstream as skipped-but-ok (fail-open)" do
      alpha = member("alpha", root: member_root("alpha"))
      stub_rebase(alpha.root => sync(:skipped_no_upstream, "main has no upstream; nothing to sync"))

      results = described_class.call(config: config, members: [alpha])

      expect(results.first).to be_ok
      expect(results.first.skipped).to be(true)
    end

    it "fails open when the upstream cannot be fetched" do
      alpha = member("alpha", root: member_root("alpha"))
      stub_rebase(alpha.root => sync(:skipped_unreachable, "could not fetch origin/main; proceeding with local main"))

      results = described_class.call(config: config, members: [alpha])

      expect(results.first).to be_ok
      expect(results.first.skipped).to be(true)
      expect(results.first.stdout).to include("proceeding")
    end

    it "fails the member on a rebase error with a rebase_error diagnostic" do
      alpha = member("alpha", root: member_root("alpha"))
      stub_rebase(alpha.root => sync(:error, "not a git repository: #{alpha.root}"))

      results = described_class.call(config: config, members: [alpha])

      expect(results.first).not_to be_ok
      expect(results.first.diagnostics).to match([hash_including("type" => "rebase_error", "member" => "alpha")])
    end

    it "syncs a shared git root once for monorepo members" do
      root = member_root("mono")
      alpha = member("alpha", root: root)
      beta = member("beta", root: root)
      calls = stub_rebase(root => sync(:ok, "up to date"))

      results = described_class.call(config: config, members: [alpha, beta])

      expect(calls).to eq([root])
      expect(results.map(&:member_name)).to eq(%w[alpha beta])
      expect(results).to all(be_ok)
    end

    it "emits member_start, command_step, and member_complete events per member on the event tape" do
      alpha = member("alpha", root: member_root("alpha"))
      stub_rebase(alpha.root => sync(:ok, "up to date"))
      events = []

      described_class.call(config: config, members: [alpha], event_tape: ->(event) { events << event })

      types = events.map { |event| event["type"] }
      expect(types).to eq(%w[member_start command_step command_step member_complete])
      expect(events).to all(include("command" => "rebase_check", "member" => "alpha"))
      step = events.select { |event| event["type"] == "command_step" }
      expect(step.map { |event| event["status"] }).to eq(%w[started ok])
      expect(step).to all(include("phase" => "rebase_check"))
    end

    it "emits failure events for a member whose rebase fails" do
      alpha = member("alpha", root: member_root("alpha"))
      stub_rebase(alpha.root => sync(:conflict, "rebase failed", ["f.txt"]))
      events = []

      described_class.call(config: config, members: [alpha], event_tape: ->(event) { events << event })

      expect(events.last).to include("type" => "member_complete", "member" => "alpha", "status" => "failed")
    end

    it "emits no tape events when nested (the check is skipped entirely)" do
      stub_env("KETTLE_REBASE_NESTED" => "true")
      alpha = member("alpha", root: member_root("alpha"))
      events = []

      described_class.call(config: config, members: [alpha], event_tape: ->(event) { events << event })

      expect(events).to be_empty
    end

    context "when the bundled kettle-dev predates the Rebase module" do
      before { hide_const("Kettle::Dev::Rebase") }

      it "falls back to the kettle-rebase executable" do
        root = member_root("alpha")
        allow(Open3).to receive(:capture3).with("kettle-rebase", root).and_return(["main is up to date\n", "", instance_double(Process::Status, success?: true)])

        results = described_class.call(config: config, members: [member("alpha", root: root)])

        expect(results).to all(be_ok)
        expect(results.first.stdout).to include("up to date")
      end

      it "fails the member when neither module nor executable is available" do
        allow(Open3).to receive(:capture3).and_raise(Errno::ENOENT)

        results = described_class.call(config: config, members: [member("alpha", root: member_root("alpha"))])

        expect(results.first).not_to be_ok
        expect(results.first.stdout).to include("upgrade kettle-dev")
      end
    end

    # Runs only when the bundle ships the module (local KETTLE_DEV_DEV wiring,
    # or after the kettle-dev floor rises past the release that adds Rebase);
    # absent from CI until then.
    if defined?(Kettle::Dev::Rebase)
      it "syncs a real checkout that is behind its upstream" do
        root = repo_with_origin("alpha")
        advance_origin("alpha")

        results = described_class.call(config: config, members: [member("alpha", root: root)])

        expect(results).to all(be_ok)
        expect(results.first.stdout).to include("rebased")
      end
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

  def member_root(name)
    File.join(@tmpdir, name).tap { |dir| FileUtils.mkdir_p(dir) }
  end

  def sync(status, message = "synced", conflicts = [])
    sync_class.new(status: status, message: message, conflicts: conflicts)
  end

  def sync_class
    @sync_class ||= Struct.new(:status, :message, :conflicts)
  end

  def stub_rebase(outcomes)
    calls = []
    fake = Module.new
    fake.define_singleton_method(:call) do |root:|
      calls << root
      outcomes.fetch(root) { raise "no stubbed rebase outcome for #{root}" }
    end
    stub_const("Kettle::Dev::Rebase", fake)
    calls
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
