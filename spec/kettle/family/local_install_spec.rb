# frozen_string_literal: true

require "fileutils"
require "json"
require "tmpdir"

RSpec.describe Kettle::Family::LocalInstall do
  before do
    @tmpdir = Dir.mktmpdir("kettle-family-local-install-spec")
    allow(Dir).to receive(:home).and_return(@tmpdir)
  end

  after do
    FileUtils.remove_entry(@tmpdir) if @tmpdir && Dir.exist?(@tmpdir)
  end

  it "builds and installs local dependencies before selected members and writes the marker" do
    write_gem("alpha", required_ruby_version: ">= 3.2")
    dep_root = File.join(@tmpdir, "deps", "token-resolver")
    dep_gemspec = write_gem_at(dep_root, "token-resolver")
    config = write_config(local_dependencies: [dep_gemspec])
    members = [member_from_root(File.join(@tmpdir, "alpha"))]
    allow_successful_commands

    results = described_class.new(config: config, members: members, execute: true, jobs: 1).results

    expect(results.map(&:member_name)).to eq(["token-resolver", "alpha"])
    expect(results).to all(be_ok)
    expect(results).to all(satisfy { |result| result.skipped == false })
    expect(results.map(&:reason)).to eq([nil, nil])
    marker = JSON.parse(File.read(File.join(@tmpdir, ".kettle-family", "local-install.json")))
    expect(marker.fetch("family")).to eq(File.basename(@tmpdir))
    expect(marker.fetch("local_dependencies")).to eq([dep_gemspec])
    expect(marker.fetch("installed_members")).to eq(["token-resolver", "alpha"])
  end

  it "deduplicates local dependencies that are also selected members" do
    dep_root = File.join(@tmpdir, "deps", "alpha")
    dep_gemspec = write_gem_at(dep_root, "alpha")
    config = write_config(local_dependencies: [dep_gemspec])
    member = member_from_root(dep_root)

    results = described_class.new(config: config, members: [member], execute: false).results

    expect(results.map(&:member_name)).to eq(["alpha"])
    expect(results.first.skipped).to be(true)
  end

  it "stops on build failures and does not write the marker" do
    write_gem("alpha")
    write_gem("beta")
    config = write_config
    members = %w[alpha beta].map { |name| member_from_root(File.join(@tmpdir, name)) }
    failure = instance_double(Process::Status, success?: false, exitstatus: 17)
    allow(Open3).to receive(:capture3).and_return(["", "build failed", failure])

    results = described_class.new(config: config, members: members, execute: true, jobs: 1).results

    expect(results.map(&:member_name)).to eq(["alpha"])
    expect(results.first).not_to be_ok
    expect(results.first.reason).to eq("command failed")
    expect(File).not_to exist(File.join(@tmpdir, ".kettle-family", "local-install.json"))
  end

  it "executes independent selected member installs in parallel when jobs allow it" do
    write_gem("alpha")
    write_gem("beta")
    config = write_config
    members = %w[alpha beta].map { |name| member_from_root(File.join(@tmpdir, name)) }
    installer = described_class.new(config: config, members: members, execute: true, jobs: 2)
    barrier = Queue.new
    release = Queue.new

    allow(installer).to receive(:install_member) do |member|
      barrier << member.name
      release.pop
      successful_result(member)
    end

    worker = Thread.new { installer.results } # rubocop:disable ThreadSafety/NewThread -- this spec verifies parallel install scheduling.
    expect(2.times.map { barrier.pop }.sort).to eq(%w[alpha beta])
    2.times { release << true }
    results = worker.value

    expect(results.map(&:member_name).sort).to eq(%w[alpha beta])
  end

  it "waits for install dependencies before running dependent selected members" do
    write_gem("beta")
    write_gem("alpha", dependencies: ["beta"])
    config = write_config
    members = %w[alpha beta].map { |name| member_from_root(File.join(@tmpdir, name)) }
    installer = described_class.new(config: config, members: members, execute: true, jobs: 2)
    started = Queue.new

    allow(installer).to receive(:install_member) do |member|
      started << member.name
      successful_result(member)
    end

    results = installer.results

    expect(results.map(&:member_name)).to eq(%w[beta alpha])
    expect(2.times.map { started.pop }).to eq(%w[beta alpha])
  end

  it "reports install command failures after a successful build" do
    write_gem("alpha")
    config = write_config
    member = member_from_root(File.join(@tmpdir, "alpha"))
    success = instance_double(Process::Status, success?: true, exitstatus: 0)
    failure = instance_double(Process::Status, success?: false, exitstatus: 42)
    allow(Open3).to receive(:capture3).and_return(
      ["built\n", "", success],
      ["", "install failed\n", failure]
    )

    result = described_class.new(config: config, members: [member], execute: true).results.fetch(0)

    expect(result.member_name).to eq("alpha")
    expect(result.status).to eq(42)
    expect(result.reason).to eq("command failed")
    expect(result.stdout).to eq("built\n")
    expect(result.stderr).to eq("install failed\n")
  end

  it "rejects invalid local dependency paths" do
    config = write_config(local_dependencies: [File.join(@tmpdir, "missing")])

    expect { described_class.new(config: config, members: [], execute: false).results }
      .to raise_error(Kettle::Family::Error, /install local dependency does not exist/)
  end

  it "rejects local dependency directories without one gemspec" do
    empty = File.join(@tmpdir, "empty")
    FileUtils.mkdir_p(empty)
    multiple = File.join(@tmpdir, "multiple")
    FileUtils.mkdir_p(multiple)
    File.write(File.join(multiple, "one.gemspec"), "Gem::Specification.new { |spec| spec.name = 'one' }\n")
    File.write(File.join(multiple, "two.gemspec"), "Gem::Specification.new { |spec| spec.name = 'two' }\n")

    expect { described_class.new(config: write_config(local_dependencies: [empty]), members: [], execute: false).results }
      .to raise_error(Kettle::Family::Error, /no gemspec found/)
    expect { described_class.new(config: write_config(local_dependencies: [multiple]), members: [], execute: false).results }
      .to raise_error(Kettle::Family::Error, /multiple gemspecs found/)
  end

  it "wraps invalid local dependency gemspec load errors" do
    broken = File.join(@tmpdir, "broken")
    FileUtils.mkdir_p(broken)
    File.write(File.join(broken, "broken.gemspec"), "raise 'broken gemspec'\n")

    expect { described_class.new(config: write_config(local_dependencies: [broken]), members: [], execute: false).results }
      .to raise_error(Kettle::Family::Error, /could not load gemspec/)
  end

  def allow_successful_commands
    success = instance_double(Process::Status, success?: true, exitstatus: 0)
    allow(Open3).to receive(:capture3).and_return(["ok\n", "", success])
  end

  def write_config(local_dependencies: [])
    File.write(File.join(@tmpdir, ".kettle-family.yml"), <<~YAML)
      install:
        local_dependencies:
    YAML
    File.open(File.join(@tmpdir, ".kettle-family.yml"), "a") do |file|
      local_dependencies.each { |path| file.puts("          - #{path}") }
    end
    Kettle::Family::Config.load(root: @tmpdir)
  end

  def write_gem(name, required_ruby_version: nil, dependencies: [])
    write_gem_at(File.join(@tmpdir, name), name, required_ruby_version: required_ruby_version, dependencies: dependencies)
  end

  def write_gem_at(root, name, required_ruby_version: nil, dependencies: [])
    FileUtils.mkdir_p(File.join(root, "lib", name))
    File.write(File.join(root, "lib", name, "version.rb"), %(module #{name.split("-").map(&:capitalize).join} ; VERSION = "1.0.0" ; end\n))
    gemspec = File.join(root, "#{name}.gemspec")
    required_ruby_line = required_ruby_version ? %(spec.required_ruby_version = "#{required_ruby_version}") : ""
    dependency_lines = dependencies
      .map { |dependency| %(  spec.add_dependency "#{dependency}") }
      .join("\n")
    File.write(gemspec, <<~RUBY)
      Gem::Specification.new do |spec|
        spec.name = "#{name}"
        spec.version = "1.0.0"
        #{required_ruby_line}
        #{dependency_lines}
      end
    RUBY
    gemspec
  end

  def member_from_root(root)
    gemspec = Dir.glob(File.join(root, "*.gemspec")).fetch(0)
    spec = Gem::Specification.load(gemspec)
    Kettle::Family::Member.new(
      spec.name,
      root,
      gemspec,
      Dir.glob(File.join(root, "lib", "**", "version.rb")).min,
      spec.version.to_s,
      spec.dependencies.map(&:name),
      spec.required_ruby_version.to_s,
      Array(spec.licenses),
      Array(spec.authors)
    )
  end

  def successful_result(member)
    Kettle::Family::CommandResult.new(
      member_name: member.name,
      phase: "install",
      command: ["gem", "install"],
      workdir: member.root,
      status: 0,
      success: true,
      stdout: "",
      stderr: "",
      elapsed_seconds: 0.0,
      skipped: false,
      reason: nil
    )
  end
end
