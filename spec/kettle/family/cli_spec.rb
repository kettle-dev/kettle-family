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

  def write_gem(name)
    root = File.join(@tmpdir, name)
    FileUtils.mkdir_p(root)
    File.write(File.join(root, "#{name}.gemspec"), <<~RUBY)
      Gem::Specification.new do |spec|
        spec.name = "#{name}"
        spec.version = "1.0.0"
      end
    RUBY
  end
end
