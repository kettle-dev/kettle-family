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

  it "ignores a member config that is the active family config or has no branch targets" do
    member = Kettle::Family::Member.new("rubocop-lts", @family_root)
    config_path = File.join(@family_root, ".kettle-family.yml")
    File.write(config_path, "family:\n  name: rubocop-lts\n")
    config = Kettle::Family::Config.load(root: @family_root)

    expect(described_class.member_local_release_config(member: member, config: config)).to be_nil

    member_root = File.join(@family_root, "member")
    FileUtils.mkdir_p(member_root)
    File.write(File.join(member_root, ".kettle-family.yml"), "family:\n  name: member\n")
    nested_member = Kettle::Family::Member.new("member", member_root)

    expect(described_class.member_local_release_config(member: nested_member, config: config)).to be_nil
  end

  it "selects the first branch config that declares release targets" do
    member_root = File.join(@family_root, "member")
    FileUtils.mkdir_p(member_root)
    member = Kettle::Family::Member.new("member", member_root)
    empty = "family:\n  name: member\n"
    targeted = "release:\n  target_branches:\n    - legacy\n"
    allow(described_class).to receive(:member_git_root).with(member).and_return(@family_root)
    allow(described_class).to receive(:member_relative_root).with(member, @family_root).and_return("member")
    allow(described_class).to receive(:member_local_config_paths)
      .with(@family_root, "member")
      .and_return([["main:.kettle-family.yml", empty], ["legacy:.kettle-family.yml", targeted]])

    config = described_class.member_local_release_config_from_branch(member)

    expect(config.path).to eq("legacy:.kettle-family.yml")
    expect(config.release_target_branches).to eq(["legacy"])
  end

  it "loads standalone member branch targets without a parent family config" do
    member_root = File.join(@family_root, "member")
    FileUtils.mkdir_p(member_root)
    File.write(File.join(member_root, ".kettle-family.yml"), <<~YAML)
      release:
        target_branches:
          - legacy
    YAML
    member = Kettle::Family::Member.new("member", member_root)

    config = described_class.member_local_release_config(member: member, config: nil)

    expect(config.release_target_branches).to eq(["legacy"])
  end

  it "derives nested member roots and rejects paths outside the Git checkout" do
    nested_root = File.join(@family_root, "gems", "member")
    FileUtils.mkdir_p(nested_root)
    nested_member = Kettle::Family::Member.new("member", nested_root)
    outside_root = File.join(File.dirname(@family_root), "outside-#{File.basename(@family_root)}")
    FileUtils.mkdir_p(outside_root)
    outside_member = Kettle::Family::Member.new("outside", outside_root)

    expect(described_class.member_relative_root(nested_member, @family_root)).to eq("gems/member")
    expect { described_class.member_relative_root(outside_member, @family_root) }
      .to raise_error(Kettle::Family::Error, /outside git root/)
  ensure
    FileUtils.rm_rf(outside_root) if outside_root
  end

  it "reports failure to enumerate local branches" do
    allow(Open3).to receive(:capture3)
      .and_return(["", "not a repository", instance_double(Process::Status, success?: false)])

    expect { described_class.local_branches(@family_root) }
      .to raise_error(Kettle::Family::Error, /could not list local branches/)
  end
end
