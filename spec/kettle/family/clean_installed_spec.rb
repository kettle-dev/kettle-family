# frozen_string_literal: true

require "tmpdir"

# CleanInstalled is the deterministic inverse of `install`: it uninstalls each
# selected member's current source version. The fixtures are real files for the
# same reason as the sibling cleanups' specs: stubbing the RubyGems enumeration
# API is what let the bundle-scoping bug hide.
RSpec.describe Kettle::Family::CleanInstalled do
  def member(name, version: "1.2.0")
    Kettle::Family::Member.new(
      name: name,
      root: "/repo/#{name}",
      gemspec_path: nil,
      version_file: nil,
      version: version,
      dependencies: []
    )
  end

  def config_double(local_dependencies: [])
    instance_double(Kettle::Family::Config, install_local_dependencies: local_dependencies)
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

  def write_installed(root, name, *versions)
    dir = File.join(root, "specifications")
    FileUtils.mkdir_p(dir)
    versions.each { |version| FileUtils.touch(File.join(dir, "#{name}-#{version}.gemspec")) }
    dir
  end

  def write_cached(root, name, version)
    dir = File.join(root, "cache")
    FileUtils.mkdir_p(dir)
    FileUtils.touch(File.join(dir, "#{name}-#{version}.gem"))
  end

  def with_gem_homes(homes)
    allow(Gem).to receive(:path).and_return(homes)
    allow(Gem::Specification).to receive(:dirs).and_return(homes.map { |home| File.join(home, "specifications") })
  end

  def runner_that_removes(gem_home)
    runner = instance_double(Kettle::Family::CommandRunner)
    allow(runner).to receive(:call) do |member:, phase:, command:|
      command.each do |arg|
        next unless arg.include?(":")

        name, version = arg.split(":", 2)
        FileUtils.rm_f(File.join(gem_home, "specifications", "#{name}-#{version}.gemspec"))
      end
      Kettle::Family::CommandResult.new(member.name, phase, command, member.root, 0, true, "removed", "", 0.0, false, nil)
    end
    runner
  end

  describe "dry-run" do
    it "plans the uninstall of every unreleased installed source version without running anything" do
      Dir.mktmpdir do |home|
        alpha = member("alpha", version: "1.3.0")
        write_installed(home, "alpha", "1.3.0")
        with_gem_homes([home])
        with_states([release_state("alpha", latest_released: "1.2.0")])

        result = described_class.new(config: config_double, members: [alpha]).results.last

        expect(result.skipped).to be(true)
        expect(result.stdout).to eq("would uninstall alpha 1.3.0")
        expect(result.command).to eq(%w[gem uninstall alpha:1.3.0 --executables])
        expect(File.exist?(File.join(home, "specifications", "alpha-1.3.0.gemspec"))).to be(true)
      end
    end
  end

  describe "guards" do
    it "does nothing for a member whose source version is released" do
      Dir.mktmpdir do |home|
        alpha = member("alpha", version: "1.2.0")
        write_installed(home, "alpha", "1.2.0")
        with_gem_homes([home])
        with_states([release_state("alpha", latest_released: "1.2.0")])

        results = described_class.new(config: config_double, members: [alpha], execute: true).results

        expect(results.map(&:stdout)).to include("source version is released; nothing to uninstall")
        expect(File.exist?(File.join(home, "specifications", "alpha-1.2.0.gemspec"))).to be(true)
      end
    end

    it "does nothing when the source version is not installed" do
      Dir.mktmpdir do |home|
        alpha = member("alpha", version: "1.3.0")
        with_gem_homes([home])
        with_states([release_state("alpha", latest_released: "1.2.0")])

        results = described_class.new(config: config_double, members: [alpha], execute: true).results

        expect(results.map(&:stdout)).to include("source version is not installed")
      end
    end

    it "reports rather than guesses when the latest released version is unknown" do
      alpha = member("alpha", version: "1.3.0")
      with_states([release_state("alpha", latest_released: "unknown")])

      results = described_class.new(config: config_double, members: [alpha]).results

      expect(results.map(&:stdout)).to include("latest released version is unknown; no cleanup attempted")
    end

    it "fails per member when release state cannot be read" do
      alpha = member("alpha", version: "1.3.0")
      with_states([release_state("alpha", latest_released: nil, success: false, status: 1, stderr: "boom")])

      results = described_class.new(config: config_double, members: [alpha]).results

      expect(results.last.success).to be(false)
      expect(results.last.reason).to eq("release state unavailable")
    end
  end

  describe "execute" do
    it "uninstalls the source version and its cached .gem, then verifies removal" do
      Dir.mktmpdir do |home|
        alpha = member("alpha", version: "1.3.0")
        write_installed(home, "alpha", "1.2.0", "1.3.0")
        write_cached(home, "alpha", "1.3.0")
        with_gem_homes([home])
        with_states([release_state("alpha", latest_released: "1.2.0")])
        runner = runner_that_removes(home)

        results = described_class.new(config: config_double, members: [alpha], execute: true, runner: runner).results

        expect(results.last.success).to be(true)
        # Only the unreleased source version is removed; the released install stays.
        expect(File.exist?(File.join(home, "specifications", "alpha-1.2.0.gemspec"))).to be(true)
        expect(File.exist?(File.join(home, "specifications", "alpha-1.3.0.gemspec"))).to be(false)
        expect(File.exist?(File.join(home, "cache", "alpha-1.3.0.gem"))).to be(false)
      end
    end

    it "batches several members into one invocation, each reporting its own gem" do
      Dir.mktmpdir do |home|
        alpha = member("alpha", version: "1.3.0")
        beta = member("beta", version: "2.4.0")
        write_installed(home, "alpha", "1.3.0")
        write_installed(home, "beta", "2.4.0")
        with_gem_homes([home])
        with_states([
          release_state("alpha", latest_released: "1.2.0"),
          release_state("beta", latest_released: "2.3.0")
        ])
        runner = runner_that_removes(home)

        results = described_class.new(config: config_double, members: [alpha, beta], execute: true, runner: runner).results

        expect(runner).to have_received(:call).once
        expect(results.map(&:member_name)).to contain_exactly("alpha", "beta")
        expect(results.map(&:stdout)).to all(eq("removed"))
      end
    end
  end

  describe "install local_dependencies" do
    # The inverse must cover what install covers: configured local_dependencies
    # are installed alongside members, so they are uninstalled alongside them.
    it "includes configured install local_dependencies" do
      Dir.mktmpdir do |home|
        Dir.mktmpdir do |repo|
          dep_dir = File.join(repo, "local-dep")
          FileUtils.mkdir_p(dep_dir)
          File.write(File.join(dep_dir, "local-dep.gemspec"), <<~GEMSPEC)
            Gem::Specification.new do |spec|
              spec.name = "local-dep"
              spec.version = "2.0.0"
              spec.summary = "local dependency"
              spec.authors = ["example"]
            end
          GEMSPEC

          write_installed(home, "local-dep", "2.0.0")
          with_gem_homes([home])
          with_states([release_state("local-dep", latest_released: "1.9.0")])
          runner = runner_that_removes(home)

          results = described_class.new(
            config: config_double(local_dependencies: [dep_dir]),
            members: [],
            execute: true,
            runner: runner
          ).results

          expect(results.map(&:member_name)).to include("local-dep")
          expect(File.exist?(File.join(home, "specifications", "local-dep-2.0.0.gemspec"))).to be(false)
        end
      end
    end
  end
end
