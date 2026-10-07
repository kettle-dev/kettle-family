# frozen_string_literal: true

require "fileutils"
require "tmpdir"

RSpec.describe Kettle::Family::PublishedVersionCheck do
  around do |example|
    Dir.mktmpdir("kettle-family-published-version-spec") do |dir|
      @tmpdir = dir
      # REGISTRY_MEMO is process-global mutable state; each example stubs the
      # registry differently, so leaking answers between examples would make
      # these specs order-dependent.
      described_class::REGISTRY_MEMO.clear
      example.run
      described_class::REGISTRY_MEMO.clear
    end
  end

  # The release marker is real on-disk state this machine accumulates from every
  # release ever run here (74 entries at last count), and recently_released?
  # reads it. Stubbing it keeps these specs hermetic instead of changing
  # behavior depending on what happens to be marked locally. Examples that
  # exercise the marker override this with their own stub.
  #
  # This is a `before` rather than part of the `around` hook because RSpec only
  # makes the mocking framework available to examples and before/after hooks.
  before do
    allow(Kettle::Dev::RubyGemsVersions).to receive(:recently_released?).and_return(false)
  end

  # A locally built and installed gem resolves during an ordinary
  # `bundle install` and lands in the lockfile as a normal GEM entry with a
  # valid checksum taken from the installed spec, so nothing about the lockfile
  # text reveals it. Only asking the registry can tell.
  def write_gem_lockfile(member, name: "demo-gem", version: "9.9.9", remote: "https://gem.coop/")
    File.write(
      File.join(member.root, "Gemfile.lock"),
      <<~LOCK
        GEM
          remote: #{remote}
          specs:
            #{name} (#{version})

        DEPENDENCIES
          #{name}
      LOCK
    )
  end

  def stub_registry(published_versions_by_name)
    allow(Kettle::Dev::RubyGemsVersions).to receive(:published_version_numbers) do |name, **_opts|
      published_versions_by_name.fetch(name) { raise "unexpected registry query for #{name}" }
    end
  end

  it "reports a pinned version the registry does not serve" do
    member = member_at("alpha")
    write_gem_lockfile(member, version: "9.9.9")
    stub_registry("demo-gem" => %w[1.0.0 1.1.0])

    result = described_class.call(member: member)

    expect(result).not_to be_ok
    expect(result.stdout).to include(
      "release lockfile pins demo-gem 9.9.9, which is not published on https://gem.coop/"
    )
    expect(result.reason).to eq("lockfile pins versions no registry serves")
    expect(result.phase).to eq("published_version_check")
  end

  it "passes when every pinned version is published" do
    member = member_at("alpha")
    write_gem_lockfile(member, version: "1.1.0")
    stub_registry("demo-gem" => %w[1.0.0 1.1.0])

    result = described_class.call(member: member)

    expect(result).to be_ok
    expect(result.stdout).to eq("")
    expect(result.reason).to be_nil
  end

  it "queries the remote recorded in the lockfile, not a hardcoded registry" do
    member = member_at("alpha")
    write_gem_lockfile(member, version: "1.0.0", remote: "https://gems.example.test/")
    requested_sources = []
    allow(Kettle::Dev::RubyGemsVersions).to receive(:published_version_numbers) do |_name, source:, **_opts|
      requested_sources << source
      ["1.0.0"]
    end

    described_class.call(member: member)

    # Passed through exactly as the lockfile recorded it; RubyGemsVersions
    # normalizes the trailing slash before building the request URI.
    expect(requested_sources).to eq(["https://gems.example.test/"])
  end

  it "reports each unpublished gem when a lockfile pins several" do
    member = member_at("alpha")
    File.write(
      File.join(member.root, "Gemfile.lock"),
      <<~LOCK
        GEM
          remote: https://gem.coop/
          specs:
            alpha-gem (9.9.9)
            beta-gem (8.8.8)
            gamma-gem (1.0.0)
      LOCK
    )
    stub_registry(
      "alpha-gem" => ["1.0.0"],
      "beta-gem" => ["1.0.0"],
      "gamma-gem" => ["1.0.0"]
    )

    result = described_class.call(member: member)

    expect(result).not_to be_ok
    expect(result.stdout).to include("pins alpha-gem 9.9.9")
    expect(result.stdout).to include("pins beta-gem 8.8.8")
    expect(result.stdout).not_to include("gamma-gem")
  end

  # Failing open is load-bearing: a registry outage must not turn every member
  # of a family release into a false failure.
  it "fails open when the registry cannot be consulted" do
    member = member_at("alpha")
    write_gem_lockfile(member, version: "9.9.9")
    allow(Kettle::Dev::RubyGemsVersions).to receive(:published_version_numbers).and_return(nil)

    result = described_class.call(member: member)

    expect(result).to be_ok
    expect(result.stdout).to be_empty
  end

  # Distinct from the fail-open case above: a reachable registry that answers
  # with no versions proves the pin is unpublished, so this must fail.
  it "reports a pin when the registry is reachable but serves no versions" do
    member = member_at("alpha")
    write_gem_lockfile(member, version: "9.9.9")
    stub_registry("demo-gem" => [])

    expect(described_class.call(member: member)).not_to be_ok
  end

  it "ignores entries in a GEM section that records no remote" do
    member = member_at("alpha")
    File.write(File.join(member.root, "Gemfile.lock"), <<~LOCK)
      GEM
        specs:
          demo-gem (9.9.9)
    LOCK
    allow(Kettle::Dev::RubyGemsVersions).to receive(:published_version_numbers)

    result = described_class.call(member: member)

    expect(result).to be_ok
    expect(Kettle::Dev::RubyGemsVersions).not_to have_received(:published_version_numbers)
  end

  # PATH and GIT sources are covered by ReadinessCheck's local-path remote
  # detection; a git-sourced version is legitimately unpublished.
  it "ignores GIT sources" do
    member = member_at("alpha")
    File.write(File.join(member.root, "Gemfile.lock"), <<~LOCK)
      GIT
        remote: https://github.com/example/demo.git
        revision: abc123
        specs:
          demo-gem (9.9.9)

      PLATFORMS
        ruby
    LOCK
    allow(Kettle::Dev::RubyGemsVersions).to receive(:published_version_numbers)

    result = described_class.call(member: member)

    expect(result).to be_ok
    expect(Kettle::Dev::RubyGemsVersions).not_to have_received(:published_version_numbers)
  end

  it "passes when the member has no lockfile" do
    member = member_at("alpha")
    allow(Kettle::Dev::RubyGemsVersions).to receive(:published_version_numbers)

    result = described_class.call(member: member)

    expect(result).to be_ok
    expect(Kettle::Dev::RubyGemsVersions).not_to have_received(:published_version_numbers)
  end

  # Family members share nearly all toolchain and sibling dependencies, so the
  # process memo is what keeps a 30-member release from re-querying the same
  # gems 30 times (recently released ones deliberately cache-bust on disk).
  it "queries the registry once per gem and remote across repeated checks" do
    member = member_at("alpha")
    write_gem_lockfile(member, version: "1.0.0")
    queries = []
    allow(Kettle::Dev::RubyGemsVersions).to receive(:published_version_numbers) do |name, source:, **_opts|
      queries << [name, source]
      ["1.0.0"]
    end

    3.times { described_class.call(member: member) }

    expect(queries).to eq([["demo-gem", "https://gem.coop/"]])
  end

  it "asks the registry once per distinct gem when it is unreachable" do
    member = member_at("alpha")
    File.write(
      File.join(member.root, "Gemfile.lock"),
      <<~LOCK
        GEM
          remote: https://gem.coop/
          specs:
            alpha-gem (9.9.9)
            beta-gem (8.8.8)
      LOCK
    )
    queries = 0
    allow(Kettle::Dev::RubyGemsVersions).to receive(:published_version_numbers) do
      queries += 1
      nil
    end

    expect(described_class.call(member: member)).to be_ok
    expect(queries).to eq(2) # one per distinct gem, not per retry
  end

  # A release publishes a gem mid-run and then raises its dependents' floors to
  # it. If the memo answered from a pre-publish query, the freshly released
  # version would be reported unpublished and block a legitimate release. The
  # on-disk marker kettle-release writes after publishing must win over the memo.
  it "bypasses the memo when the release marker says that version was just published" do
    member = member_at("alpha")
    write_gem_lockfile(member, version: "1.1.0")
    allow(Kettle::Dev::RubyGemsVersions).to receive(:recently_released?)
      .with("demo-gem", "1.1.0").and_return(false, true)
    published = [["1.0.0"], %w[1.0.0 1.1.0]]
    queries = []
    allow(Kettle::Dev::RubyGemsVersions).to receive(:published_version_numbers) do |name, **opts|
      queries << [name, opts[:source], opts[:version]]
      published[queries.size - 1] || []
    end

    expect(described_class.call(member: member)).not_to be_ok # pre-publish
    expect(described_class.call(member: member)).to be_ok # post-publish

    expect(queries.size).to eq(2) # memo was not served the stale answer
  end

  it "passes the pinned version through to the registry query" do
    member = member_at("alpha")
    write_gem_lockfile(member, version: "2.3.4")
    versions = []
    allow(Kettle::Dev::RubyGemsVersions).to receive(:published_version_numbers) do |_name, **opts|
      versions << opts[:version]
      %w[2.3.4]
    end

    described_class.call(member: member)

    expect(versions).to eq(["2.3.4"])
  end

  # The marker records a bare version, so a platform-suffixed pin must be
  # normalized before asking, or the marker would never match a native gem.
  it "asks the marker with the platform suffix already stripped" do
    member = member_at("alpha")
    write_gem_lockfile(member, name: "nokogiri", version: "1.19.4-x86_64-linux-gnu")
    hints = []
    allow(Kettle::Dev::RubyGemsVersions).to receive(:recently_released?) do |name, version|
      hints << [name, version]
      false
    end
    stub_registry("nokogiri" => ["1.19.4"])

    described_class.call(member: member)

    expect(hints).to eq([["nokogiri", "1.19.4"]])
  end

  it "still answers from the memo when the marker says nothing was just published" do
    member = member_at("alpha")
    write_gem_lockfile(member, version: "1.0.0")
    allow(Kettle::Dev::RubyGemsVersions).to receive(:recently_released?).and_return(false)
    queries = 0
    allow(Kettle::Dev::RubyGemsVersions).to receive(:published_version_numbers) do
      queries += 1
      ["1.0.0"]
    end

    3.times { described_class.call(member: member) }

    expect(queries).to eq(1)
  end

  it "does not ask the marker when the pin has no version" do
    member = member_at("alpha")
    allow(Kettle::Dev::RubyGemsVersions).to receive(:recently_released?).and_raise("should not be called")
    stub_registry("demo-gem" => ["1.0.0"])

    check = described_class.new(member: member)

    expect(check.send(:just_released?, "demo-gem", nil)).to be(false)
    expect(check.send(:just_released?, "demo-gem", "")).to be(false)
  end

  it "treats a marker read failure as not just released" do
    allow(Kettle::Dev::RubyGemsVersions).to receive(:recently_released?)
      .and_raise(Errno::EACCES, "permission denied")

    check = described_class.new(member: member_at("alpha"))

    expect(check.send(:just_released?, "demo-gem", "1.0.0")).to be(false)
  end

  # A lockfile pins a native gem as "1.19.4-x86_64-linux-gnu" while the
  # registry lists bare "1.19.4" once per platform. Comparing the pinned string
  # directly reported every native gem as unpublished — nokogiri and
  # tree_sitter_language_pack alone added 10 false positives to one real
  # lockfile — so the platform suffix must be split off before comparing.
  it "does not report a published native gem whose pin carries a platform suffix" do
    member = member_at("alpha")
    write_gem_lockfile(member, name: "nokogiri", version: "1.19.4-x86_64-linux-gnu")
    stub_registry("nokogiri" => ["1.19.4"])

    result = described_class.call(member: member)

    expect(result).to be_ok
  end

  it "still reports an unpublished native gem whose pin carries a platform suffix" do
    member = member_at("alpha")
    write_gem_lockfile(member, name: "nokogiri", version: "9.9.9-x86_64-linux-gnu")
    stub_registry("nokogiri" => ["1.19.4"])

    result = described_class.call(member: member)

    expect(result).not_to be_ok
    expect(result.stdout).to include("pins nokogiri 9.9.9-x86_64-linux-gnu")
  end

  it "does not report a published java-platform gem" do
    member = member_at("alpha")
    write_gem_lockfile(member, name: "json", version: "2.7.2-java")
    stub_registry("json" => ["2.7.2"])

    expect(described_class.call(member: member)).to be_ok
  end

  # A prerelease version uses dots, not a hyphen, so platform stripping must
  # not truncate it.
  it "does not truncate a prerelease version" do
    member = member_at("alpha")
    write_gem_lockfile(member, name: "demo-gem", version: "1.0.0.rc1")
    stub_registry("demo-gem" => ["1.0.0.rc1"])

    expect(described_class.call(member: member)).to be_ok
  end

  def member_at(name)
    root = File.join(@tmpdir, name)
    FileUtils.mkdir_p(root)
    Kettle::Family::Member.new(
      name: name,
      root: root,
      gemspec_path: File.join(root, "#{name}.gemspec"),
      version: "1.0.0",
      dependencies: []
    )
  end
end
