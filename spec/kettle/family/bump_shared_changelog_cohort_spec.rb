# frozen_string_literal: true

require "fileutils"
require "open3"
require "stringio"
require "tmpdir"

RSpec.describe Kettle::Family::CLI, :prism do
  around do |example|
    Dir.mktmpdir("kettle-family-shared-bump-spec") do |dir|
      @tmpdir = dir
      example.run
    end
  end

  before do
    Kettle::Family.mise_adapter = build_mise_adapter(executable: "mise")
  end

  it "raises a shared-changelog member with unreleased entries to the next shared version and commits" do
    write_gem("alpha")
    write_gem("beta")
    File.write(File.join(@tmpdir, "CHANGELOG.md"), <<~MD)
      ## [Unreleased]

      ### Fixed

      - shared cohort fix

      ## [1.0.0] - 2026-01-01

      - initial
    MD
    File.write(File.join(@tmpdir, ".kettle-family.yml"), <<~YAML)
      family:
        mode: monorepo
      members:
        roots:
          - alpha
          - beta
      changelog:
        mode: root
        version_file: alpha/lib/alpha/version.rb
    YAML
    initialize_git_repo(@tmpdir)
    stub_release_state(
      "alpha" => {"version" => "1.0.0", "latest_released" => "1.0.0", "unreleased_entries" => true, "bump_release_pending" => true},
      "beta" => {"version" => "1.0.0", "latest_released" => "1.0.0", "unreleased_entries" => true, "bump_release_pending" => true}
    )
    out = StringIO.new

    status = described_class.call(["bump", "patch", "--root", @tmpdir, "--only", "bump", "--execute"], out: out, err: StringIO.new)

    expect(status).to eq(0)
    expect(out.string).to include("alpha bump\n    1.0.0 -> 1.0.1")
    expect(out.string).to include("beta bump\n    1.0.0 -> 1.0.1")
    expect(out.string).to include("alpha commit_version_bump")
    expect(out.string).to include("beta commit_version_bump")
    expect(File.read(File.join(@tmpdir, "alpha", "lib", "alpha", "version.rb"))).to include('VERSION = "1.0.1"')
    expect(File.read(File.join(@tmpdir, "beta", "lib", "beta", "version.rb"))).to include('VERSION = "1.0.1"')
    commits = run_git(@tmpdir, "log", "--format=%s").lines.map(&:strip)
    expect(commits).to include("🔖 Bump gem version")
  end

  it "raises a misaligned shared cohort to the next shared version instead of silently aligning" do
    write_gem("alpha")
    write_gem("beta")
    set_gem_version(File.join(@tmpdir, "beta"), "beta", "0.9.0")
    File.write(File.join(@tmpdir, "CHANGELOG.md"), "## [Unreleased]\n\n### Fixed\n\n- entry\n\n## [1.0.0] - 2026-01-01\n")
    File.write(File.join(@tmpdir, ".kettle-family.yml"), <<~YAML)
      family:
        mode: monorepo
      members:
        roots:
          - alpha
          - beta
      changelog:
        mode: root
        version_file: alpha/lib/alpha/version.rb
    YAML
    initialize_git_repo(@tmpdir)
    # Every member owes the release (unreleased entries, version at the
    # released line); beta additionally sits behind the cohort. The bump
    # must move the whole cohort to the NEXT shared version (1.0.1), not
    # merely align beta to 1.0.0 and report ok — which left the release
    # bump gate uncleared (#17).
    stub_release_state(
      "alpha" => {"version" => "1.0.0", "latest_released" => "1.0.0", "unreleased_entries" => true, "bump_release_pending" => true},
      "beta" => {"version" => "0.9.0", "latest_released" => "0.9.0", "unreleased_entries" => true, "bump_release_pending" => true}
    )
    out = StringIO.new

    status = described_class.call(["bump", "patch", "--root", @tmpdir, "--only", "bump", "--execute", "--no-commit"], out: out, err: StringIO.new)

    expect(status).to eq(0)
    expect(out.string).to include("alpha bump\n    1.0.0 -> 1.0.1")
    expect(out.string).to include("beta bump\n    0.9.0 -> 1.0.1")
    expect(File.read(File.join(@tmpdir, "alpha", "lib", "alpha", "version.rb"))).to include('VERSION = "1.0.1"')
    expect(File.read(File.join(@tmpdir, "beta", "lib", "beta", "version.rb"))).to include('VERSION = "1.0.1"')
  end

  it "aligns a misaligned cohort without state results (explicit selection)" do
    write_gem("alpha")
    write_gem("beta")
    set_gem_version(File.join(@tmpdir, "beta"), "beta", "0.9.0")
    File.write(File.join(@tmpdir, "CHANGELOG.md"), "## [Unreleased]\n")
    File.write(File.join(@tmpdir, ".kettle-family.yml"), <<~YAML)
      family:
        mode: monorepo
      members:
        roots:
          - alpha
          - beta
      changelog:
        mode: root
        version_file: alpha/lib/alpha/version.rb
    YAML
    out = StringIO.new

    status = described_class.call(["bump", "patch", "--root", @tmpdir, "--only", "alpha,beta", "--execute", "--no-commit"], out: out, err: StringIO.new)

    expect(status).to eq(0)
    expect(out.string).to include("alpha bump\n    1.0.0 -> 1.0.0")
    expect(out.string).to include("beta bump\n    0.9.0 -> 1.0.0")
    expect(File.read(File.join(@tmpdir, "beta", "lib", "beta", "version.rb"))).to include('VERSION = "1.0.0"')
  end

  def write_gem(name)
    root = File.join(@tmpdir, name)
    FileUtils.mkdir_p(File.join(root, "lib", name))
    File.write(File.join(root, "lib", name, "version.rb"), <<~RUBY)
      module #{name.capitalize}
        VERSION = "1.0.0"
      end
    RUBY
    File.write(File.join(root, "#{name}.gemspec"), <<~RUBY)
      Gem::Specification.new do |spec|
        spec.name = "#{name}"
        spec.version = "1.0.0"
        spec.summary = "#{name} fixture"
      end
    RUBY
  end

  def set_gem_version(root, name, version)
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

  def initialize_git_repo(path)
    run_git(path, "init", "--quiet")
    run_git(path, "config", "user.email", "kettle-family@example.test")
    run_git(path, "config", "user.name", "Kettle Family")
    run_git(path, "add", ".")
    run_git(path, "commit", "--quiet", "-m", "Initial fixture")
  end

  def run_git(path, *args)
    stdout, stderr, status = Open3.capture3("git", *args, chdir: path)
    raise "git #{args.join(" ")} failed: #{stderr}#{stdout}" unless status.success?

    stdout
  end
end
