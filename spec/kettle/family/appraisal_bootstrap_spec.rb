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
    expect(File.read(File.join(member.root, "Appraisal.root.gemfile"))).not_to include("pboling/appraisal")
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

  def member_at(name)
    root = File.join(@tmpdir, name)
    FileUtils.mkdir_p(root)
    Kettle::Family::Member.new(name: name, root: root, gemspec_path: File.join(root, "#{name}.gemspec"), version: "1.0.0", dependencies: [])
  end
end
