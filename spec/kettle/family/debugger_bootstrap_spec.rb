# frozen_string_literal: true

require "fileutils"
require "tmpdir"

RSpec.describe Kettle::Family::DebuggerBootstrap, :prism do
  around do |example|
    Dir.mktmpdir("kettle-family-debugger-bootstrap-spec") do |dir|
      @tmpdir = dir
      example.run
    end
  end

  it "replaces the complete byebug Gemfile stack with one debug declaration" do
    member = member_at("legacy")
    gemfile = File.join(member.root, "Gemfile")
    File.write(gemfile, <<~RUBY)
      group :test do
        gem "byebug", "~> 10", require: false
        gem "pry-byebug", "~> 3", require: false
      end
    RUBY

    result = described_class.new(mode: :execute).bootstrap_member(member)

    expect(result).to be_ok
    expect(File.read(gemfile)).to eq(<<~RUBY)
      group :test do
        gem "debug", require: false
      end
    RUBY
  end

  it "replaces legacy gemspec debugger dependencies before Bundler evaluates gemspec" do
    member = member_at("legacy")
    File.write(member.gemspec_path, <<~RUBY)
      Gem::Specification.new do |spec|
        spec.add_development_dependency "byebug", "~> 10"
        spec.add_development_dependency "pry-byebug", "~> 3"
      end
    RUBY

    described_class.new(mode: :execute).bootstrap_member(member)

    expect(File.read(member.gemspec_path)).to eq(<<~RUBY)
      Gem::Specification.new do |spec|
        spec.add_development_dependency "debug"
      end
    RUBY
  end

  def member_at(name)
    root = File.join(@tmpdir, name)
    FileUtils.mkdir_p(root)
    Kettle::Family::Member.new(
      name: name,
      root: root,
      gemspec_path: File.join(root, "#{name}.gemspec"),
      version: "1.0.0",
      dependencies: []
    )
  end
end
