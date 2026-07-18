# frozen_string_literal: true

RSpec.describe Gem::Specification do
  let(:specification) { described_class.load(File.expand_path("../../../../kettle-family.gemspec", __dir__)) }

  it "ships provider gems for built-in kettle-family workflow commands" do
    runtime_dependencies = specification.dependencies.select { |dependency| dependency.type == :runtime }
    runtime_dependency_names = runtime_dependencies.map(&:name)

    expect(runtime_dependency_names).to include(
      "kettle-dev",
      "kettle-jem",
      "kettle-test"
    )
  end

  it "declares the Ruby floor required by the templating provider" do
    expect(specification.required_ruby_version).to be_satisfied_by(Gem::Version.new("4.0.0"))
    expect(specification.required_ruby_version).not_to be_satisfied_by(Gem::Version.new("3.3.0"))
  end
end
