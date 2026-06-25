# frozen_string_literal: true

RSpec.describe Kettle::Family::BranchTargetConfig do
  it "keeps main for non-release branch-stack commands" do
    expect(described_class.branch_targets_for("template", %w[main r1])).to eq(%w[main r1])
  end

  it "skips main for install and release branch-stack commands" do
    expect(described_class.branch_targets_for("install", %w[main r1])).to eq(%w[r1])
    expect(described_class.branch_targets_for("release", %w[main r1])).to eq(%w[r1])
  end

  it "does not treat synthetic branch config refs as the active config path" do
    expect(described_class.same_config_path?("branch:.kettle-family.yml", ".kettle-family.yml")).to be(false)
  end
end
