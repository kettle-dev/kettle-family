# frozen_string_literal: true

require "fileutils"
require "tmpdir"

RSpec.describe Kettle::Family::Config do
  around do |example|
    Dir.mktmpdir("kettle-family-config-spec") do |dir|
      @tmpdir = dir
      example.run
    end
  end

  it "loads default config values when no config file exists" do
    config = described_class.load(root: @tmpdir)

    expect(config.path).to be_nil
    expect(config.family_name).to eq(File.basename(@tmpdir))
    expect(config.members_root).to eq(@tmpdir)
    expect(config.discover_members?).to be(true)
    expect(config.member_exclude_patterns).to eq(["**/vendor/**"])
    expect(config.order_mode).to eq("dependency")
    expect(config.order_hints).to be_empty
  end

  it "loads configured values and stringifies keys" do
    File.write(File.join(@tmpdir, ".kettle-family.yml"), <<~YAML)
      family:
        name: configured-family
        members_root: gems
      members:
        discover: false
        explicit:
          - root: alpha
        exclude:
          - "**/tmp/**"
        order:
          mode: fixed
          hints:
            - alpha
    YAML

    config = described_class.load(root: @tmpdir)

    expect(config.family_name).to eq("configured-family")
    expect(config.members_root).to eq(File.join(@tmpdir, "gems"))
    expect(config.discover_members?).to be(false)
    expect(config.member_exclude_patterns).to eq(["**/vendor/**", "**/tmp/**"])
    expect(config.explicit_members).to eq([{"root" => File.join(@tmpdir, "alpha")}])
    expect(config.order_mode).to eq("fixed")
    expect(config.order_hints).to eq(["alpha"])
  end

  it "loads an explicit config path" do
    File.write(File.join(@tmpdir, "family.yml"), "family:\n  name: explicit\n")

    config = described_class.load(root: @tmpdir, path: "family.yml")

    expect(config.path).to eq(File.join(@tmpdir, "family.yml"))
    expect(config.family_name).to eq("explicit")
  end

  it "falls back to members.root when family.members_root is absent" do
    File.write(File.join(@tmpdir, ".kettle-family.yml"), "members:\n  root: components\n")

    config = described_class.load(root: @tmpdir)

    expect(config.members_root).to eq(File.join(@tmpdir, "components"))
  end

  it "loads release target branches from release config" do
    File.write(File.join(@tmpdir, ".kettle-family.yml"), <<~YAML)
      release:
        target_branches:
          - r1_8-even-v0
          - r1_9-even-v2
    YAML

    config = described_class.load(root: @tmpdir)

    expect(config.release_target_branches).to eq(%w[r1_8-even-v0 r1_9-even-v2])
  end

  it "loads release target branches from branch aliases" do
    File.write(File.join(@tmpdir, ".kettle-family.yml"), <<~YAML)
      branches:
        release_targets:
          - r3_2-even-v24
    YAML

    config = described_class.load(root: @tmpdir)

    expect(config.release_target_branches).to eq(["r3_2-even-v24"])
  end

  it "defaults publish releases to kettle-release" do
    config = described_class.load(root: @tmpdir)

    expect(config.release_publish_command).to eq("bundle exec kettle-release")
  end
end
