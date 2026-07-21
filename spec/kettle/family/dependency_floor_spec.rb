# frozen_string_literal: true

require "fileutils"
require "tmpdir"
require "kettle/family/dependency_floor"

RSpec.describe Kettle::Family::DependencyFloor, :prism do
  around do |example|
    Dir.mktmpdir("kettle-family-dependency-floor-spec") do |dir|
      @tmpdir = dir
      example.run
    end
  end

  it "raises runtime dependency floors for released family members" do
    alpha = write_gem("alpha", version: "1.2.3")
    beta = write_gem("beta", version: "2.0.0", dependencies: {"alpha" => ["~> 1.0", ">= 1.0.0"]})

    results = described_class.new(released_members: [alpha], dependent_members: [beta], mode: :execute).results

    expect(results).to all(be_ok)
    expect(results.first.phase).to eq("dependency_floor")
    expect(File.read(beta.gemspec_path)).to include('"alpha", "~> 1.0", ">= 1.2.3"')
  end

  it "raises development dependency floors for released family members" do
    alpha = write_gem("alpha", version: "1.2.3")
    beta = write_gem("beta", version: "2.0.0", dependencies: {"alpha" => ["~> 1.0", ">= 1.0.0"]}, dependency_method: "add_development_dependency")

    results = described_class.new(released_members: [alpha], dependent_members: [beta], mode: :execute).results

    expect(results).to all(be_ok)
    expect(File.read(beta.gemspec_path)).to include('add_development_dependency "alpha", "~> 1.0", ">= 1.2.3"')
  end

  it "handles array requirement declarations" do
    alpha = write_gem("alpha", version: "1.2.3")
    beta = write_gem("beta", version: "2.0.0", dependencies: {"alpha" => [[">= 1.0.0", "< 2.0"]]})

    described_class.new(released_members: [alpha], dependent_members: [beta], mode: :execute).results

    expect(File.read(beta.gemspec_path)).to include('"alpha", [">= 1.2.3", "< 2.0"]')
  end

  it "leaves already high enough floors unchanged" do
    alpha = write_gem("alpha", version: "1.2.3")
    beta = write_gem("beta", version: "2.0.0", dependencies: {"alpha" => [">= 1.2.3"]})

    results = described_class.new(released_members: [alpha], dependent_members: [beta], mode: :execute).results

    expect(results).to be_empty
  end

  it "does not add missing lower bounds" do
    alpha = write_gem("alpha", version: "1.2.3")
    beta = write_gem("beta", version: "2.0.0", dependencies: {"alpha" => ["~> 1.0"]})

    results = described_class.new(released_members: [alpha], dependent_members: [beta], mode: :execute).results

    expect(results).to be_empty
    expect(File.read(beta.gemspec_path)).to include('"alpha", "~> 1.0"')
  end

  def write_gem(name, version:, dependencies: {}, dependency_method: "add_dependency")
    root = File.join(@tmpdir, name)
    FileUtils.mkdir_p(root)
    dependency_lines = dependencies.map do |dependency, requirements|
      serialized = Array(requirements).map(&:inspect)
      %(  spec.#{dependency_method} #{dependency.inspect}, #{serialized.join(", ")})
    end
    gemspec_path = File.join(root, "#{name}.gemspec")
    File.write(gemspec_path, <<~RUBY)
      Gem::Specification.new do |spec|
        spec.name = #{name.inspect}
        spec.version = #{version.inspect}
      #{dependency_lines.join("\n")}
      end
    RUBY
    Kettle::Family::Member.new(
      name: name,
      root: root,
      gemspec_path: gemspec_path,
      version_file: nil,
      version: version,
      dependencies: dependencies.keys
    )
  end
end
