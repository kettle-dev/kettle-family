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

  it "ignores development dependencies for family ordering" do
    write_gem("alpha")
    write_gem("beta", development_dependencies: ["alpha"])

    config = Kettle::Family::Config.load(root: @tmpdir)
    member = described_class.new(config: config).members.find { |candidate| candidate.name == "beta" }

    expect(member.dependencies).to be_empty
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

  it "captures version, Ruby floor, license, and author metadata from gemspecs" do
    root = File.join(@tmpdir, "alpha")
    FileUtils.mkdir_p(root)
    File.write(File.join(root, "alpha.gemspec"), <<~RUBY)
      Gem::Specification.new do |spec|
        spec.name = "alpha"
        spec.version = "1.2.3"
        spec.required_ruby_version = ">= 3.2"
        spec.licenses = ["MIT"]
        spec.authors = ["Example Author"]
      end
    RUBY

    config = Kettle::Family::Config.load(root: @tmpdir)
    member = described_class.new(config: config).members.fetch(0)

    expect(member.version).to eq("1.2.3")
    expect(member.required_ruby_version).to eq(">= 3.2")
    expect(member.licenses).to eq(["MIT"])
    expect(member.authors).to eq(["Example Author"])
    expect(member.to_h).to include(
      "required_ruby_version" => ">= 3.2",
      "licenses" => ["MIT"],
      "authors" => ["Example Author"]
    )
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

  it "excludes discovered gemspecs with configured glob patterns before loading members" do
    write_gem("alpha")
    write_gem("beta")
    write_gemspec(File.join(@tmpdir, "beta", "custom", "fixture"), "alpha")
    File.write(File.join(@tmpdir, ".kettle-family.yml"), <<~YAML)
      members:
        exclude:
          - "**/custom/**"
    YAML

    config = Kettle::Family::Config.load(root: @tmpdir)
    members = described_class.new(config: config).members

    expect(members.map(&:name)).to eq(%w[alpha beta])
  end

  it "excludes default test fixture gemspecs before loading members" do
    write_gem("alpha")
    write_gem("beta")
    write_gemspec(File.join(@tmpdir, "beta", "spec", "support", "fixtures"), "alpha")

    config = Kettle::Family::Config.load(root: @tmpdir)
    members = described_class.new(config: config).members

    expect(members.map(&:name)).to eq(%w[alpha beta])
  end

  it "excludes default top-level vendored gemspecs before loading members" do
    write_gem("alpha")
    write_gemspec(File.join(@tmpdir, "vendor", "fixture"), "vendored")

    config = Kettle::Family::Config.load(root: @tmpdir)
    members = described_class.new(config: config).members

    expect(members.map(&:name)).to eq(["alpha"])
  end

  it "loads discovered gemspecs from their own directory" do
    root = File.join(@tmpdir, "relative-load")
    FileUtils.mkdir_p(File.join(root, "lib", "relative"))
    File.write(File.join(root, "lib", "relative", "version.rb"), <<~RUBY)
      module Relative
        VERSION = "1.0.0"
      end
    RUBY
    File.write(File.join(root, "relative-load.gemspec"), <<~RUBY)
      Kernel.load "lib/relative/version.rb"
      Gem::Specification.new do |spec|
        spec.name = "relative-load"
        spec.version = Relative::VERSION
      end
    RUBY

    config = Kettle::Family::Config.load(root: @tmpdir)
    members = described_class.new(config: config).members

    expect(members.map(&:name)).to eq(["relative-load"])
  end

  it "excludes gemspecs ignored by git before loading members" do
    system("git", "init", "--quiet", chdir: @tmpdir)
    write_gem("alpha")
    write_gem("beta")
    write_gemspec(File.join(@tmpdir, "beta", "tmp", "fixture"), "alpha")
    File.write(File.join(@tmpdir, ".gitignore"), "tmp/\n")

    config = Kettle::Family::Config.load(root: @tmpdir)
    members = described_class.new(config: config).members

    expect(members.map(&:name)).to eq(%w[alpha beta])
  end

  it "wraps gemspec load failures" do
    root = File.join(@tmpdir, "broken")
    FileUtils.mkdir_p(root)
    File.write(File.join(root, "broken.gemspec"), "raise 'broken gemspec'\n")

    config = Kettle::Family::Config.load(root: @tmpdir)

    expect { described_class.new(config: config).members }
      .to raise_error(Kettle::Family::Error, /could not load gemspec/)
  end

  def write_gem(name, dependencies: [], development_dependencies: [])
    root = File.join(@tmpdir, name)
    FileUtils.mkdir_p(root)
    write_gemspec(root, name, dependencies: dependencies, development_dependencies: development_dependencies)
  end

  def write_gemspec(root, name, dependencies: [], development_dependencies: [])
    FileUtils.mkdir_p(root)
    dependency_lines = dependencies.map do |dependency|
      %(  spec.add_dependency "#{dependency}", "= 1.0.0")
    end
    development_dependency_lines = development_dependencies.map do |dependency|
      %(  spec.add_development_dependency "#{dependency}", "= 1.0.0")
    end
    File.write(File.join(root, "#{name}.gemspec"), <<~RUBY)
      Gem::Specification.new do |spec|
        spec.name = "#{name}"
        spec.version = "1.0.0"
      #{dependency_lines.join("\n")}
      #{development_dependency_lines.join("\n")}
      end
    RUBY
  end
end
