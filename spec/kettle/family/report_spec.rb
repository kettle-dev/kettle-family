# frozen_string_literal: true

RSpec.describe Kettle::Family::Report do
  def member(name)
    Kettle::Family::Member.new(name: name, root: "/repo/#{name}", gemspec_path: nil, version_file: nil, version: "1.0.0", dependencies: [])
  end

  def result(member_name, phase: "release_publish", success: true, skipped: false, reason: nil, elapsed_seconds: 1.0)
    Kettle::Family::CommandResult.new(
      member_name,
      phase,
      ["release"],
      "/repo/#{member_name}",
      success ? 0 : 1,
      success,
      "",
      "",
      elapsed_seconds,
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

  it "tracks every command that reports selected member results" do
    expected = (
      Kettle::Family::CLI::WORKFLOW_COMMANDS +
      %w[add-changelog bump bump-version clean-unreleased install reconcile-releases release-state]
    ).sort

    expect(described_class::MEMBER_RESULT_COMMANDS.sort).to eq(expected)
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
        "github_latest_release" => "v24.2.0",
        "transfer_changelog_lag" => 2,
        "transfer_changelog_total" => 9,
        "transfer_changelog_applicable" => 6,
        "transfer_changelog_excluded_present" => 1,
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
    expect(text).to include("count columns:")
    expect(text).to include("T(n): filter-aware kettle-jem transfer changelog lag; n is the total source entry count and row values are missing / applicable (x excluded-present)")
    expect(text).to include("branch")
    expect(text).to include("V.rb")
    expect(text).to include("V.ch.md")
    expect(text).to include("V.rel")
    expect(text).to include("GH.rel")
    expect(text).to include("T(9)")
    expect(text).to include("2 / 6 (x1)")
    expect(text).to include("^ / v")
    expect(text).to include("unrel")
    expect(text).to include("prep")
    expect(text).to include("pend")
    expect(text).to include("bump")
    expect(text).to include("r3_2-even-v24")
    expect(text).to include("feature/re")
    expect(text).not_to include("feature/release-state-compaction")
    expect(text).to include("rubocop-lts")
    header = text.lines.find { |line| line.include?("GH.rel") }
    expect(header.index("V.rb")).to be < header.index("V.ch.md")
    expect(header.index("V.ch.md")).to be < header.index("V.rel")
    expect(header.index("V.rel")).to be < header.index("GH.rel")
    expect(header.index("GH.rel")).to be < header.index("T(9)")
  end

  it "marks GitHub release values that do not match the RubyGems release" do
    result = Kettle::Family::ReleaseStateResult.new(
      member_name: "alpha",
      command: ["internal", "release-state"],
      workdir: "/repo/alpha",
      status: 0,
      success: true,
      stdout: "",
      stderr: "",
      elapsed_seconds: 0.1,
      state: {
        "gem_name" => "alpha",
        "current_branch" => "main",
        "version" => "1.2.4",
        "latest_released" => "1.2.3",
        "github_latest_release" => "v1.2.2",
        "latest_changelog_version" => "1.2.4",
        "unreleased_entries" => true,
        "prepared_release_pending" => false,
        "pending_release" => true,
        "bump_release_pending" => false
      }
    )
    report = described_class.new(
      family_name: "kettle-dev",
      order_mode: "dependency",
      members: [],
      selected_members: [],
      config_path: nil,
      command: "release-state",
      results: [result]
    )

    expect(report.to_text).to include("🔴 v1.2.2")
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

  it "summarizes failed template preparation NDJSON without dumping the raw event stream" do
    selected_member = member("alpha")
    stdout = [
      JSON.generate(event_version: 1, type: "phase_start", phase: "facts", status: "started"),
      JSON.generate(event_version: 1, type: "diagnostic", message: "cannot load such file -- ast/merge/file_analyzable")
    ].join("\n")
    prepare_result = Kettle::Family::CommandResult.new(
      "alpha",
      "prepare_template_dependencies",
      ["bundle", "exec", "kettle-jem", "prepare", "--events"],
      "/repo/alpha",
      1,
      false,
      stdout,
      "LoadError: cannot load such file -- ast/merge/file_analyzable\n",
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
      results: [prepare_result]
    )

    text = report.to_text

    expect(text).to include("diagnostic: cannot load such file -- ast/merge/file_analyzable")
    expect(text).to include("template event stream omitted from text report")
    expect(text).to include("LoadError: cannot load such file -- ast/merge/file_analyzable")
    expect(text).not_to include("\"event_version\"")
    expect(text).not_to include("\"phase_start\"")
  end

  it "counts unique template changed files across duplicate NDJSON summaries" do
    selected_member = member("alpha")
    stdout = [
      JSON.generate(event_version: 1, type: "summary", changed_files: ["Gemfile", "Rakefile"], changed_count: 2),
      JSON.generate(event_version: 1, type: "summary", changed_files: ["Gemfile", "Rakefile", ".yard-lint.yml"], changed_count: 3),
      JSON.generate(event_version: 1, type: "summary", changed_files: ["Rakefile", ".yard-lint.yml"], changed_count: 2)
    ].join("\n")
    template_result = Kettle::Family::CommandResult.new(
      "alpha",
      "template",
      ["kettle-jem", "install", "--events"],
      "/repo/alpha",
      0,
      true,
      stdout,
      "",
      1.0,
      false,
      nil
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

    expect(text).to include("3 files changed")
    expect(text).not_to include("7 files changed")
  end

  it "reports checksum hits and unchanged template files from NDJSON summaries" do
    selected_member = member("alpha")
    stdout = JSON.generate(
      event_version: 1,
      type: "summary",
      changed_count: 3,
      checksum_hit_count: 17,
      checksum_protected_count: 2,
      unchanged_count: 12
    )
    template_result = Kettle::Family::CommandResult.new(
      "alpha", "template", ["kettle-jem", "install", "--events"], "/repo/alpha",
      0, true, stdout, "", 1.0, false, nil
    )
    report = described_class.new(
      family_name: "rubocop-lts", order_mode: "dependency", members: [selected_member],
      selected_members: [selected_member], config_path: nil, command: "template", results: [template_result]
    )

    text = report.to_text

    expect(text).to include("17 checksum hits")
    expect(text).to include("2 checksum-protected changes")
    expect(text).to include("12 unchanged")
    expect(text).to include("3 files changed")
  end

  it "uses the last template changed count when NDJSON summaries omit changed files" do
    selected_member = member("alpha")
    stdout = [
      JSON.generate(event_version: 1, type: "summary", changed_count: 2),
      JSON.generate(event_version: 1, type: "summary", changed_count: 3)
    ].join("\n")
    template_result = Kettle::Family::CommandResult.new(
      "alpha",
      "template",
      ["kettle-jem", "install", "--events"],
      "/repo/alpha",
      0,
      true,
      stdout,
      "",
      1.0,
      false,
      nil
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

    expect(text).to include("3 files changed")
    expect(text).not_to include("5 files changed")
  end

  it "summarizes failed release NDJSON without dumping the raw event stream" do
    selected_member = member("alpha")
    stdout = [
      JSON.generate(event_version: 1, type: "run_start", command: "release"),
      JSON.generate(event_version: 1, type: "diagnostic", kind: "remote_fetch", message: "cb unavailable"),
      JSON.generate(event_version: 1, type: "summary", status: "failed", error_message: "Command failed")
    ].join("\n")
    result = Kettle::Family::CommandResult.new(
      "alpha",
      "release_publish",
      ["bundle", "exec", "kettle-release", "--events"],
      "/repo/alpha",
      1,
      false,
      stdout,
      "",
      1.0,
      false,
      "command failed"
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

    expect(text).to include("diagnostic: cb unavailable")
    expect(text).to include("summary: failed: Command failed")
    expect(text).to include("release event stream omitted from text report")
    expect(text).not_to include("\"event_version\"")
    expect(text).not_to include("\"run_start\"")
  end

  it "summarizes streamed failure output without replaying the transcript" do
    selected_member = member("alpha")
    stdout = <<~TEXT
      == kettle-release v2.3.8 ==
      Running pre-release checks via kettle-pre-release...
      GitHub Actions SHA pin validation failed
      Recommended fix: kettle-gha-pins --write --upgrade major
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
      true,
      "/repo/alpha/tmp/kettle-family/release/alpha-release_publish.log"
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
    expect(text).to include("recommended fix: kettle-gha-pins --write --upgrade major")
    expect(text).to include("log: /repo/alpha/tmp/kettle-family/release/alpha-release_publish.log")
    expect(text).to include("output: omitted because it was already streamed")
    expect(text).not_to include("Running pre-release checks via kettle-pre-release")
    expect(report.to_h.fetch("results").first.fetch("output_streamed")).to be(true)
    expect(report.to_h.fetch("results").first.fetch("log_path")).to eq("/repo/alpha/tmp/kettle-family/release/alpha-release_publish.log")
  end

  it "keeps centralized action-pin JSON in its log instead of the text report" do
    selected_member = member("alpha")
    payload = JSON.generate(
      "repositories" => Array.new(40) { |index| {"repository" => "actions/cache", "ref" => index.to_s} }
    )
    list_result = Kettle::Family::CommandResult.new(
      "alpha",
      "gha_sha_pins_list",
      ["bundle", "exec", "kettle-gha-pins", "--list"],
      "/repo/alpha",
      0,
      true,
      payload,
      "",
      1.0,
      false,
      nil,
      nil,
      false,
      "/repo/tmp/kettle-family/gha-sha-pins-list.log"
    )
    review_result = Kettle::Family::CommandResult.new(
      "alpha",
      "gha_sha_pins_review",
      ["bundle", "exec", "kettle-gha-pins", "--review"],
      "/repo/alpha",
      1,
      false,
      payload,
      "kettle-gha-pins: GitHub refresh timed out for codecov/codecov-action",
      1.0,
      false,
      "command failed",
      nil,
      false,
      "/repo/tmp/kettle-family/gha-sha-pins-review.log"
    )
    report = described_class.new(
      family_name: "kettle-dev",
      order_mode: "dependency",
      members: [selected_member],
      selected_members: [selected_member],
      config_path: nil,
      command: "release",
      release_mode: "publish",
      results: [list_result, review_result]
    )

    text = report.to_text

    expect(text).not_to include('"repositories"')
    expect(text).not_to include('"ref"')
    expect(text).to include("log: /repo/tmp/kettle-family/gha-sha-pins-review.log")
    expect(text).to include("kettle-gha-pins: GitHub refresh timed out for codecov/codecov-action")
  end

  it "uses the last useful streamed line when no explicit failure line is present" do
    selected_member = member("alpha")
    result = Kettle::Family::CommandResult.new(
      "alpha",
      "release_publish",
      ["bundle", "exec", "kettle-release"],
      "/repo/alpha",
      1,
      false,
      "Fetching metadata\nCould not find json-2.21.2 in locally installed gems\n",
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

    expect(report.to_text).to include("summary: Could not find json-2.21.2 in locally installed gems")
  end

  it "prints a release log path for failed release commands with no captured output" do
    selected_member = member("alpha")
    result = Kettle::Family::CommandResult.new(
      "alpha",
      "release_publish",
      ["bundle", "exec", "kettle-release"],
      "/repo/alpha",
      1,
      false,
      "",
      "",
      1.0,
      false,
      "command failed",
      nil,
      false,
      "/repo/alpha/tmp/kettle-family/release/alpha-release_publish.log"
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

    expect(report.to_text).to include("log: /repo/alpha/tmp/kettle-family/release/alpha-release_publish.log")
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

  it "repeats command context in the final summary footer" do
    report = described_class.new(
      family_name: "structuredmerge-ruby",
      family_mode: "monorepo",
      order_mode: "dependency",
      members: [member("alpha")],
      selected_members: [member("alpha")],
      config_path: "/repo/.kettle-family.yml",
      command: "release",
      release_mode: "publish",
      release_target_branches: ["main"],
      member_release_target_branches: {"alpha" => ["r1", "r2"]},
      results: [result("alpha", phase: "release_publish")]
    )

    footer = report.to_text.split("\ncontext:\n").fetch(1)

    expect(footer).to include("  kettle-family: #{Kettle::Family::VERSION}")
    expect(footer).to include("  family: structuredmerge-ruby")
    expect(footer).to include("  mode: monorepo")
    expect(footer).to include("  config: /repo/.kettle-family.yml")
    expect(footer).to include("  order: dependency")
    expect(footer).to include("  command: release")
    expect(footer).to include("  release mode: publish")
    expect(footer).to include("  release targets: main")
    expect(footer).to include("  member release targets:\n    alpha: r1, r2")
    expect(footer).to include("summary:\n  outcome: success")
    expect(footer).to include("  elapsed: 00:01")
  end

  it "includes total visible result elapsed time in the summary" do
    report = described_class.new(
      family_name: "structuredmerge-ruby",
      order_mode: "dependency",
      members: [member("alpha")],
      selected_members: [member("alpha")],
      config_path: nil,
      command: "release",
      results: [
        result("alpha", phase: "release_wave", elapsed_seconds: 300),
        result("alpha", phase: "release_changelog", elapsed_seconds: 65.4),
        result("alpha", phase: "release_publish", elapsed_seconds: 3601.2)
      ]
    )

    expect(report.to_text).to include("  elapsed: 1:01:07")
    expect(report.to_h.fetch("summary").fetch("elapsed_seconds")).to eq(3666.6)
  end

  it "includes release transcript log directories in successful release summaries" do
    release_result = result("alpha", phase: "release_publish")
    release_result.log_path = "/repo/alpha/tmp/kettle-family/release-20260731-101010-123/alpha-release_publish.log"
    report = described_class.new(
      family_name: "structuredmerge-ruby",
      order_mode: "dependency",
      members: [member("alpha")],
      selected_members: [member("alpha")],
      config_path: nil,
      command: "release",
      results: [release_result]
    )

    expect(report.to_text).to include("  logs: /repo/alpha/tmp/kettle-family/release-20260731-101010-123")
    expect(report.to_h.fetch("summary").fetch("release_log_dirs")).to eq(
      ["/repo/alpha/tmp/kettle-family/release-20260731-101010-123"]
    )
  end

  it "summarizes successful bump members with their commit phases" do
    report = described_class.new(
      family_name: "rubocop-lts",
      order_mode: "dependency",
      members: [member("alpha"), member("beta")],
      selected_members: [member("alpha"), member("beta")],
      config_path: nil,
      command: "bump",
      results: [
        result("alpha", phase: "bump"),
        result("beta", phase: "bump"),
        result("alpha", phase: "commit_version_bump"),
        result("beta", phase: "commit_version_bump")
      ]
    )

    expect(report.to_text).to include("succeeded: alpha, beta")
    expect(report.to_h.fetch("summary").fetch("succeeded")).to eq(%w[alpha beta])
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

  it "does not count template-sync-only members as templated" do
    report = described_class.new(
      family_name: "galtzo-floss",
      order_mode: "dependency",
      members: [member("alpha"), member("beta"), member("gamma")],
      selected_members: [member("alpha"), member("beta"), member("gamma")],
      config_path: nil,
      command: "template",
      results: [
        result("alpha", phase: "template"),
        result("beta", phase: "prepare_template_dependencies", success: false, reason: "command failed"),
        result("gamma", phase: "template_sync")
      ]
    )

    summary = report.to_h.fetch("summary")
    text = report.to_text

    expect(summary.fetch("succeeded")).to eq(["alpha"])
    expect(summary.fetch("failed")).to eq([
      {"member" => "beta", "phase" => "prepare_template_dependencies", "reason" => "command failed"}
    ])
    expect(summary.fetch("pending")).to eq([
      {"member" => "gamma", "phase" => "template", "reason" => "not run after earlier failure"}
    ])
    expect(text).to include("  1/3 members ok")
    expect(text).to include("pending: gamma template (not run after earlier failure)")
  end

  it "does not count dependency floor-only members as released in release summaries" do
    report = described_class.new(
      family_name: "galtzo-floss",
      order_mode: "dependency",
      members: [member("alpha"), member("beta"), member("gamma")],
      selected_members: [member("alpha"), member("beta"), member("gamma")],
      config_path: nil,
      command: "release",
      release_mode: "publish",
      results: [
        result("alpha", phase: "release_publish"),
        result("beta", phase: "dependency_floor"),
        result("gamma", phase: "dependency_floor"),
        result("beta", phase: "dependency_floor_lockfiles", success: false, reason: "dependency floor lockfile refresh failed")
      ]
    )

    summary = report.to_h.fetch("summary")
    text = report.to_text

    expect(report).not_to be_success
    expect(summary.fetch("succeeded")).to eq(["alpha"])
    expect(summary.fetch("failed")).to eq([
      {"member" => "beta", "phase" => "dependency_floor_lockfiles", "reason" => "dependency floor lockfile refresh failed"}
    ])
    expect(summary.fetch("pending")).to eq([
      {"member" => "gamma", "phase" => "release", "reason" => "not run after earlier failure"}
    ])
    expect(text).to include("succeeded: alpha")
    expect(text).to include("pending: gamma release (not run after earlier failure)")
  end
end
