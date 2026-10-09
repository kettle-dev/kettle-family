# frozen_string_literal: true

require "tmpdir"

# Guarded so appraisals that omit gem_mine skip these specs instead of erroring.
begin
  require "gem_mine"
rescue LoadError
  nil
end

# Regression coverage for the bundle-scoped enumeration bug in clean-unreleased.
#
# These specs install REAL gems into a real isolated GEM_HOME with GemMine
# rather than writing specification files by hand, because the bug is a
# property of how RubyGems behaves under `bundle exec` and can only be
# reproduced by a gem home that RubyGems itself populated. The unit specs in
# spec/kettle/family/unreleased_gem_cleanup_spec.rb assert the candidate logic
# and the specification-filename parsing; these assert that the enumeration is
# not bundle-scoped.
#
# The distinction matters: a spec that stubs Gem::Specification.find_all_by_name
# cannot fail when the implementation stops calling it, so it encodes the buggy
# contract instead of the behaviour. That is exactly how the masking went
# unnoticed while the suite stayed green.
RSpec.describe Kettle::Family::UnreleasedGemCleanup, "installed gem enumeration" do
  # GemMine shells out to `gem build` and `gem install`, which needs those
  # executables available outside the bundle. It guards that itself via
  # Bundler.with_unbundled_env, so the only precondition is gem_mine being
  # installed; the guard keeps the suite passing in appraisals that omit it.
  before do
    skip "gem_mine is not available" unless defined?(GemMine::Scaffold)
  end

  # The gem home is isolated per example and removed afterwards, so the suite
  # never leaves mined-out workspaces behind and never touches the developer's
  # real gem home.
  around do |example|
    Dir.mktmpdir("kettle-family-gem-home-") do |gem_home|
      Dir.mktmpdir("kettle-family-gem-builds-") do |builds|
        @gem_home = gem_home
        @builds = builds
        example.run
      end
    end
  end

  def install_fixture(name, version)
    GemMine.scaffold(
      name,
      root: File.join(@builds, "#{name}-#{version}"),
      version: version,
      gem_home: @gem_home
    )
  end

  def with_fixture_gem_home
    specifications = File.join(@gem_home, "specifications")
    original_dirs = Gem::Specification.dirs
    original_path = Gem.path
    allow(Gem).to receive(:path).and_return([@gem_home])
    allow(Gem::Specification).to receive(:dirs).and_return([specifications])
    yield
  ensure
    allow(Gem).to receive(:path).and_return(original_path)
    allow(Gem::Specification).to receive(:dirs).and_return(original_dirs)
  end

  it "installs fixture gems RubyGems can enumerate from disk" do
    install_fixture("minefix", "1.0.0")
    install_fixture("minefix", "1.0.1")

    written = Dir.glob(File.join(@gem_home, "specifications", "*.gemspec"))
      .map { |path| File.basename(path) }

    expect(written).to contain_exactly("minefix-1.0.0.gemspec", "minefix-1.0.1.gemspec")
  end

  # The regression itself. `minefix` is installed in @gem_home but is not a
  # member of the bundle running this spec, so every bundle-scoped RubyGems API
  # reports nothing for it. Cleanup that trusts those APIs sees zero installed
  # versions and concludes there is nothing to remove -- silently, with outcome
  # success. This is the failure mode observed live on the kettle-dev family,
  # where the tool reported "no unreleased installed versions found" for all 13
  # members while 10 unreleased versions were installed.
  it "sees an installed unreleased version that the active bundle does not resolve" do
    install_fixture("minefix", "1.0.0")
    install_fixture("minefix", "1.0.1")

    with_fixture_gem_home do
      # Establish that the bug's precondition is real: the bundle-scoped API is
      # blind to a genuinely installed gem. If this ever becomes false the
      # regression coverage below has lost its meaning.
      expect(Gem::Specification.find_all_by_name("minefix")).to be_empty

      cleanup = described_class.allocate
      expect(cleanup.send(:installed_versions, "minefix").map(&:to_s))
        .to eq(%w[1.0.0 1.0.1])
    end
  end

  # End to end: only the version newer than the latest release becomes a
  # candidate, and the released version is left installed.
  it "uninstalls only the version newer than the latest release" do
    install_fixture("minefix", "1.0.0")
    install_fixture("minefix", "1.0.1")

    state = Kettle::Family::ReleaseStateResult.new(
      member_name: "minefix",
      command: %w[kettle-changelog --release-state --json],
      workdir: "/repo/minefix",
      status: 0,
      success: true,
      stdout: "",
      stderr: "",
      elapsed_seconds: 0.0,
      state: {"latest_released" => "1.0.0"}
    )
    allow(Kettle::Family::ReleaseStateCheck).to receive(:new)
      .and_return(instance_double(Kettle::Family::ReleaseStateCheck, results: [state]))

    member = Kettle::Family::Member.new(
      name: "minefix",
      root: "/repo/minefix",
      gemspec_path: nil,
      version_file: nil,
      version: "1.0.1",
      dependencies: []
    )

    with_fixture_gem_home do
      result = described_class.new(config: nil, members: [member]).results.first

      expect(result).to be_ok
      expect(result.command).to eq(%w[gem uninstall minefix:1.0.1 --executables])
    end
  end

  # The real uninstall must actually remove the gem from a real gem home, which
  # a synthetic specification file cannot prove. GEM_HOME and GEM_PATH are
  # exported for the duration so the subprocess cannot reach the developer's
  # gem home even if the member is not mise-configured; the member root is the
  # fixture build directory because CommandRunner chdirs into it.
  it "removes the unreleased version from the gem home when executed" do
    install_fixture("minefix", "1.0.0")
    install_fixture("minefix", "1.0.1")

    member_root = File.join(@builds, "minefix-1.0.1")
    state = release_state_for("minefix", "1.0.0")
    allow(Kettle::Family::ReleaseStateCheck).to receive(:new)
      .and_return(instance_double(Kettle::Family::ReleaseStateCheck, results: [state]))

    member = Kettle::Family::Member.new(
      name: "minefix",
      root: member_root,
      gemspec_path: nil,
      version_file: nil,
      version: "1.0.1",
      dependencies: []
    )
    with_fixture_gem_home do
      results = described_class.new(config: nil, members: [member], execute: true, runner: isolated_runner).results
      expect(results.first).to be_ok
    end

    remaining = Dir.glob(File.join(@gem_home, "specifications", "*.gemspec"))
      .map { |path| File.basename(path) }
    expect(remaining).to eq(["minefix-1.0.0.gemspec"])
  end

  # `gem uninstall` resolves its target from GEM_HOME/GEM_PATH, and
  # CommandRunner builds the subprocess environment from
  # Bundler.unbundled_env with unsetenv_others, which drops both. In production
  # that is correct: the ambient gem home is the one being cleaned. Here the
  # fixture lives in an isolated gem home, so the subprocess is pointed at it
  # explicitly rather than changing what the tool does in production.
  def isolated_runner
    gem_home = @gem_home
    Class.new(Kettle::Family::CommandRunner) do
      define_method(:call) do |**kwargs|
        super(**kwargs.merge(env: (kwargs[:env] || {}).merge("GEM_HOME" => gem_home, "GEM_PATH" => gem_home)))
      end
    end.new(execute: true)
  end

  def release_state_for(name, latest_released)
    Kettle::Family::ReleaseStateResult.new(
      member_name: name,
      command: %w[kettle-changelog --release-state --json],
      workdir: "/repo/#{name}",
      status: 0,
      success: true,
      stdout: "",
      stderr: "",
      elapsed_seconds: 0.0,
      state: {"latest_released" => latest_released}
    )
  end
end
