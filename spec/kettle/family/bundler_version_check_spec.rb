# frozen_string_literal: true

require "fileutils"
require "tmpdir"

# :real_bundler_version_check opts out of the global stub of this check's
# seam (see spec/support/shared_contexts/with_stubbed_bundler_version_check.rb)
# so these examples exercise the real class against a stubbed BundlerPinning.
RSpec.describe Kettle::Family::BundlerVersionCheck, :real_bundler_version_check do
  around do |example|
    Dir.mktmpdir("kettle-family-bundler-version-spec") do |dir|
      @tmpdir = dir
      example.run
    end
  end

  before do
    write_config
  end

  describe ".gated?" do
    it "gates bundle-mutating commands" do
      expect(described_class.gated?("template")).to be(true)
      expect(described_class.gated?("bup")).to be(true)
    end

    it "never gates the remedy commands, or commands that leave bundles alone" do
      %w[bupb update-bundler release check test lint bex install].each do |command|
        expect(described_class.gated?(command)).to be(false), "expected #{command} to be ungated"
      end
    end
  end

  describe ".call" do
    it "fails open when the registry cannot be consulted" do
      stub_bundler_pinning(published: nil, installed: Gem::Version.new("4.1.0"))

      result = check(members: [member("alpha", bundled_with: "4.0.23")])

      expect(result).to be_ok
      expect(result.diagnostics).to be_empty
    end

    it "passes when the installed stable and every member pin match the registry latest stable" do
      stub_bundler_pinning(published: Gem::Version.new("4.1.0"), installed: Gem::Version.new("4.1.0"))

      result = check(members: [member("alpha", bundled_with: "4.1.0"), member("beta", bundled_with: "4.1.0")])

      expect(result).to be_ok
      expect(result.diagnostics).to be_empty
    end

    it "fails when the installed stable lags the registry, naming both versions and the remedy" do
      stub_bundler_pinning(published: Gem::Version.new("4.1.0"), installed: Gem::Version.new("4.0.24"))

      result = check(members: [])

      expect(result).not_to be_ok
      expect(result.member_name).to eq(config.family_name)
      expect(result.phase).to eq("bundler_version_check")
      expect(result.stdout).to include("4.0.24", "4.1.0", "update-bundler --execute")
      expect(result.diagnostics).to match([hash_including("kind" => "bundler_installed_drift", "held" => false)])
    end

    it "fails with the hold reason when the installed stable is a known-bad held version" do
      stub_bundler_pinning(published: Gem::Version.new("4.1.0"), installed: Gem::Version.new("4.2.0"))
      allow(Kettle::Dev::BundlerPinning).to receive(:held_reason).with(Gem::Version.new("4.2.0")).and_return("breaks nested Bundler loads")

      result = check(members: [])

      expect(result).not_to be_ok
      expect(result.stdout).to include("known-bad held version", "breaks nested Bundler loads")
      expect(result.diagnostics).to match([hash_including("kind" => "bundler_installed_drift", "held" => true)])
    end

    it "points at HELD_VERSIONS when the installed stable leads the registry without a registered hold" do
      stub_bundler_pinning(published: Gem::Version.new("4.1.0"), installed: Gem::Version.new("4.2.0"))

      result = check(members: [])

      expect(result).not_to be_ok
      expect(result.stdout).to include("HELD_VERSIONS")
    end

    it "fails when no stable Bundler is installed at all" do
      stub_bundler_pinning(published: Gem::Version.new("4.1.0"), installed: nil)

      result = check(members: [])

      expect(result).not_to be_ok
      expect(result.stdout).to include("no stable Bundler is installed", "update-bundler --execute")
      expect(result.diagnostics).to match([hash_including("kind" => "bundler_not_installed")])
    end

    it "fails when a member lockfile pins an older Bundler, naming the member" do
      stub_bundler_pinning(published: Gem::Version.new("4.1.0"), installed: Gem::Version.new("4.1.0"))

      result = check(members: [member("alpha", bundled_with: "4.0.23"), member("beta", bundled_with: "4.1.0")])

      expect(result).not_to be_ok
      expect(result.stdout).to include("alpha", "4.0.23", "4.1.0")
      expect(result.stdout).not_to include("beta")
      expect(result.diagnostics).to match([hash_including("kind" => "bundler_lockfile_drift", "member" => "alpha")])
    end

    it "calls out a prerelease member pin as the reinfection vector" do
      stub_bundler_pinning(published: Gem::Version.new("4.1.0"), installed: Gem::Version.new("4.1.0"))

      result = check(members: [member("alpha", bundled_with: "4.1.0.beta1")])

      expect(result).not_to be_ok
      expect(result.stdout).to include("4.1.0.beta1", "prerelease")
    end

    it "skips members without a lockfile, without a BUNDLED WITH trailer, or with one Bundler cannot parse" do
      stub_bundler_pinning(published: Gem::Version.new("4.1.0"), installed: Gem::Version.new("4.1.0"))
      no_lockfile = member("alpha")
      no_trailer = member("beta", bundled_with: nil)
      unparsable = member("gamma", bundled_with: "not-a-version")

      result = check(members: [no_lockfile, no_trailer, unparsable])

      expect(result).to be_ok
    end

    it "skips a member whose lockfile Bundler refuses to parse (announced future LockfileError)" do
      stub_bundler_pinning(published: Gem::Version.new("4.1.0"), installed: Gem::Version.new("4.1.0"))
      with_lockfile = member("alpha", bundled_with: "4.1.0")
      allow(Bundler::LockfileParser).to receive(:new).and_raise(Bundler::LockfileError, "invalid lockfile")

      result = check(members: [with_lockfile])

      expect(result).to be_ok
    end
  end

  def write_config
    File.write(File.join(@tmpdir, ".kettle-family.yml"), "family:\n  name: bundler-spec\n")
  end

  def config
    Kettle::Family::Config.load(root: @tmpdir)
  end

  def check(members:)
    described_class.call(config: config, members: members)
  end

  def stub_bundler_pinning(published:, installed:)
    allow(Kettle::Dev::BundlerPinning).to receive_messages(
      published_stable: published,
      installed_stable: installed,
      held_reason: nil
    )
  end

  def member(name, bundled_with: :none)
    root = File.join(@tmpdir, name)
    FileUtils.mkdir_p(root)
    case bundled_with
    when :none
      nil
    when nil
      File.write(File.join(root, "Gemfile.lock"), bare_lockfile)
    else
      File.write(File.join(root, "Gemfile.lock"), lockfile(pinned: bundled_with))
    end
    Kettle::Family::Member.new(name: name, root: root, gemspec_path: nil, version_file: nil, version: "1.0.0", dependencies: [])
  end

  def lockfile(pinned:)
    <<~LOCKFILE
      GEM
        remote: https://rubygems.org/
        specs:

      PLATFORMS
        ruby

      DEPENDENCIES

      BUNDLED WITH
         #{pinned}
    LOCKFILE
  end

  def bare_lockfile
    <<~LOCKFILE
      GEM
        remote: https://rubygems.org/
        specs:

      PLATFORMS
        ruby

      DEPENDENCIES
    LOCKFILE
  end
end
