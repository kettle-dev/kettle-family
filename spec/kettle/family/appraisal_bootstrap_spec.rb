# frozen_string_literal: true

require "fileutils"
require "tmpdir"

RSpec.describe Kettle::Family::AppraisalBootstrap, :prism do
  around do |example|
    Dir.mktmpdir("kettle-family-appraisal-bootstrap-spec") do |dir|
      @tmpdir = dir
      example.run
    end
  end

  it "removes only the retired pre-fork appraisal declaration before templating" do
    member = member_at("legacy")
    File.write(File.join(member.root, "Gemfile"), <<~RUBY)
      source "https://rubygems.org"
      gem "appraisal", github: "pboling/appraisal", branch: "galtzo"
      gem "appraisal2", "~> 3.0"
    RUBY
    File.write(File.join(member.root, "Appraisal.root.gemfile"), <<~RUBY)
      gemspec
      gem "appraisal", github: "pboling/appraisal", branch: "galtzo"
    RUBY

    bootstrap = described_class.new(mode: :execute)

    expect(bootstrap.member_needs_bootstrap?(member)).to be(true)
    result = bootstrap.bootstrap_member(member)

    expect(result).to be_ok
    expect(File.read(File.join(member.root, "Gemfile"))).not_to include("pboling/appraisal")
    expect(File.read(File.join(member.root, "Gemfile"))).to include('gem "appraisal2", "~> 3.0"')
    expect(File.read(File.join(member.root, "Appraisal.root.gemfile"))).to eq("gemspec\n")
  end

  it "does not remove a different appraisal source or an appraisal2 declaration" do
    member = member_at("current")
    gemfile = File.join(member.root, "Gemfile")
    File.write(gemfile, <<~RUBY)
      gem "appraisal", github: "another-org/appraisal", branch: "main"
      gem "appraisal2", "~> 3.0"
    RUBY

    bootstrap = described_class.new(mode: :execute)

    expect(bootstrap.member_needs_bootstrap?(member)).to be(false)
    expect(File.read(gemfile)).to include("another-org/appraisal")
  end

  it "plans removal without modifying the Gemfile during a dry run" do
    member = member_at("legacy")
    gemfile = File.join(member.root, "Gemfile")
    original = <<~RUBY
      source "https://rubygems.org"
      gem "appraisal", github: "pboling/appraisal", branch: "galtzo"
    RUBY
    File.write(gemfile, original)

    result = described_class.new.bootstrap_member(member)

    expect(result).to be_ok
    expect(result.skipped).to be(true)
    expect(result.reason).to eq("dry run")
    expect(File.read(gemfile)).to eq(original)
  end

  it "does not bootstrap a member without managed Gemfiles" do
    member = member_at("current")

    expect(described_class.new(mode: :execute).member_needs_bootstrap?(member)).to be(false)
  end

  it "ignores appraisal calls without the exact retired source coordinates" do
    member = member_at("current")
    File.write(File.join(member.root, "Gemfile"), <<~RUBY)
      options = {github: "pboling/appraisal", branch: "galtzo"}
      gem
      gem "appraisal"
      gem "appraisal", github: "pboling/appraisal"
      gem "appraisal", github: :not_a_string, branch: "galtzo"
      gem "appraisal", {github: "pboling/appraisal", branch: "main"}
      gem "appraisal", **options
    RUBY

    expect(described_class.new(mode: :execute).member_needs_bootstrap?(member)).to be(false)
  end

  it "removes a retired declaration in the middle of a file without removing neighbors" do
    member = member_at("legacy")
    gemfile = File.join(member.root, "Gemfile")
    File.write(gemfile, <<~RUBY)
      source "https://rubygems.org"

      gem "appraisal", github: "pboling/appraisal", branch: "galtzo"

      gem "appraisal2", "~> 3.0"
    RUBY

    described_class.new(mode: :execute).bootstrap_member(member)

    expect(File.read(gemfile)).to eq(<<~RUBY)
      source "https://rubygems.org"


      gem "appraisal2", "~> 3.0"
    RUBY
  end

  it "removes a final retired declaration when the file has no trailing newline" do
    member = member_at("legacy-no-newline")
    gemfile = File.join(member.root, "Gemfile")
    File.write(gemfile, 'gem "appraisal", github: "pboling/appraisal", branch: "galtzo"')

    described_class.new(mode: :execute).bootstrap_member(member)

    expect(File.read(gemfile)).to eq("\n")
  end

  def member_at(name)
    root = File.join(@tmpdir, name)
    FileUtils.mkdir_p(root)
    Kettle::Family::Member.new(name: name, root: root, gemspec_path: File.join(root, "#{name}.gemspec"), version: "1.0.0", dependencies: [])
  end
end
