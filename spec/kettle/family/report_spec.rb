# frozen_string_literal: true

RSpec.describe Kettle::Family::Report do
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
end
