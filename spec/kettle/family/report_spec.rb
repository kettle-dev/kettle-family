# frozen_string_literal: true

RSpec.describe Kettle::Family::Report do
  it "prints the loaded kettle-family version in text reports" do
    report = described_class.new(
      family_name: "rubocop-lts",
      order_mode: "dependency",
      members: [],
      selected_members: [],
      config_path: nil,
      command: "discover"
    )

    expect(report.to_text.lines.first).to eq("kettle-family: #{Kettle::Family::VERSION}\n")
  end

  it "renders release-state results with a branch column when branches are present" do
    result = Kettle::Family::ReleaseStateResult.new(
      member_name: "rubocop-lts",
      command: ["internal", "release-state"],
      workdir: "/repo/rubocop-lts",
      status: 0,
      success: true,
      stdout: "",
      stderr: "",
      elapsed_seconds: 0.1,
      state: {
        "gem_name" => "rubocop-lts",
        "version" => "24.2.0",
        "latest_released" => "24.2.0",
        "latest_changelog_version" => "24.2.0",
        "unreleased_entries" => false,
        "prepared_release_pending" => true,
        "pending_release" => true
      },
      branch: "r3_2-even-v24"
    )

    report = described_class.new(
      family_name: "rubocop-lts",
      order_mode: "dependency",
      members: [],
      selected_members: [],
      config_path: nil,
      command: "release-state",
      results: [result]
    )

    text = report.to_text

    expect(text).to include("branch")
    expect(text).to include("r3_2-even-v24")
    expect(text).to include("rubocop-lts")
  end

  it "renders member-local release target branches" do
    report = described_class.new(
      family_name: "rubocop-lts",
      order_mode: "dependency",
      members: [],
      selected_members: [],
      config_path: nil,
      command: "release",
      member_release_target_branches: {"rubocop-lts" => %w[r1 r2]}
    )

    expect(report.to_text).to include("member release targets:\n  rubocop-lts: r1, r2")
    expect(report.to_h.fetch("member_release_target_branches")).to eq("rubocop-lts" => %w[r1 r2])
  end
end
