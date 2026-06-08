# frozen_string_literal: true

require "fileutils"
require "tmpdir"

RSpec.describe Kettle::Family::Discovery do
  around do |example|
    Dir.mktmpdir("kettle-family-spec") do |dir|
      @tmpdir = dir
      example.run
    end
  end

  it "discovers gemspecs and orders family dependencies first" do
    write_gem("alpha")
    write_gem("beta", dependencies: ["alpha"])

    config = Kettle::Family::Config.load(root: @tmpdir)
    members = described_class.new(config: config).members
    ordered = Kettle::Family::Orderer.new(members: members).ordered

    expect(ordered.map(&:name)).to eq(%w[alpha beta])
  end

  it "applies selection after ordering" do
    write_gem("alpha")
    write_gem("beta", dependencies: ["alpha"])
    write_gem("gamma", dependencies: ["beta"])

    config = Kettle::Family::Config.load(root: @tmpdir)
    members = described_class.new(config: config).members
    ordered = Kettle::Family::Orderer.new(members: members).ordered
    selected = Kettle::Family::Selection.new(members: ordered).apply(start_at: "beta")

    expect(selected.map(&:name)).to eq(%w[beta gamma])
  end

  it "loads explicit members without discovery" do
    write_gem("alpha")
    File.write(File.join(@tmpdir, ".kettle-family.yml"), <<~YAML)
      members:
        discover: false
        explicit:
          - root: alpha
    YAML

    config = Kettle::Family::Config.load(root: @tmpdir)
    members = described_class.new(config: config).members

    expect(members.map(&:name)).to eq(["alpha"])
  end

  it "loads explicit member gemspec paths" do
    root = File.join(@tmpdir, "alpha")
    FileUtils.mkdir_p(root)
    write_gemspec(root, "custom")
    File.write(File.join(@tmpdir, ".kettle-family.yml"), <<~YAML)
      members:
        discover: false
        explicit:
          - root: alpha
            gemspec: custom.gemspec
    YAML

    config = Kettle::Family::Config.load(root: @tmpdir)
    members = described_class.new(config: config).members

    expect(members.map(&:name)).to eq(["custom"])
  end

  it "rejects explicit members without gemspecs" do
    FileUtils.mkdir_p(File.join(@tmpdir, "empty"))
    File.write(File.join(@tmpdir, ".kettle-family.yml"), <<~YAML)
      members:
        discover: false
        explicit:
          - root: empty
    YAML

    config = Kettle::Family::Config.load(root: @tmpdir)

    expect { described_class.new(config: config).members }
      .to raise_error(Kettle::Family::Error, /no gemspec found/)
  end

  it "rejects explicit members with ambiguous gemspecs" do
    root = File.join(@tmpdir, "ambiguous")
    FileUtils.mkdir_p(root)
    write_gemspec(root, "alpha")
    write_gemspec(root, "beta")
    File.write(File.join(@tmpdir, ".kettle-family.yml"), <<~YAML)
      members:
        discover: false
        explicit:
          - root: ambiguous
    YAML

    config = Kettle::Family::Config.load(root: @tmpdir)

    expect { described_class.new(config: config).members }
      .to raise_error(Kettle::Family::Error, /multiple gemspecs/)
  end

  it "rejects duplicate member names from different roots" do
    write_gem("alpha")
    other = File.join(@tmpdir, "other-alpha")
    FileUtils.mkdir_p(other)
    write_gemspec(other, "alpha")
    File.write(File.join(@tmpdir, ".kettle-family.yml"), <<~YAML)
      members:
        explicit:
          - root: other-alpha
    YAML

    config = Kettle::Family::Config.load(root: @tmpdir)

    expect { described_class.new(config: config).members }
      .to raise_error(Kettle::Family::Error, /duplicate family member/)
  end

  it "wraps gemspec load failures" do
    root = File.join(@tmpdir, "broken")
    FileUtils.mkdir_p(root)
    File.write(File.join(root, "broken.gemspec"), "raise 'broken gemspec'\n")

    config = Kettle::Family::Config.load(root: @tmpdir)

    expect { described_class.new(config: config).members }
      .to raise_error(Kettle::Family::Error, /could not load gemspec/)
  end

  def write_gem(name, dependencies: [])
    root = File.join(@tmpdir, name)
    FileUtils.mkdir_p(root)
    write_gemspec(root, name, dependencies: dependencies)
  end

  def write_gemspec(root, name, dependencies: [])
    dependency_lines = dependencies.map do |dependency|
      %(  spec.add_dependency "#{dependency}", "= 1.0.0")
    end
    File.write(File.join(root, "#{name}.gemspec"), <<~RUBY)
      Gem::Specification.new do |spec|
        spec.name = "#{name}"
        spec.version = "1.0.0"
      #{dependency_lines.join("\n")}
      end
    RUBY
  end
end
