# frozen_string_literal: true

RSpec.describe Kettle::Family::Report do
  def member(name)
    Kettle::Family::Member.new(name: name, root: "/repo/#{name}", gemspec_path: nil, version_file: nil, version: "1.0.0", dependencies: [])
  end

  def result(member_name, phase: "release_publish", success: true, skipped: false, reason: nil)
    Kettle::Family::CommandResult.new(
      member_name,
      phase,
      ["release"],
      "/repo/#{member_name}",
      success ? 0 : 1,
      success,
      "",
      "",
      1.0,
      skipped,
      reason
    )
  end

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
        "current_branch" => "feature/release-state-compaction",
        "version" => "24.2.0",
        "latest_released" => "24.2.0",
        "latest_changelog_version" => "24.2.0",
        "unreleased_entries" => false,
        "prepared_release_pending" => true,
        "pending_release" => true,
        "bump_release_pending" => false
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

    expect(text).to include("boolean columns:")
    expect(text).to include("unrel: unreleased changelog entries are present")
    expect(text).to include("prep: V.ch.md matches V.rb and is ready to publish")
    expect(text).to include("pend: unrel or prep")
    expect(text).to include("bump: unrel is yes and V.rb matches V.rel")
    expect(text).to include("branch")
    expect(text).to include("V.rb")
    expect(text).to include("V.rel")
    expect(text).to include("V.ch.md")
    expect(text).to include("🔼 / 🔽")
    expect(text).to include("unrel")
    expect(text).to include("prep")
    expect(text).to include("pend")
    expect(text).to include("bump")
    expect(text).to include("r3_2-even-v24")
    expect(text).to include("feature/re")
    expect(text).not_to include("feature/release-state-compaction")
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
      member_release_target_branches: {"rubocop-lts" => ["r1", "r2"]}
    )

    expect(report.to_text).to include("member release targets:\n  rubocop-lts: r1, r2")
    expect(report.to_h.fetch("member_release_target_branches")).to eq("rubocop-lts" => ["r1", "r2"])
  end

  it "renders release wave markers separately from command results" do
    wave = Kettle::Family::CommandResult.new(
      "wave 1",
      "release_wave",
      ["internal", "release-wave"],
      "/repo",
      0,
      true,
      "alpha, gamma",
      "",
      0.0,
      false,
      "jobs=2 total=2"
    )
    release = Kettle::Family::CommandResult.new(
      "alpha",
      "release_build",
      ["bundle", "exec", "kettle-release"],
      "/repo/alpha",
      0,
      true,
      "",
      "",
      1.0,
      false,
      nil
    )
    report = described_class.new(
      family_name: "rubocop-lts",
      order_mode: "dependency",
      members: [],
      selected_members: [],
      config_path: nil,
      command: "release",
      results: [wave, release]
    )

    text = report.to_text

    expect(text).to include("release waves:\n  wave 1: alpha, gamma (jobs=2 total=2)")
    expect(text).to include("results:\n  ok alpha release_build")
    expect(text).not_to include("ok wave 1 release_wave")
  end

  it "summarizes failed template NDJSON without dumping the raw event stream" do
    selected_member = member("alpha")
    stdout = [
      JSON.generate(event_version: 1, type: "phase_start", phase: "install", status: "started"),
      JSON.generate(event_version: 1, type: "diagnostic", message: "bundle install failed"),
      JSON.generate(event_version: 1, type: "summary", changed_count: 3)
    ].join("\n")
    template_result = Kettle::Family::CommandResult.new(
      "alpha",
      "template",
      ["kettle-jem", "install", "--events"],
      "/repo/alpha",
      1,
      false,
      stdout,
      "Bundler::GitError\n",
      1.0,
      false,
      "command failed"
    )
    report = described_class.new(
      family_name: "rubocop-lts",
      order_mode: "dependency",
      members: [selected_member],
      selected_members: [selected_member],
      config_path: nil,
      command: "template",
      results: [template_result]
    )

    text = report.to_text

    expect(text).to include("diagnostic: bundle install failed")
    expect(text).to include("template event stream omitted from text report")
    expect(text).to include("Bundler::GitError")
    expect(text).to include("3 files changed")
    expect(text).not_to include("\"event_version\"")
    expect(text).not_to include("\"phase_start\"")
  end

  it "summarizes streamed failure output without replaying the transcript" do
    selected_member = member("alpha")
    stdout = <<~TEXT
      == kettle-release v2.3.8 ==
      Running pre-release checks via kettle-pre-release...
      GitHub Actions SHA pin validation failed
      Recommended fix: kettle-gha-sha-pins --write --upgrade major
      kettle-release: exited (status=1, msg=GitHub Actions SHA pin validation failed)
    TEXT
    result = Kettle::Family::CommandResult.new(
      "alpha",
      "release_publish",
      ["bundle", "exec", "kettle-release"],
      "/repo/alpha",
      1,
      false,
      stdout,
      "",
      1.0,
      false,
      "command failed",
      nil,
      true
    )
    report = described_class.new(
      family_name: "kettle-dev",
      order_mode: "dependency",
      members: [selected_member],
      selected_members: [selected_member],
      config_path: nil,
      command: "release",
      release_mode: "publish",
      results: [result]
    )

    text = report.to_text

    expect(text).to include("summary: kettle-release: exited (status=1, msg=GitHub Actions SHA pin validation failed)")
    expect(text).to include("recommended fix: kettle-gha-sha-pins --write --upgrade major")
    expect(text).to include("output: omitted because it was already streamed")
    expect(text).not_to include("Running pre-release checks via kettle-pre-release")
    expect(report.to_h.fetch("results").first.fetch("output_streamed")).to be(true)
  end

  it "uses a full release resume hint for failed publish releases" do
    result = Kettle::Family::CommandResult.new(
      "rubocop-ruby3_2",
      "release_publish",
      ["bundle", "exec", "kettle-release"],
      "/repo/rubocop-ruby3_2",
      1,
      false,
      "",
      "CI failed",
      1.0,
      false,
      "Workflow failed"
    )
    report = described_class.new(
      family_name: "rubocop-lts",
      order_mode: "dependency",
      members: [],
      selected_members: [],
      config_path: nil,
      command: "release",
      release_mode: "publish",
      results: [result]
    )

    expect(report.to_text).to include("resume: kettle-family release --execute --publish")
    expect(report.to_text).not_to include("--start-at rubocop-ruby3_2")
    expect(report.to_h.fetch("resume_hint")).to eq("kettle-family release --execute --publish")
  end

  it "renders a final summary for successful commands" do
    report = described_class.new(
      family_name: "rubocop-lts",
      order_mode: "dependency",
      members: [member("alpha")],
      selected_members: [member("alpha")],
      config_path: nil,
      command: "test",
      results: [result("alpha", phase: "test")]
    )

    expect(report.to_text).to include("summary:")
    expect(report.to_text).to include("outcome: success")
    expect(report.to_text).to include("succeeded: alpha")
    expect(report.to_h.fetch("summary").fetch("outcome")).to eq("success")
  end

  it "renders failed and pending members in the final summary" do
    report = described_class.new(
      family_name: "rubocop-lts",
      order_mode: "dependency",
      members: [member("alpha"), member("beta"), member("gamma")],
      selected_members: [member("alpha"), member("beta"), member("gamma")],
      config_path: nil,
      command: "release",
      release_mode: "publish",
      results: [
        result("alpha", phase: "release_publish", success: false, reason: "Workflow failed"),
        result("beta", phase: "release_publish")
      ]
    )

    text = report.to_text
    summary = report.to_h.fetch("summary")

    expect(report).not_to be_success
    expect(text).to include("outcome: failure")
    expect(text).to include("succeeded: beta")
    expect(text).to include("failed: alpha release_publish (Workflow failed)")
    expect(text).to include("pending: gamma release (not run after earlier failure)")
    expect(text).to include("resume: kettle-family release --execute --publish")
    expect(summary.fetch("pending")).to eq([
      {"member" => "gamma", "phase" => "release", "reason" => "not run after earlier failure"}
    ])
  end
end
