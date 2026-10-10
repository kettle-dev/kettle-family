# frozen_string_literal: true

require "tmpdir"

# ReleasePreClean removes installed gems whose versions no registry publishes,
# before a release-mode dependency update re-pins them. Like the sibling
# cleanups' specs, the fixtures are real filesystem state: stubbing the
# RubyGems enumeration API is what let the bundle-scoping bug hide.
RSpec.describe Kettle::Family::ReleasePreClean do
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

  def write_installed(root, name, *versions)
    dir = File.join(root, "specifications")
    FileUtils.mkdir_p(dir)
    versions.each { |version| FileUtils.touch(File.join(dir, "#{name}-#{version}.gemspec")) }
    dir
  end

  def with_gem_homes(homes)
    allow(Gem).to receive(:path).and_return(homes)
    allow(Gem::Specification).to receive(:dirs).and_return(homes.map { |home| File.join(home, "specifications") })
  end

  def with_registry(published)
    allow(Kettle::Dev::RubyGemsVersions).to receive(:published_version_numbers) do |name|
      published[name]
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

  it "removes installed versions no registry publishes, including cross-family lockfile gems" do
    Dir.mktmpdir do |home|
      Dir.mktmpdir do |repo|
        lockfile = File.join(repo, "Gemfile.lock")
        File.write(lockfile, <<~LOCK)
          GEM
            remote: https://gem.coop/
            specs:
              sibling (9.8.0)

          PLATFORMS
            ruby

          DEPENDENCIES
            sibling
        LOCK
        alpha = Kettle::Family::Member.new(
          name: "alpha", root: repo, gemspec_path: nil, version_file: nil,
          version: "1.3.0", dependencies: []
        )
        write_installed(home, "alpha", "1.2.0", "1.3.0")
        # A transitive sibling no member declares but a member's lockfile names.
        write_installed(home, "sibling", "9.9.0")
        with_gem_homes([home])
        with_registry("alpha" => ["1.2.0"], "sibling" => ["9.8.0"])
        runner = runner_that_removes(home)

        results = described_class.new(config: config_double, members: [alpha], execute: true, runner: runner).results

        expect(results.length).to eq(1)
        expect(results.last.ok?).to be(true)
        # Unreleased source version and unpublished sibling are gone; the
        # published 1.2.0 install survives.
        expect(File.exist?(File.join(home, "specifications", "alpha-1.3.0.gemspec"))).to be(false)
        expect(File.exist?(File.join(home, "specifications", "sibling-9.9.0.gemspec"))).to be(false)
        expect(File.exist?(File.join(home, "specifications", "alpha-1.2.0.gemspec"))).to be(true)
      end
    end
  end

  it "removes nothing when every installed policed version is published" do
    Dir.mktmpdir do |home|
      alpha = member("alpha", version: "1.2.0")
      allow(File).to receive(:file?).and_call_original
      allow(File).to receive(:file?).with("/repo/alpha/Gemfile.lock").and_return(false)
      write_installed(home, "alpha", "1.2.0")
      with_gem_homes([home])
      with_registry("alpha" => ["1.2.0"])
      runner = runner_that_removes(home)

      results = described_class.new(config: config_double, members: [alpha], execute: true, runner: runner).results

      expect(results).to be_empty
      expect(runner).not_to have_received(:call)
      expect(File.exist?(File.join(home, "specifications", "alpha-1.2.0.gemspec"))).to be(true)
    end
  end

  it "fails open when the registry cannot be consulted" do
    Dir.mktmpdir do |home|
      alpha = member("alpha", version: "1.3.0")
      allow(File).to receive(:file?).and_call_original
      allow(File).to receive(:file?).with("/repo/alpha/Gemfile.lock").and_return(false)
      write_installed(home, "alpha", "1.3.0")
      with_gem_homes([home])
      allow(Kettle::Dev::RubyGemsVersions).to receive(:published_version_numbers).and_return(nil)
      runner = runner_that_removes(home)

      results = described_class.new(config: config_double, members: [alpha], execute: true, runner: runner).results

      expect(results).to be_empty
      expect(runner).not_to have_received(:call)
    end
  end

  it "includes lockfile-named gems among the policed set" do
    Dir.mktmpdir do |home|
      Dir.mktmpdir do |repo|
        lockfile = File.join(repo, "Gemfile.lock")
        File.write(lockfile, <<~LOCK)
          GEM
            remote: https://gem.coop/
            specs:
              locked-dep (2.0.0)

          PLATFORMS
            ruby

          DEPENDENCIES
            locked-dep
        LOCK
        locked_member = Kettle::Family::Member.new(
          name: "alpha", root: repo, gemspec_path: nil, version_file: nil,
          version: "1.2.0", dependencies: []
        )
        write_installed(home, "locked-dep", "2.1.0")
        with_gem_homes([home])
        with_registry("alpha" => ["1.2.0"], "locked-dep" => ["2.0.0"])
        runner = runner_that_removes(home)

        results = described_class.new(config: config_double, members: [locked_member], execute: true, runner: runner).results

        expect(results.last.ok?).to be(true)
        expect(File.exist?(File.join(home, "specifications", "locked-dep-2.1.0.gemspec"))).to be(false)
      end
    end
  end

  def config_double
    instance_double(Kettle::Family::Config, family_name: "test-family", root: "/repo")
  end
end
