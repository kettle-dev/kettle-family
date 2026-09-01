# frozen_string_literal: true

RSpec.describe Kettle::Family::BranchTargetConfig do
  around do |example|
    Dir.mktmpdir("kettle-family-branch-target-config") do |root|
      @family_root = root
      example.run
    end
  end

  it "keeps main for non-release branch-stack commands" do
    expect(described_class.branch_targets_for("template", ["main", "r1"])).to eq(["main", "r1"])
  end

  it "skips main for install and release branch-stack commands" do
    expect(described_class.branch_targets_for("install", ["main", "r1"])).to eq(["r1"])
    expect(described_class.branch_targets_for("release", ["main", "r1"])).to eq(["r1"])
  end

  it "does not treat synthetic branch config refs as the active config path" do
    expect(described_class.same_config_path?("branch:.kettle-family.yml", ".kettle-family.yml")).to be(false)
  end

  it "preserves the parent family local path root for configured member branch targets" do
    member_root = File.join(@family_root, "rubocop-lts")
    FileUtils.mkdir_p(member_root)
    config_path = File.join(@family_root, ".kettle-family.yml")
    File.write(config_path, <<~YAML)
      family:
        name: rubocop-lts
        mode: sibling_repos
        local_path_env: RUBOCOP_LTS_DEV
      members:
        roots:
          - rubocop-lts
      release:
        member_target_branches:
          rubocop-lts:
            - r3_2-even-v24
    YAML
    config = Kettle::Family::Config.load(root: @family_root)
    member = Kettle::Family::Member.new("rubocop-lts", member_root)

    derived = described_class.member_release_config(member: member, config: config)

    expect(derived.root).to eq(member_root)
    expect(derived.family_local_path_env).to eq("RUBOCOP_LTS_DEV" => @family_root)
    expect(derived.release_target_branches).to eq(["r3_2-even-v24"])
  end
end
