# frozen_string_literal: true

require "tmpdir"
require "fileutils"

# Declared at the top level rather than inside the example group: a constant
# defined in an RSpec block leaks past the group (RSpec/LeakyConstantDeclaration)
# and is redefined on every run (Lint/ConstantDefinitionInBlock).

# A lockfile with GEM-section pins: the inspectable case.
BLOCKER_REGISTRY_LOCK = <<~LOCK
  GEM
    remote: https://gem.coop/
    specs:
      ast-crispr (7.1.10)

  PLATFORMS
    ruby
LOCK

# A lockfile resolved entirely through PATH remotes: local-gem mode, where family
# siblings come from source checkouts and there are no GEM-section specs for the
# registry check to examine.
BLOCKER_PATH_MODE_LOCK = <<~LOCK
  PATH
    remote: /repo/local-gem
    specs:
      ast-crispr (7.1.10)

  PLATFORMS
    ruby
LOCK

RSpec.describe Kettle::Family::BlockerCleanup do
  # Members get real directories and real lockfiles rather than stubbed paths.
  # The sibling command's spec documents why: stubbing the filesystem or the
  # RubyGems enumeration API is what let a bundle-scoping bug hide, because a
  # double returns whatever the test hands it. Stubbing File.file? per member
  # would also be fragile here, since re-stubbing File for a second member
  # discards the first member's constraint.
  def member(name, root_dir, lockfile: BLOCKER_REGISTRY_LOCK)
    member_root = File.join(root_dir, name)
    FileUtils.mkdir_p(member_root)
    File.write(File.join(member_root, "Gemfile.lock"), lockfile) unless lockfile.nil?
    Kettle::Family::Member.new(
      name: name,
      root: member_root,
      gemspec_path: nil,
      version_file: nil,
      version: "1.2.0",
      dependencies: []
    )
  end

  def write_installed(gem_home, name, *versions)
    dir = File.join(gem_home, "specifications")
    FileUtils.mkdir_p(dir)
    versions.each { |version| FileUtils.touch(File.join(dir, "#{name}-#{version}.gemspec")) }
    dir
  end

  def with_gem_homes(homes)
    allow(Gem).to receive(:path).and_return(homes)
    allow(Gem::Specification).to receive(:dirs).and_return(homes.map { |home| File.join(home, "specifications") })
  end

  # Stub the registry check. BlockerCleanup consumes its structured diagnostics
  # rather than its stdout, because stdout is truncated to its last 20 lines by
  # CommandResult#summarize: the real failure case had 28 blockers, so a stdout
  # consumer would have silently lost 8 of them.
  #
  # diagnostics is assigned after construction: CommandResult is a positional
  # Struct and diagnostics is its LAST member, well past the 11 the existing specs
  # pass. Passing it positionally would land it in the `branch` slot.
  def with_blockers(blockers_by_member)
    check = class_double(Kettle::Family::PublishedVersionCheck).as_stubbed_const
    allow(check).to receive(:call) do |member:|
      diagnostics = (blockers_by_member[member.name] || []).map do |gem_name, version|
        {
          "kind" => "unpublished_lockfile_pin",
          "gem" => gem_name,
          "version" => version,
          "remote" => "https://gem.coop/",
          "member" => member.name
        }
      end
      result = Kettle::Family::CommandResult.new(
        member.name, "published_version_check", ["internal"], member.root,
        diagnostics.any? ? 1 : 0, diagnostics.empty?, "", "", 0.0, false, nil
      )
      result.diagnostics = diagnostics
      result
    end
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
    it "names every blocker it would remove without running anything" do
      Dir.mktmpdir do |home|
        Dir.mktmpdir do |repo|
          alpha = member("alpha", repo)
          write_installed(home, "ast-crispr", "7.1.10")
          write_installed(home, "ast-merge", "7.1.10")
          with_gem_homes([home])
          with_blockers("alpha" => [["ast-crispr", "7.1.10"], ["ast-merge", "7.1.10"]])

          result = described_class.new(members: [alpha]).results.last

          expect(result.skipped).to be(true)
          expect(result.stdout).to eq("would uninstall ast-crispr 7.1.10, ast-merge 7.1.10")
          expect(result.command).to eq(%w[gem uninstall ast-crispr:7.1.10 ast-merge:7.1.10 --executables])
          # Nothing removed, because this was a plan only.
          expect(File.exist?(File.join(home, "specifications", "ast-crispr-7.1.10.gemspec"))).to be(true)
        end
      end
    end
  end

  describe "cross-family reach" do
    # The reason this command exists. `clean-unreleased` derives candidates from
    # family members' release state, so it can only remove a member of its own
    # family. Here a kettle-family-shaped member is blocked by gems from a
    # completely different family, and they must still be found and removed.
    it "finds and removes blockers belonging to other families" do
      Dir.mktmpdir do |home|
        Dir.mktmpdir do |repo|
          kettle_family = member("kettle-family", repo)
          write_installed(home, "ast-crispr", "7.1.10")
          write_installed(home, "tree_haver", "7.1.10")
          with_gem_homes([home])
          with_blockers("kettle-family" => [["ast-crispr", "7.1.10"], ["tree_haver", "7.1.10"]])
          runner = runner_that_removes(home)

          results = described_class.new(members: [kettle_family], execute: true, runner: runner).results

          expect(results.last.success).to be(true)
          expect(runner).to have_received(:call).with(
            member: kettle_family,
            phase: "clean_blockers",
            command: %w[gem uninstall ast-crispr:7.1.10 tree_haver:7.1.10 --executables]
          )
          expect(File.exist?(File.join(home, "specifications", "ast-crispr-7.1.10.gemspec"))).to be(false)
        end
      end
    end

    it "unions and deduplicates blockers pinned by several members" do
      Dir.mktmpdir do |home|
        Dir.mktmpdir do |repo|
          alpha = member("alpha", repo)
          beta = member("beta", repo)
          write_installed(home, "ast-crispr", "7.1.10")
          write_installed(home, "tree_haver", "7.1.10")
          with_gem_homes([home])
          # Both members pin ast-crispr; only one invocation may result, because
          # per-gem invocations raise Gem::DependencyRemovalException on
          # interdependent gems.
          with_blockers(
            "alpha" => [["ast-crispr", "7.1.10"], ["tree_haver", "7.1.10"]],
            "beta" => [["ast-crispr", "7.1.10"]]
          )
          runner = runner_that_removes(home)

          results = described_class.new(members: [alpha, beta], execute: true, runner: runner).results

          expect(runner).to have_received(:call).once
          expect(results.map(&:member_name)).to contain_exactly("alpha", "beta")
        end
      end
    end
  end

  describe "PATH-mode lockfiles" do
    # A member in local-gem mode resolves its siblings through PATH remotes, so
    # its lockfile has no GEM-section specs and the check finds nothing. Reporting
    # that as "no blockers" would claim a clean bill of health that was never
    # established -- the same failure mode as reporting success over an uninstall
    # that removed nothing.
    it "distinguishes not-inspectable from genuinely clean" do
      Dir.mktmpdir do |home|
        Dir.mktmpdir do |repo|
          path_mode = member("path-mode", repo, lockfile: BLOCKER_PATH_MODE_LOCK)
          with_gem_homes([home])
          with_blockers({})

          result = described_class.new(members: [path_mode]).results.first

          expect(result.stdout).to eq("lockfile has no registry-resolved pins; nothing inspectable")
        end
      end
    end

    it "reports no blockers for a registry-resolved lockfile with none" do
      Dir.mktmpdir do |home|
        Dir.mktmpdir do |repo|
          clean = member("clean", repo)
          with_gem_homes([home])
          with_blockers({})

          result = described_class.new(members: [clean]).results.first

          expect(result.stdout).to eq("no unpublished lockfile pins found")
        end
      end
    end

    it "reports a member with no lockfile as not inspectable" do
      Dir.mktmpdir do |home|
        Dir.mktmpdir do |repo|
          absent = member("absent", repo, lockfile: nil)
          with_gem_homes([home])
          with_blockers({})

          result = described_class.new(members: [absent]).results.first

          expect(result.stdout).to eq("lockfile has no registry-resolved pins; nothing inspectable")
        end
      end
    end
  end

  describe "blockers that cannot be removed here" do
    # A blocker not installed in a gem home is a PATH or git source checkout.
    # `gem uninstall` cannot remove one, and including it would abort the whole
    # batch -- so it must be reported, not attempted.
    it "reports a source-checkout blocker instead of attempting to uninstall it" do
      Dir.mktmpdir do |home|
        Dir.mktmpdir do |repo|
          alpha = member("alpha", repo)
          with_gem_homes([home])
          with_blockers("alpha" => [["local-only-gem", "9.9.9"]])
          runner = instance_double(Kettle::Family::CommandRunner)
          allow(runner).to receive(:call)

          results = described_class.new(members: [alpha], execute: true, runner: runner).results

          expect(results.first.stdout).to include("not installed in a gem home")
          expect(results.first.stdout).to include("local-only-gem 9.9.9")
          expect(runner).not_to have_received(:call)
        end
      end
    end
  end

  describe "version normalization" do
    it "strips a platform suffix so the pinned version matches the installed spec" do
      Dir.mktmpdir do |home|
        Dir.mktmpdir do |repo|
          alpha = member("alpha", repo)
          # Gem homes store the platform in the FILENAME, but the parsed version is
          # platform-independent.
          write_installed(home, "nokogiri", "1.19.4")
          with_gem_homes([home])
          with_blockers("alpha" => [["nokogiri", "1.19.4-x86_64-linux-gnu"]])

          result = described_class.new(members: [alpha]).results.last

          expect(result.command).to eq(%w[gem uninstall nokogiri:1.19.4 --executables])
        end
      end
    end

    # `Gem::Version.new("")` returns version "0" rather than raising, so a blank
    # version would silently become a bogus `name:0` uninstall argument.
    it "skips a blank version instead of turning it into version 0" do
      Dir.mktmpdir do |home|
        Dir.mktmpdir do |repo|
          alpha = member("alpha", repo)
          write_installed(home, "alpha-gem", "1.0.0")
          with_gem_homes([home])
          with_blockers("alpha" => [["alpha-gem", ""]])
          runner = instance_double(Kettle::Family::CommandRunner)
          allow(runner).to receive(:call)

          results = described_class.new(members: [alpha], execute: true, runner: runner).results

          expect(runner).not_to have_received(:call)
          expect(results.first.stdout).to include("not installed in a gem home")
        end
      end
    end
  end

  describe "post-uninstall verification" do
    # `gem uninstall` exits 0 and prints "Gem 'name' is not installed" when it
    # removes nothing, so exit status alone cannot distinguish a completed cleanup
    # from one that found the wrong gem home and silently did nothing.
    it "fails when the gem is still installed after a successful uninstall" do
      Dir.mktmpdir do |home|
        Dir.mktmpdir do |repo|
          alpha = member("alpha", repo)
          write_installed(home, "ast-crispr", "7.1.10")
          with_gem_homes([home])
          with_blockers("alpha" => [["ast-crispr", "7.1.10"]])
          runner = instance_double(Kettle::Family::CommandRunner)
          allow(runner).to receive(:call).and_return(
            Kettle::Family::CommandResult.new(
              "alpha", "clean_blockers", %w[gem uninstall], "/repo/alpha",
              0, true, "Gem 'ast-crispr' is not installed", "", 0.0, false, nil
            )
          )

          result = described_class.new(members: [alpha], execute: true, runner: runner).results.last

          # The per-member result intentionally overrides `reason` with the
          # attribution message (matching UnreleasedGemCleanup), while the
          # verification detail from #verified_uninstall_outcome is preserved in
          # stderr by CommandResult#dup. Assert both, so neither can regress into
          # a silent "uninstall succeeded" verdict.
          expect(result.success).to be(false)
          expect(result.skipped).to be(false)
          expect(result.reason).to include("batched gem uninstall including ast-crispr 7.1.10 failed")
          expect(result.stderr).to include("still installed after gem uninstall: ast-crispr 7.1.10")
        end
      end
    end
  end
end
