# frozen_string_literal: true

require "fileutils"
require "tmpdir"

RSpec.describe Kettle::Family::Config do
  around do |example|
    Dir.mktmpdir("kettle-family-config-series-spec") do |dir|
      @tmpdir = dir
      example.run
    end
  end

  it "defaults to no independent version series members" do
    config = described_class.load(root: @tmpdir)

    expect(config.release_version_series_independent_members).to be_empty
  end

  it "loads release.version_series.independent_members" do
    File.write(File.join(@tmpdir, ".kettle-family.yml"), <<~YAML)
      release:
        version_series:
          independent_members:
            - kettle-jem
            - other-member
    YAML

    config = described_class.load(root: @tmpdir)

    expect(config.release_version_series_independent_members).to eq(%w[kettle-jem other-member])
    expect(config.independent_version_series_member?(double(name: "kettle-jem"))).to be(true)
    expect(config.independent_version_series_member?(double(name: "smorg-rb"))).to be(false)
  end

  it "normalizes blank and duplicate independent member entries" do
    File.write(File.join(@tmpdir, ".kettle-family.yml"), <<~YAML)
      release:
        version_series:
          independent_members:
            - kettle-jem
            - ""
            - kettle-jem
    YAML

    config = described_class.load(root: @tmpdir)

    expect(config.release_version_series_independent_members).to eq(%w[kettle-jem])
  end
end
