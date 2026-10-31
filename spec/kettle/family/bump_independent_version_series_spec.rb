# frozen_string_literal: true

require "fileutils"
require "open3"
require "stringio"
require "tmpdir"

RSpec.describe Kettle::Family::CLI, :prism do
  around do |example|
    Dir.mktmpdir("kettle-family-independent-series-spec") do |dir|
      @tmpdir = dir
      example.run
    end
  end

  before do
    Kettle::Family.mise_adapter = build_mise_adapter(executable: "mise")
  end

  # The incident shape (#18): a shared-changelog family whose independent
  # member has NO local changelog of its own — everything that would make
  # the lockstep raise capture it — protected only by
  # release.version_series.independent_members.
  def write_family_config(independent_members)
    File.write(File.join(@tmpdir, ".kettle-family.yml"), <<~YAML)
      family:
        mode: monorepo
      members:
        roots:
          - alpha
          - beta
          - indy
      changelog:
        mode: root
        version_file: alpha/lib/alpha/version.rb
      release:
        version_series:
          independent_members:
            #{Array(independent_members).map { |name| "- #{name}" }.join("\n            ")}
    YAML
  end

  def write_shared_changelog
    File.write(File.join(@tmpdir, "CHANGELOG.md"), <<~MD)
      ## [Unreleased]

      ### Fixed

      - shared cohort fix

      ## [1.0.0] - 2026-01-01
    MD
  end

  it "does not capture an independent-series member in the shared-version raise" do
    write_gem("alpha")
    write_gem("beta")
    write_gem("indy", version: "2.0.0")
    write_shared_changelog
    write_family_config(["indy"])
    # Every member's bump gate fires (shared cohort via the root changelog,
    # indy via its own state): indy must move on its OWN series, never to
    # the shared target.
    stub_release_state(
      "alpha" => {"version" => "1.0.0", "latest_released" => "1.0.0", "unreleased_entries" => true, "bump_release_pending" => true},
      "beta" => {"version" => "1.0.0", "latest_released" => "1.0.0", "unreleased_entries" => true, "bump_release_pending" => true},
      "indy" => {"version" => "2.0.0", "latest_released" => "2.0.0", "unreleased_entries" => true, "bump_release_pending" => true}
    )
    out = StringIO.new

    status = described_class.call(["bump", "patch", "--root", @tmpdir, "--only", "bump", "--execute", "--no-commit"], out: out, err: StringIO.new)

    expect(status).to eq(0)
    expect(out.string).to include("alpha bump\n    1.0.0 -> 1.0.1")
    expect(out.string).to include("beta bump\n    1.0.0 -> 1.0.1")
    expect(out.string).to include("indy bump\n    2.0.0 -> 2.0.1")
    expect(File.read(File.join(@tmpdir, "indy", "lib", "indy", "version.rb"))).to include('VERSION = "2.0.1"')
    expect(File.read(File.join(@tmpdir, "alpha", "lib", "alpha", "version.rb"))).to include('VERSION = "1.0.1"')
  end

  it "keeps an independent-series member's higher version out of the shared target computation" do
    write_gem("alpha")
    write_gem("beta")
    write_gem("indy", version: "9.9.9")
    write_shared_changelog
    write_family_config(["indy"])
    stub_release_state(
      "alpha" => {"version" => "1.0.0", "latest_released" => "1.0.0", "unreleased_entries" => true, "bump_release_pending" => true},
      "beta" => {"version" => "1.0.0", "latest_released" => "1.0.0", "unreleased_entries" => true, "bump_release_pending" => true},
      "indy" => {"version" => "9.9.9", "latest_released" => "9.9.9", "unreleased_entries" => false, "bump_release_pending" => false}
    )
    out = StringIO.new

    status = described_class.call(["bump", "patch", "--root", @tmpdir, "--only", "alpha,beta,indy", "--execute", "--no-commit"], out: out, err: StringIO.new)

    expect(status).to eq(0)
    # The shared cohort is raised from its own line (1.0.0 -> 1.0.1); indy's
    # 9.9.9 neither becomes the shared target nor suppresses the raise.
    expect(out.string).to include("alpha bump\n    1.0.0 -> 1.0.1")
    expect(out.string).to include("beta bump\n    1.0.0 -> 1.0.1")
    expect(out.string).to include("indy bump\n    9.9.9 -> 9.9.10")
    expect(out.string).not_to include("1.0.0 -> 9.9.10")
    expect(File.read(File.join(@tmpdir, "alpha", "lib", "alpha", "version.rb"))).to include('VERSION = "1.0.1"')
    expect(File.read(File.join(@tmpdir, "indy", "lib", "indy", "version.rb"))).to include('VERSION = "9.9.10"')
  end

  def write_gem(name, version: "1.0.0")
    root = File.join(@tmpdir, name)
    FileUtils.mkdir_p(File.join(root, "lib", name))
    File.write(File.join(root, "lib", name, "version.rb"), <<~RUBY)
      module #{name.capitalize}
        VERSION = "#{version}"
      end
    RUBY
    File.write(File.join(root, "#{name}.gemspec"), <<~RUBY)
      Gem::Specification.new do |spec|
        spec.name = "#{name}"
        spec.version = "#{version}"
        spec.summary = "#{name} fixture"
      end
    RUBY
  end

  def stub_release_state(states)
    results = states.map do |member_name, state|
      Kettle::Family::ReleaseStateResult.new(
        member_name: member_name,
        command: %w[kettle-changelog --release-state --json],
        workdir: File.join(@tmpdir, member_name),
        status: 0,
        success: true,
        stdout: "",
        stderr: "",
        elapsed_seconds: 0.0,
        state: state
      )
    end
    checker = instance_double(Kettle::Family::ReleaseStateCheck, results: results)
    allow(Kettle::Family::ReleaseStateCheck).to receive(:new).and_return(checker)
  end
end
