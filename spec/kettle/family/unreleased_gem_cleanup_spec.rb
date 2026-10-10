# frozen_string_literal: true

require "tmpdir"
require "fileutils"

RSpec.describe Kettle::Family::UnreleasedGemCleanup do
  def member(name)
    Kettle::Family::Member.new(
      name: name,
      root: "/repo/#{name}",
      gemspec_path: nil,
      version_file: nil,
      version: "1.2.0",
      dependencies: []
    )
  end

  def release_state(member_name, latest_released:, success: true, status: 0, stderr: "")
    Kettle::Family::ReleaseStateResult.new(
      member_name: member_name,
      command: %w[kettle-changelog --release-state --json],
      workdir: "/repo/#{member_name}",
      status: status,
      success: success,
      stdout: "",
      stderr: stderr,
      elapsed_seconds: 0.0,
      state: {"latest_released" => latest_released}
    )
  end

  def with_states(states)
    allow(Kettle::Family::ReleaseStateCheck).to receive(:new)
      .and_return(instance_double(Kettle::Family::ReleaseStateCheck, results: states))
  end

  # A gem home laid out the way RubyGems lays it out: one .gemspec per installed
  # version under specifications/. The fixture is real files rather than doubles,
  # because stubbing Gem::Specification.find_all_by_name is what let the
  # bundle-scoping bug hide: that API reports only versions the active bundle
  # resolves, and a double returns whatever the test hands it.
  def write_installed(root, name, *versions)
    dir = File.join(root, "specifications")
    FileUtils.mkdir_p(dir)
    versions.each { |version| FileUtils.touch(File.join(dir, "#{name}-#{version}.gemspec")) }
    dir
  end

  # Points Gem.path at the given gem homes and Gem::Specification.dirs at their
  # specification directories. `outside_dirs` are specification dirs that are NOT
  # under any Gem.path root, which is what a PATH or git source checkout looks
  # like to the scanner.
  def with_gem_homes(homes, outside_dirs: [])
    specification_dirs = homes.map { |home| File.join(home, "specifications") }
    allow(Gem).to receive(:path).and_return(homes)
    allow(Gem::Specification).to receive(:dirs).and_return(specification_dirs + outside_dirs)
  end

  it "plans a single batched uninstall of installed versions newer than the latest release" do
    Dir.mktmpdir do |home|
      write_installed(home, "alpha", "0.9.0", "1.0.0", "1.0.1", "1.1.0")
      with_gem_homes([home])
      with_states([release_state("alpha", latest_released: "1.0.0")])

      results = described_class.new(config: nil, members: [member("alpha")]).results

      expect(results.map(&:stdout)).to eq(["would uninstall alpha 1.0.1, alpha 1.1.0"])
      expect(results.map(&:skipped)).to eq([true])
      expect(results.map(&:command)).to eq([
        %w[gem uninstall alpha:1.0.1 alpha:1.1.0 --executables]
      ])
    end
  end

  # Regression for the bundle-scoping bug. Under `bundle exec`, find_all_by_name
  # (and stubs_for, and Specification.all) return only the versions the active
  # bundle resolves, so an unreleased version that is installed but not pinned by
  # the lockfile was invisible. Cleanup then reported "no unreleased installed
  # versions found" with outcome success while leaving the offender installed --
  # blind in exactly the state it exists to correct, because re-resolving the
  # lockfile to released versions is what hides the offender from the API.
  # Observed live with kettle-rb: `gem list` showed 0.1.14, 0.1.15 and 0.1.16
  # while find_all_by_name under bundle exec returned only 0.1.15.
  it "finds an unreleased installed version the active bundle does not resolve" do
    Dir.mktmpdir do |home|
      write_installed(home, "alpha", "1.0.0", "1.0.1")
      with_gem_homes([home])
      with_states([release_state("alpha", latest_released: "1.0.0")])
      # What the bundle-scoped API would report: only the released version.
      allow(Gem::Specification).to receive(:find_all_by_name).with("alpha")
        .and_return([instance_double(Gem::Specification, version: Gem::Version.new("1.0.0"))])

      result = described_class.new(config: nil, members: [member("alpha")]).results.first

      expect(result.command).to eq(%w[gem uninstall alpha:1.0.1 --executables])
    end
  end

  # A runner double that behaves like a real `gem uninstall`: it removes the
  # specification files from the fixture gem home. Cleanup re-enumerates after
  # the batch to verify removal, so a double that only returns success would
  # model a cleanup that removed nothing.
  def runner_that_removes(gem_home, result: nil)
    runner = instance_double(Kettle::Family::CommandRunner)
    allow(runner).to receive(:call) do |member:, phase:, command:|
      command.each do |arg|
        next unless arg.include?(":")

        name, version = arg.split(":", 2)
        FileUtils.rm_f(File.join(gem_home, "specifications", "#{name}-#{version}.gemspec"))
      end
      result || Kettle::Family::CommandResult.new(member.name, phase, command, member.root, 0, true, "removed", "", 0.0, false, nil)
    end
    runner
  end

  it "runs one gem uninstall for all unreleased installed candidates when executed" do
    Dir.mktmpdir do |home|
      alpha = member("alpha")
      write_installed(home, "alpha", "1.0.1")
      with_gem_homes([home])
      with_states([release_state("alpha", latest_released: "1.0.0")])
      expected = Kettle::Family::CommandResult.new("alpha", "clean_unreleased", %w[gem uninstall alpha], "/repo/alpha", 0, true, "", "", 0.0, false, nil)
      runner = runner_that_removes(home, result: expected)

      results = described_class.new(config: nil, members: [alpha], execute: true, runner: runner).results

      expect(results).to eq([expected])
      expect(runner).to have_received(:call).with(
        member: alpha,
        phase: "clean_unreleased",
        command: %w[gem uninstall alpha:1.0.1 --executables]
      )
    end
  end

  # RubyGems' uninstall_specific topologically sorts the whole requested set
  # (strongly_connected_components.flatten.reverse), removing dependents before
  # their dependencies. A per-gem invocation sees one gem, cannot sort, and
  # raises Gem::DependencyRemovalException when an installed gem still depends on
  # it. Family members are interdependent, so this is the difference between
  # succeeding and failing on the foundations.
  it "batches candidates from every member into one invocation" do
    Dir.mktmpdir do |home|
      alpha = member("alpha")
      beta = member("beta")
      write_installed(home, "alpha", "1.0.1")
      write_installed(home, "beta", "2.0.1", "2.1.0")
      with_gem_homes([home])
      with_states([
        release_state("alpha", latest_released: "1.0.0"),
        release_state("beta", latest_released: "2.0.0")
      ])
      runner = runner_that_removes(home)

      described_class.new(config: nil, members: [alpha, beta], execute: true, runner: runner).results

      expect(runner).to have_received(:call).once
      expect(runner).to have_received(:call).with(
        member: alpha,
        phase: "clean_unreleased",
        command: %w[gem uninstall alpha:1.0.1 beta:2.0.1 beta:2.1.0 --executables]
      )
    end
  end

  # --all with no gem arguments means uninstall_all, which removes every gem in
  # the gem home. Omitting it makes an empty argument list a usage error instead.
  it "never passes --all or --version to gem uninstall" do
    Dir.mktmpdir do |home|
      write_installed(home, "alpha", "1.0.1")
      with_gem_homes([home])
      with_states([release_state("alpha", latest_released: "1.0.0")])

      command = described_class.new(config: nil, members: [member("alpha")]).results.first.command

      expect(command).not_to include("--all")
      expect(command).not_to include("--version")
    end
  end

  # Enumerating installed specs twice per member would double the work and could
  # report inconsistently if an install landed between the two passes.
  it "enumerates installed versions once per member" do
    Dir.mktmpdir do |home|
      write_installed(home, "alpha", "1.0.1")
      with_gem_homes([home])
      with_states([release_state("alpha", latest_released: "1.0.0")])
      allow(Dir).to receive(:glob).and_call_original

      described_class.new(config: nil, members: [member("alpha")]).results

      expect(Dir).to have_received(:glob)
        .with(File.join(home, "specifications", "alpha-*.gemspec")).once
    end
  end

  # Under `bundle exec`, bundler puts PATH and git sources on the load path, so a
  # source checkout can look like a spec (gems/tree_haver at 7.1.10) rather than
  # an installed gem. `gem uninstall` cannot remove one, so offering to would
  # report work that can never succeed -- and once batched, one such bogus
  # candidate would abort the whole batch.
  it "ignores specification dirs outside a gem home" do
    Dir.mktmpdir do |home|
      Dir.mktmpdir do |checkout|
        outside = write_installed(checkout, "alpha", "1.0.1")
        with_gem_homes([home], outside_dirs: [outside])
        with_states([release_state("alpha", latest_released: "1.0.0")])

        result = described_class.new(config: nil, members: [member("alpha")]).results.first

        expect(result).to be_ok
        expect(result.stdout).to eq("no unreleased installed versions found")
      end
    end
  end

  # A bogus source-checkout candidate must not poison the batch that removes
  # genuinely installed gems.
  it "batches installed gems while excluding source checkouts" do
    Dir.mktmpdir do |home|
      Dir.mktmpdir do |checkout|
        write_installed(home, "alpha", "1.0.1")
        outside = write_installed(checkout, "beta", "2.0.1")
        with_gem_homes([home], outside_dirs: [outside])
        with_states([
          release_state("alpha", latest_released: "1.0.0"),
          release_state("beta", latest_released: "2.0.0")
        ])

        result = described_class.new(config: nil, members: [member("alpha"), member("beta")]).results.last

        expect(result.command).to eq(%w[gem uninstall alpha:1.0.1 --executables])
      end
    end
  end

  # A native gem's specification filename carries a platform suffix. The version
  # is the part before the first hyphen, matching Gem::Specification#version, so
  # the platform must not leak into the candidate argument.
  it "reads the version from a native platform specification filename" do
    Dir.mktmpdir do |home|
      dir = File.join(home, "specifications")
      FileUtils.mkdir_p(dir)
      FileUtils.touch(File.join(dir, "alpha-1.0.1-x86_64-linux.gemspec"))
      with_gem_homes([home])
      with_states([release_state("alpha", latest_released: "1.0.0")])

      result = described_class.new(config: nil, members: [member("alpha")]).results.first

      expect(result.command).to eq(%w[gem uninstall alpha:1.0.1 --executables])
    end
  end

  # `alpha-extra` is a different gem whose specification files also start with
  # the `alpha-` prefix. Its version part does not parse, so it must be skipped
  # rather than guessed at and offered to `gem uninstall`.
  it "skips specification files belonging to a differently named gem" do
    Dir.mktmpdir do |home|
      write_installed(home, "alpha", "1.0.1")
      write_installed(home, "alpha-extra", "9.9.9")
      with_gem_homes([home])
      with_states([release_state("alpha", latest_released: "1.0.0")])

      result = described_class.new(config: nil, members: [member("alpha")]).results.first

      expect(result.command).to eq(%w[gem uninstall alpha:1.0.1 --executables])
    end
  end

  # The same version can be present in more than one Gem.path root (a user gem
  # home shadowing the interpreter's). One candidate per version keeps the
  # uninstall argument list free of duplicates.
  it "reports when installed versions contain no unreleased candidates" do
    Dir.mktmpdir do |home|
      Dir.mktmpdir do |other_home|
        write_installed(home, "alpha", "0.9.0", "1.0.0")
        write_installed(other_home, "alpha", "1.0.0")
        with_gem_homes([home, other_home])
        with_states([release_state("alpha", latest_released: "v1.0.0")])

        result = described_class.new(config: nil, members: [member("alpha")]).results.fetch(0)

        expect(result).to be_ok
        expect(result.stdout).to eq("no unreleased installed versions found")
      end
    end
  end

  # Regression guard: `reason` must stay nil for a successful real run, and must
  # be preserved verbatim for a dry run. Neither was previously asserted, which
  # let a refactor silently change it.
  it "reports a nil reason when the executed batch succeeds" do
    Dir.mktmpdir do |home|
      write_installed(home, "alpha", "1.0.1")
      with_gem_homes([home])
      with_states([release_state("alpha", latest_released: "1.0.0")])
      runner = runner_that_removes(
        home,
        result: Kettle::Family::CommandResult.new("alpha", "clean_unreleased", %w[gem uninstall], "/repo/alpha", 0, true, "ok", "", 0.5, false, nil)
      )

      result = described_class.new(config: nil, members: [member("alpha")], execute: true, runner: runner).results.first

      expect(result).to be_ok
      expect(result.skipped).to be(false)
      expect(result.reason).to be_nil
      expect(result.stdout).to eq("ok")
    end
  end

  # A failed batch must name the gems that member contributed, not just say the
  # batch failed, so a multi-member failure is still attributable per member.
  it "names the member's own gems when the executed batch fails" do
    Dir.mktmpdir do |home|
      write_installed(home, "alpha", "1.0.1")
      with_gem_homes([home])
      with_states([release_state("alpha", latest_released: "1.0.0")])
      runner = instance_double(Kettle::Family::CommandRunner)
      allow(runner).to receive(:call).and_return(
        Kettle::Family::CommandResult.new("alpha", "clean_unreleased", %w[gem uninstall], "/repo/alpha", 1, false, "", "boom", 0.5, false, "command failed")
      )

      result = described_class.new(config: nil, members: [member("alpha")], execute: true, runner: runner).results.first

      expect(result).not_to be_ok
      expect(result.reason).to eq("batched gem uninstall including alpha 1.0.1 failed")
    end
  end

  # `gem uninstall` exits 0 and prints "Gem 'name' is not installed" when it
  # removes nothing, so a bare exit-status check reports success for a cleanup
  # that never happened. Post-removal verification catches that instead of
  # trusting the status, and names the version that survived.
  it "fails when gem uninstall exits 0 but the version is still installed" do
    Dir.mktmpdir do |home|
      write_installed(home, "alpha", "1.0.1")
      with_gem_homes([home])
      with_states([release_state("alpha", latest_released: "1.0.0")])
      runner = instance_double(Kettle::Family::CommandRunner)
      allow(runner).to receive(:call).and_return(
        Kettle::Family::CommandResult.new("alpha", "clean_unreleased", %w[gem uninstall], "/repo/alpha", 0, true, "Gem 'alpha' is not installed", "", 0.5, false, nil)
      )

      result = described_class.new(config: nil, members: [member("alpha")], execute: true, runner: runner).results.first

      expect(result).not_to be_ok
      # member_result deliberately restates the failure in per-member terms so a
      # multi-member batch stays attributable; the verification detail rides in
      # stderr, where it names exactly which version survived.
      expect(result.reason).to eq("batched gem uninstall including alpha 1.0.1 failed")
      expect(result.stderr).to include("still present after gem uninstall: alpha 1.0.1")
    end
  end

  it "does not uninstall when the latest released version is unknown" do
    Dir.mktmpdir do |home|
      write_installed(home, "alpha", "1.0.1")
      with_gem_homes([home])
      with_states([release_state("alpha", latest_released: nil)])
      allow(Dir).to receive(:glob).and_call_original

      results = described_class.new(config: nil, members: [member("alpha")]).results

      expect(results.first).to be_ok
      expect(results.first.stdout).to include("latest released version is unknown")
      expect(Dir).not_to have_received(:glob)
        .with(File.join(home, "specifications", "alpha-*.gemspec"))
    end
  end

  it "reports missing and failed release state without inspecting installed gems" do
    Dir.mktmpdir do |home|
      alpha = member("alpha")
      beta = member("beta")
      failed_state = release_state(
        "beta",
        latest_released: nil,
        success: false,
        status: 6,
        stderr: "state unavailable"
      )
      with_gem_homes([home])
      with_states([failed_state])
      allow(Dir).to receive(:glob).and_call_original

      results = described_class.new(config: nil, members: [alpha, beta]).results

      expect(results.map(&:status)).to eq([1, 6])
      expect(results.map(&:reason)).to all(eq("release state unavailable"))
      expect(results.last.stderr).to eq("state unavailable")
      expect(Dir).not_to have_received(:glob)
        .with(File.join(home, "specifications", "alpha-*.gemspec"))
    end
  end

  it "treats unknown and malformed released versions as unavailable" do
    Dir.mktmpdir do |home|
      members = %w[alpha beta].map { |name| member(name) }
      states = ["unknown", "not-a-version"].each_with_index.map do |version, index|
        release_state(members.fetch(index).name, latest_released: version)
      end
      write_installed(home, "alpha", "1.0.1")
      write_installed(home, "beta", "1.0.1")
      with_gem_homes([home])
      with_states(states)
      allow(Dir).to receive(:glob).and_call_original

      results = described_class.new(config: nil, members: members).results

      expect(results.map(&:stdout)).to all(include("latest released version is unknown"))
      expect(Dir).not_to have_received(:glob)
        .with(File.join(home, "specifications", "alpha-*.gemspec"))
    end
  end
end
