# frozen_string_literal: true

require "fileutils"
require "open3"
require "tmpdir"
require "webrick"

RSpec.describe Kettle::Family::ExecutionProfile do
  it "defines each supported execution context without an implicit fallback" do
    expect(described_class::DEFINITIONS.keys).to contain_exactly(
      :development_local,
      :template_local,
      :release_bootstrap,
      :release_registry,
      :release_monorepo,
      :release_recovery
    )
    expect { described_class.fetch(:unknown) }.to raise_error(ArgumentError, /unknown execution profile/)
  end

  it "requires a host-installable dependency graph for every profile" do
    described_class::DEFINITIONS.each_value do |profile|
      expect(profile.host_platform_policy).to eq(:active_platform_must_resolve)
    end
  end

  it "exposes path-gem and canonical-lockfile policy predicates" do
    expect(described_class.fetch(:development_local)).to be_local_path_gems
    expect(described_class.fetch("template_local")).to be_canonical_lockfile
    expect(described_class.fetch(:release_bootstrap)).to be_local_path_gems
    expect(described_class.fetch(:release_bootstrap).lockfile_role).to eq(:tool)
    expect(described_class.fetch(:release_monorepo)).to be_local_path_gems
    expect(described_class.fetch(:release_registry)).not_to be_local_path_gems
    expect(described_class.fetch(:release_registry)).to be_canonical_lockfile
  end

  it "resolves configured unpublished siblings through real Bundler commands" do
    Dir.mktmpdir("kettle-family-profile-scenario", File.join(Dir.pwd, "tmp")) do |root|
      write_path_gem(root, "alpha", "Alpha")
      write_path_gem(root, "beta", "Beta", dependency: "alpha")
      write_file(root, "Gemfile", <<~RUBY)
        source "https://rubygems.org"
        gem "alpha", path: "gems/alpha"
        gem "beta", path: "gems/beta"
      RUBY

      lockfile = File.join(root, "Gemfile.lock")
      run_bundle(root, lockfile, "lock", "--local")
      canonical_lock = File.binread(lockfile)

      run_bundle(root, lockfile, "install", "--local")
      stdout = run_bundle(root, lockfile, "exec", "ruby", "-e", 'require "alpha"; require "beta"; puts Alpha::VALUE + "-" + Beta::VALUE').fetch(:stdout)

      expect(stdout).to eq("alpha-beta\n")
      expect(File.binread(lockfile)).to eq(canonical_lock)
    end
  end

  it "boots a registry-only release graph from a disposable lock without mutating the canonical lock" do
    Dir.mktmpdir("kettle-family-release-profile-scenario", File.join(Dir.pwd, "tmp")) do |root|
      write_path_gem(root, "registry_fixture", "RegistryFixture")
      with_local_gem_server(create_local_gem_repository(root, "registry_fixture")) do |source|
        write_file(root, "Gemfile", <<~RUBY)
          source #{source.inspect}
          gem "registry_fixture", "1.0.0"
        RUBY

        canonical_lock = File.join(root, "Gemfile.lock")
        run_bundle(root, canonical_lock, "lock")
        canonical_contents = File.binread(canonical_lock)
        expect(canonical_contents).not_to include("PATH\n")

        disposable_lock = File.join(root, "tmp", "release", "Gemfile.lock")
        FileUtils.mkdir_p(File.dirname(disposable_lock))
        FileUtils.cp(canonical_lock, disposable_lock)
        initial_boot = run_bundle(
          root,
          disposable_lock,
          "exec",
          "ruby",
          "-e",
          'require "registry_fixture"',
          expect_success: false
        )
        expect(initial_boot.fetch(:status)).not_to be_success

        run_bundle(root, disposable_lock, "install", extra_env: {"BUNDLE_FROZEN" => "true"})
        stdout = run_bundle(
          root,
          disposable_lock,
          "exec",
          "ruby",
          "-e",
          'require "registry_fixture"; puts RegistryFixture::VALUE'
        ).fetch(:stdout)

        expect(stdout).to eq("registry_fixture\n")
        expect(File.binread(canonical_lock)).to eq(canonical_contents)
      end
    end
  end

  def write_path_gem(root, name, constant, dependency: nil)
    gem_root = File.join(root, "gems", name)
    write_file(gem_root, "lib/#{name}.rb", <<~RUBY)
      module #{constant}
        VALUE = #{name.inspect}
      end
    RUBY
    dependency_line = dependency ? "  spec.add_dependency #{dependency.inspect}, \">= 0\"\n" : ""
    write_file(gem_root, "#{name}.gemspec", <<~RUBY)
      Gem::Specification.new do |spec|
        spec.name = #{name.inspect}
        spec.version = "1.0.0"
        spec.summary = "fixture"
        spec.authors = ["Kettle"]
        spec.files = ["lib/#{name}.rb"]
        spec.require_paths = ["lib"]
      #{dependency_line}end
    RUBY
  end

  def write_file(root, relative_path, content)
    path = File.join(root, relative_path)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
  end

  def create_local_gem_repository(root, name)
    gem_root = File.join(root, "gems", name)
    stdout, stderr, status = Open3.capture3("gem", "build", "#{name}.gemspec", chdir: gem_root)
    expect(status).to be_success, "gem build failed:\n#{stdout}\n#{stderr}"

    repository = File.join(root, "gem-repository")
    FileUtils.mkdir_p(File.join(repository, "gems"))
    gem_path = File.join(gem_root, "#{name}-1.0.0.gem")
    FileUtils.cp(gem_path, File.join(repository, "gems"))
    stdout, stderr, status = Open3.capture3("gem", "generate_index", "--directory", repository)
    expect(status).to be_success, "gem generate_index failed:\n#{stdout}\n#{stderr}"
    repository
  end

  def with_local_gem_server(repository)
    server = WEBrick::HTTPServer.new(
      BindAddress: "127.0.0.1",
      Port: 0,
      DocumentRoot: repository,
      Logger: WEBrick::Log.new(File::NULL),
      AccessLog: []
    )
    # rubocop:disable ThreadSafety/NewThread -- a real local registry requires a concurrent HTTP server.
    thread = Thread.new { server.start }
    # rubocop:enable ThreadSafety/NewThread
    port = server.listeners.first.addr.fetch(1)
    yield "http://127.0.0.1:#{port}/"
  ensure
    server&.shutdown
    thread&.join
  end

  def run_bundle(root, lockfile, *args, expect_success: true, extra_env: {})
    reset_bundler_environment = ENV.keys.grep(/\A(?:BUNDLE|BUNDLER)(?:_|\z)/).to_h { |key| [key, nil] }
    reset_bundler_environment["RUBYLIB"] = nil
    reset_bundler_environment["RUBYOPT"] = nil
    stdout, stderr, status = Open3.capture3(
      reset_bundler_environment.merge(
        "BUNDLE_GEMFILE" => File.join(root, "Gemfile"),
        "BUNDLE_LOCKFILE" => lockfile,
        "BUNDLE_PATH" => File.join(root, "tmp", "bundle")
      ).merge(extra_env),
      "bundle",
      *args,
      chdir: root
    )
    if expect_success
      expect(status).to be_success, "bundle #{args.join(" ")} failed:\n#{stdout}\n#{stderr}"
    end
    {stdout: stdout, stderr: stderr, status: status}
  end
end
