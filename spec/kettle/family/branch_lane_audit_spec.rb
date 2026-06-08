# frozen_string_literal: true

require "fileutils"
require "tmpdir"

RSpec.describe Kettle::Family::BranchLaneAudit do
  around do |example|
    Dir.mktmpdir("kettle-family-branch-lane-spec") do |dir|
      @tmpdir = dir
      example.run
    end
  end

  it "passes complete branch lane mappings" do
    write_config(<<~YAML)
      branch_lanes:
        ruby-3-4:
          branch: ruby-3-4
          version: 3.4.0
          members:
            - alpha
    YAML
    config = Kettle::Family::Config.load(root: @tmpdir)
    member = member("alpha")

    results = described_class.new(config: config, members: [member]).results

    expect(results.first).to be_ok
  end

  it "reports missing lanes and unknown members" do
    empty_config = Kettle::Family::Config.load(root: @tmpdir)
    missing = described_class.new(config: empty_config, members: []).results
    write_config(<<~YAML)
      branch_lanes:
        ruby-3-4:
          branch: ruby-3-4
          members:
            - missing
    YAML
    configured = Kettle::Family::Config.load(root: @tmpdir)

    audited = described_class.new(config: configured, members: [member("alpha")]).results

    expect(missing.first.stdout).to include("no branch lanes configured")
    expect(audited.first.stdout).to include("missing version")
    expect(audited.first.stdout).to include("unknown member missing")
  end

  def write_config(content)
    File.write(File.join(@tmpdir, ".kettle-family.yml"), content)
  end

  def member(name)
    Kettle::Family::Member.new(name: name, root: @tmpdir, gemspec_path: nil, version_file: nil, version: "1.0.0", dependencies: [])
  end
end
