# frozen_string_literal: true

require "fileutils"
require "tmpdir"

RSpec.describe Kettle::Family::NomonoBootstrap, :prism do
  around do |example|
    Dir.mktmpdir("kettle-family-nomono-bootstrap-spec") do |dir|
      @tmpdir = dir
      example.run
    end
  end

  it "raises stale managed Gemfile nomono floors while preserving the declaration shape" do
    member = member_at("kettle-gha-pins")
    File.write(File.join(member.root, "Gemfile"), <<~RUBY)
      source "https://gem.coop"

      gem "nomono", "~> 1.1", ">= 1.1.0", require: false
    RUBY
    File.write(File.join(member.root, "Gemfile.lock"), <<~LOCK)
      GEM
        remote: https://gem.coop/
        specs:
          nomono (1.1.0)
    LOCK

    bootstrap = described_class.new(latest_version: "1.1.1", mode: :execute)

    expect(bootstrap.member_needs_bootstrap?(member)).to be(true)
    result = bootstrap.bootstrap_member(member)

    expect(result).to be_ok
    expect(File.read(File.join(member.root, "Gemfile"))).to include(
      'gem "nomono", "~> 1.1", ">= 1.1.1", require: false'
    )
    expect(result.stdout).to include("lockfile nomono 1.1.0 is below 1.1.1")
  end

  it "does not rewrite current nomono floors and locks" do
    member = member_at("kettle-gha-pins")
    gemfile = File.join(member.root, "Gemfile")
    File.write(gemfile, <<~RUBY)
      source "https://gem.coop"

      gem "nomono", "~> 1.1", ">= 1.1.1", require: false
    RUBY
    File.write(File.join(member.root, "Gemfile.lock"), <<~LOCK)
      GEM
        remote: https://gem.coop/
        specs:
          nomono (1.1.1)
    LOCK

    bootstrap = described_class.new(latest_version: "1.1.1", mode: :execute)

    expect(bootstrap.member_needs_bootstrap?(member)).to be(false)
    expect(File.read(gemfile)).to include('gem "nomono", "~> 1.1", ">= 1.1.1", require: false')
  end

  it "repairs stale nomono floors in existing local modular Gemfiles" do
    member = member_at("kettle-gha-pins")
    local_gemfile = File.join(member.root, "gemfiles/modular/coverage_local.gemfile")
    FileUtils.mkdir_p(File.dirname(local_gemfile))
    File.write(local_gemfile, <<~RUBY)
      nomono_activation_requirements = ["~> 1.1", ">= 1.1.0"]
      Kernel.send(:gem, "nomono", *nomono_activation_requirements)
    RUBY

    bootstrap = described_class.new(latest_version: "1.1.1", mode: :execute)

    expect(bootstrap.member_needs_bootstrap?(member)).to be(true)
    result = bootstrap.bootstrap_member(member)

    expect(result).to be_ok
    expect(File.read(local_gemfile)).to include(
      'nomono_activation_requirements = ["~> 1.1", ">= 1.1.1"]'
    )
    expect(result.stdout).to include("gemfiles/modular/coverage_local.gemfile")
  end

  def member_at(name)
    root = File.join(@tmpdir, name)
    FileUtils.mkdir_p(root)
    Kettle::Family::Member.new(name: name, root: root, gemspec_path: File.join(root, "#{name}.gemspec"), version: "1.0.0", dependencies: [])
  end
end
