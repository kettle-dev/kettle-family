# frozen_string_literal: true

require "fileutils"
require "tmpdir"

RSpec.describe Kettle::Family::VersionBump, :prism do
  around do |example|
    Dir.mktmpdir("kettle-family-version-bump-spec") do |dir|
      @tmpdir = dir
      example.run
    end
  end

  it "reports required changes in check mode" do
    alpha = write_gem("alpha", version: "1.0.0")

    results = described_class.new(members: [alpha], target_version: "1.1.0", mode: :check).results

    expect(results.first).not_to be_ok
    expect(results.first.reason).to eq("version changes required")
    expect(results.first.stdout).to include("would update")
  end

  it "plans required changes in dry-run mode without writing" do
    alpha = write_gem("alpha", version: "1.0.0")

    results = described_class.new(members: [alpha], target_version: "1.1.0").results

    expect(results.first).to be_ok
    expect(results.first.skipped).to be(true)
    expect(File.read(alpha.version_file)).to include('VERSION = "1.0.0"')
  end

  it "updates version constants and exact family dependency pins" do
    alpha = write_gem("alpha", version: "1.0.0")
    beta = write_gem("beta", version: "1.0.0", dependencies: {"alpha" => "= 1.0.0"})

    results = described_class.new(members: [alpha, beta], target_version: "1.1.0", mode: :execute).results

    expect(results).to all(be_ok)
    expect(File.read(alpha.version_file)).to include('VERSION = "1.1.0"')
    expect(File.read(beta.version_file)).to include('VERSION = "1.1.0"')
    expect(File.read(beta.gemspec_path)).to include('"alpha", "= 1.1.0"')
  end

  it "enforces --from versions" do
    alpha = write_gem("alpha", version: "1.0.0")

    expect { described_class.new(members: [alpha], target_version: "1.1.0", from_version: "0.9.0").results }
      .to raise_error(Kettle::Family::Error, /not --from/)
  end

  it "rejects ambiguous family dependency requirements" do
    alpha = write_gem("alpha", version: "1.0.0")
    beta = write_gem("beta", version: "1.0.0", dependencies: {"alpha" => "~> 1.0"})

    expect { described_class.new(members: [alpha, beta], target_version: "1.1.0").results }
      .to raise_error(Kettle::Family::Error, /ambiguous family dependency/)
  end

  it "rejects invalid target versions" do
    alpha = write_gem("alpha", version: "1.0.0")

    expect { described_class.new(members: [alpha], target_version: "not a version").results }
      .to raise_error(Kettle::Family::Error, /invalid version/)
  end

  def write_gem(name, version:, dependencies: {})
    root = File.join(@tmpdir, name)
    FileUtils.mkdir_p(File.join(root, "lib", name.tr("-", "_")))
    version_file = File.join(root, "lib", name.tr("-", "_"), "version.rb")
    File.write(version_file, <<~RUBY)
      module #{camelize(name)}
        VERSION = "#{version}"
      end
    RUBY
    dependency_lines = dependencies.map do |dependency, requirement|
      %(  spec.add_dependency "#{dependency}", "#{requirement}")
    end
    gemspec_path = File.join(root, "#{name}.gemspec")
    File.write(gemspec_path, <<~RUBY)
      Gem::Specification.new do |spec|
        spec.name = "#{name}"
        spec.version = "#{version}"
      #{dependency_lines.join("\n")}
      end
    RUBY
    Kettle::Family::Member.new(
      name: name,
      root: root,
      gemspec_path: gemspec_path,
      version_file: version_file,
      version: version,
      dependencies: dependencies.keys
    )
  end

  def camelize(name)
    name.split("-").map(&:capitalize).join
  end
end
