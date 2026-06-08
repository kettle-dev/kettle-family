# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "stringio"
require "tmpdir"

RSpec.describe Kettle::Family::CLI do
  around do |example|
    Dir.mktmpdir("kettle-family-cli-spec") do |dir|
      @tmpdir = dir
      example.run
    end
  end

  it "prints a JSON discovery report" do
    write_gem("alpha")
    out = StringIO.new
    err = StringIO.new

    status = described_class.call(["discover", "--root", @tmpdir, "--json"], out: out, err: err)

    expect(status).to eq(0)
    expect(err.string).to eq("")
    report = JSON.parse(out.string)
    expect(report.fetch("family")).to eq(File.basename(@tmpdir))
    expect(report.fetch("selected_members")).to eq(["alpha"])
  end

  it "writes JSON reports without forcing JSON stdout" do
    write_gem("alpha")
    out = StringIO.new
    report_path = File.join(@tmpdir, "tmp", "family-report.json")

    status = described_class.call(["plan", "--root", @tmpdir, "--report", report_path], out: out, err: StringIO.new)

    expect(status).to eq(0)
    expect(out.string).to include("family:")
    expect(JSON.parse(File.read(report_path)).fetch("selected_members")).to eq(["alpha"])
  end

  it "prints help" do
    out = StringIO.new

    status = described_class.call(["help"], out: out, err: StringIO.new)

    expect(status).to eq(0)
    expect(out.string).to include("Usage: kettle-family")
  end

  it "rejects unknown commands" do
    err = StringIO.new

    status = described_class.call(["unknown"], out: StringIO.new, err: err)

    expect(status).to eq(1)
    expect(err.string).to include("unknown command")
  end

  it "rejects invalid options" do
    err = StringIO.new

    status = described_class.call(["discover", "--bad"], out: StringIO.new, err: err)

    expect(status).to eq(1)
    expect(err.string).to include("invalid option")
  end

  it "runs through the executable entrypoint" do
    write_gem("alpha")

    stdout, stderr, status = Open3.capture3(
      RbConfig.ruby,
      "-Ilib",
      "exe/kettle-family",
      "discover",
      "--root",
      @tmpdir,
      "--json"
    )

    expect(status).to be_success
    expect(stderr).to eq("")
    expect(JSON.parse(stdout).fetch("selected_members")).to eq(["alpha"])
  end

  it "plans workflow commands by default" do
    write_gem("alpha")
    out = StringIO.new

    status = described_class.call(["test", "--root", @tmpdir], out: out, err: StringIO.new)

    expect(status).to eq(0)
    expect(out.string).to include("skipped alpha test")
    expect(out.string).to include("pass --execute")
  end

  it "returns failure status for readiness check failures" do
    write_gem("alpha")
    out = StringIO.new

    status = described_class.call(["check", "--root", @tmpdir], out: out, err: StringIO.new)

    expect(status).to eq(1)
    expect(out.string).to include("failed alpha check")
    expect(out.string).to include("resume: kettle-family check --start-at alpha")
  end

  it "plans template commands with family commit" do
    write_gem("alpha")
    out = StringIO.new

    status = described_class.call(["template", "--root", @tmpdir, "--commit"], out: out, err: StringIO.new)

    expect(status).to eq(0)
    expect(out.string).to include("skipped alpha template")
    expect(out.string).to include("skipped #{File.basename(@tmpdir)} family_commit")
  end

  it "checks version bumps without writing" do
    write_gem("alpha")
    out = StringIO.new

    status = described_class.call(["bump-version", "1.1.0", "--root", @tmpdir, "--check"], out: out, err: StringIO.new)

    expect(status).to eq(1)
    expect(out.string).to include("failed alpha bump-version")
    expect(out.string).to include("version changes required")
  end

  it "plans releases in fixed configured order" do
    write_ready_gem("alpha")
    write_ready_gem("beta")
    File.write(File.join(@tmpdir, ".kettle-family.yml"), <<~YAML)
      members:
        order:
          mode: fixed
          hints:
            - beta
            - alpha
    YAML
    out = StringIO.new

    status = described_class.call(["release", "--root", @tmpdir], out: out, err: StringIO.new)

    expect(status).to eq(0)
    expect(out.string.index("* beta")).to be < out.string.index("* alpha")
    expect(out.string).to include("skipped beta release_build")
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
      end
    RUBY
  end

  def write_ready_gem(name)
    write_gem(name)
    root = File.join(@tmpdir, name)
    FileUtils.mkdir_p(File.join(root, "bin"))
    %w[Gemfile Rakefile README.md LICENSE.md].each do |path|
      File.write(File.join(root, path), "stub\n")
    end
    File.write(File.join(root, "CHANGELOG.md"), "## [Unreleased]\n")
    %w[bin/rake bin/rspec].each do |path|
      full_path = File.join(root, path)
      File.write(full_path, "#!/bin/sh\n")
      FileUtils.chmod("u+x", full_path)
    end
  end
end
