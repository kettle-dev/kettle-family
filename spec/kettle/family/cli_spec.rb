# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "stringio"
require "tmpdir"

RSpec.describe Kettle::Family::CLI do
  around do |example|
    Dir.mktmpdir("kettle-family-cli-spec") do |dir|
      @tmpdir = dir
      example.run
    end
  end

  it "prints a JSON discovery report" do
    write_gem("alpha")
    out = StringIO.new
    err = StringIO.new

    status = described_class.call(["discover", "--root", @tmpdir, "--json"], out: out, err: err)

    expect(status).to eq(0)
    expect(err.string).to eq("")
    report = JSON.parse(out.string)
    expect(report.fetch("family")).to eq(File.basename(@tmpdir))
    expect(report.fetch("selected_members")).to eq(["alpha"])
  end

  it "prints a metadata table" do
    write_gem("alpha", license: "MIT", authors: ["Example Author"], required_ruby_version: ">= 3.2")
    out = StringIO.new

    status = described_class.call(["metadata", "--root", @tmpdir], out: out, err: StringIO.new)

    expect(status).to eq(0)
    expect(out.string).to include("metadata:")
    expect(out.string).to include("gem    version  ruby    licenses  authors")
    expect(out.string).to include("alpha  1.0.0    >= 3.2  MIT       Example Author")
  end

  it "writes JSON reports without forcing JSON stdout" do
    write_gem("alpha")
    out = StringIO.new
    report_path = File.join(@tmpdir, "tmp", "family-report.json")

    status = described_class.call(["plan", "--root", @tmpdir, "--report", report_path], out: out, err: StringIO.new)

    expect(status).to eq(0)
    expect(out.string).to include("family:")
    expect(JSON.parse(File.read(report_path)).fetch("selected_members")).to eq(["alpha"])
  end

  it "prints help" do
    out = StringIO.new

    status = described_class.call(["help"], out: out, err: StringIO.new)

    expect(status).to eq(0)
    expect(out.string).to include("Usage: kettle-family")
    expect(out.string).not_to include("branch-lanes")
  end

  it "rejects unknown commands" do
    err = StringIO.new

    status = described_class.call(["unknown"], out: StringIO.new, err: err)

    expect(status).to eq(1)
    expect(err.string).to include("unknown command")
  end

  it "rejects invalid options" do
    err = StringIO.new

    status = described_class.call(["discover", "--bad"], out: StringIO.new, err: err)

    expect(status).to eq(1)
    expect(err.string).to include("invalid option")
  end

  it "runs through the executable entrypoint" do
    write_gem("alpha")

    stdout, stderr, status = Open3.capture3(
      clean_entrypoint_env,
      RbConfig.ruby,
      "-Ilib",
      "exe/kettle-family",
      "discover",
      "--root",
      @tmpdir,
      "--json"
    )

    expect(status).to be_success
    expect(stderr).to eq("")
    expect(JSON.parse(stdout).fetch("selected_members")).to eq(["alpha"])
  end

  it "plans workflow commands by default" do
    write_gem("alpha")
    out = StringIO.new

    status = described_class.call(["test", "--root", @tmpdir], out: out, err: StringIO.new)

    expect(status).to eq(0)
    expect(out.string).to include("skipped alpha test")
    expect(out.string).to include("pass --execute")
  end

  it "plans releases for comma-separated only members" do
    write_ready_gem("alpha")
    write_ready_gem("beta")
    write_ready_gem("gamma")
    out = StringIO.new

    status = described_class.call(["release", "--root", @tmpdir, "--only", "gamma,alpha"], out: out, err: StringIO.new)

    expect(status).to eq(0)
    expect(out.string).to include("* alpha")
    expect(out.string).to include("- beta")
    expect(out.string).to include("* gamma")
    expect(out.string.scan("release_build").size).to eq(2)
    expect(out.string).to include("skipped alpha release_build")
    expect(out.string).not_to include("skipped beta release_build")
    expect(out.string).to include("skipped gamma release_build")
  end

  it "plans full bundle updates with bup" do
    write_gem("alpha")
    out = StringIO.new

    status = described_class.call(["bup", "--root", @tmpdir, "--json"], out: out, err: StringIO.new)

    expect(status).to eq(0)
    result = JSON.parse(out.string).fetch("results").first
    expect(result.fetch("phase")).to eq("bup")
    expect(result.fetch("command")).to eq(%w[bundle update --all])
  end

  it "plans named bundle updates with bup ARG" do
    write_gem("alpha")
    out = StringIO.new

    status = described_class.call(["bup", "rake", "--root", @tmpdir, "--json"], out: out, err: StringIO.new)

    expect(status).to eq(0)
    result = JSON.parse(out.string).fetch("results").first
    expect(result.fetch("phase")).to eq("bup")
    expect(result.fetch("command")).to eq(%w[bundle update rake])
  end

  it "plans bundler updates with bupb" do
    write_gem("alpha")
    out = StringIO.new

    status = described_class.call(["bupb", "--root", @tmpdir, "--json"], out: out, err: StringIO.new)

    expect(status).to eq(0)
    result = JSON.parse(out.string).fetch("results").first
    expect(result.fetch("phase")).to eq("bupb")
    expect(result.fetch("command")).to eq(%w[bundle update --bundler])
  end

  it "plans bundle exec commands with bex" do
    write_gem("alpha")
    out = StringIO.new

    status = described_class.call(["bex", "rake", "spec", "--root", @tmpdir, "--json"], out: out, err: StringIO.new)

    expect(status).to eq(0)
    result = JSON.parse(out.string).fetch("results").first
    expect(result.fetch("phase")).to eq("bex")
    expect(result.fetch("command")).to eq(%w[bundle exec rake spec])
  end

  it "preserves bundle exec command flags after the option separator" do
    write_gem("alpha")
    out = StringIO.new

    status = described_class.call(["bex", "--root", @tmpdir, "--json", "--", "rake", "spec", "--trace"], out: out, err: StringIO.new)

    expect(status).to eq(0)
    result = JSON.parse(out.string).fetch("results").first
    expect(result.fetch("command")).to eq(%w[bundle exec rake spec --trace])
  end

  it "rejects bex without a command" do
    err = StringIO.new

    status = described_class.call(["bex", "--root", @tmpdir], out: StringIO.new, err: err)

    expect(status).to eq(1)
    expect(err.string).to include("bex requires COMMAND")
  end

  it "plans local dependency installs before selected family members" do
    write_gem("alpha")
    dep_root = File.join(@tmpdir, "deps", "token-resolver")
    write_gem_at(dep_root, "token-resolver")
    File.write(File.join(@tmpdir, ".kettle-family.yml"), <<~YAML)
      install:
        local_dependencies:
          - deps/token-resolver
    YAML
    out = StringIO.new

    status = described_class.call(["install", "--root", @tmpdir], out: out, err: StringIO.new)

    expect(status).to eq(0)
    expect(out.string).to include("skipped token-resolver install")
    expect(out.string).to include("skipped alpha install")
    expect(out.string.index("token-resolver install")).to be < out.string.index("alpha install")
  end

  it "plans local installs across configured release target branches" do
    write_gem("alpha")
    File.write(File.join(@tmpdir, ".kettle-family.yml"), <<~YAML)
      release:
        target_branches:
          - r1_8-even-v0
          - r1_9-even-v2
    YAML
    out = StringIO.new

    status = described_class.call(["install", "--root", @tmpdir], out: out, err: StringIO.new)

    expect(status).to eq(0)
    expect(out.string.scan("release_checkout").size).to eq(2)
    expect(out.string.scan("alpha install").size).to eq(2)
  end

  it "skips main when planning local installs across configured release target branches" do
    write_gem("alpha")
    File.write(File.join(@tmpdir, ".kettle-family.yml"), <<~YAML)
      release:
        target_branches:
          - main
          - r1_8-even-v0
    YAML
    out = StringIO.new

    status = described_class.call(["install", "--root", @tmpdir], out: out, err: StringIO.new)

    expect(status).to eq(0)
    expect(out.string).to include("release targets: r1_8-even-v0")
    expect(out.string).not_to include("git checkout main")
    expect(out.string.scan("release_checkout").size).to eq(1)
    expect(out.string.scan("alpha install").size).to eq(1)
  end

  it "returns failure status for readiness check failures" do
    write_gem("alpha")
    out = StringIO.new

    status = described_class.call(["check", "--root", @tmpdir], out: out, err: StringIO.new)

    expect(status).to eq(1)
    expect(out.string).to include("failed alpha check")
    expect(out.string).to include("resume: kettle-family check --start-at alpha")
  end

  it "includes branch lane auditing in readiness checks" do
    write_gem("alpha")
    File.write(File.join(@tmpdir, ".kettle-family.yml"), <<~YAML)
      branch_lanes:
        ruby18:
          branch: r1_8-even-v0
          version: "2"
          members:
            - alpha
    YAML
    out = StringIO.new

    status = described_class.call(["check", "--root", @tmpdir], out: out, err: StringIO.new)

    expect(status).to eq(1)
    expect(out.string).to include("ok ruby18 branch_lane_audit")
    expect(out.string).to include("failed alpha check")
  end

  it "plans template commands with member commits by default" do
    write_gem("alpha")
    out = StringIO.new

    status = described_class.call(["template", "--root", @tmpdir], out: out, err: StringIO.new)

    expect(status).to eq(0)
    expect(out.string).to include("skipped alpha template")
    expect(out.string).not_to include("family_commit")
  end

  it "includes main when planning templating across configured release target branches" do
    write_gem("alpha")
    File.write(File.join(@tmpdir, ".kettle-family.yml"), <<~YAML)
      release:
        target_branches:
          - main
          - r1_8-even-v0
    YAML
    out = StringIO.new

    status = described_class.call(["template", "--root", @tmpdir], out: out, err: StringIO.new)

    expect(status).to eq(0)
    expect(out.string).to include("release targets: main, r1_8-even-v0")
    expect(out.string.scan("release_checkout").size).to eq(2)
    expect(out.string.scan("alpha template").size).to eq(2)
  end

  it "includes main when planning GitHub Actions SHA pinning across configured release target branches" do
    write_gem("alpha")
    File.write(File.join(@tmpdir, ".kettle-family.yml"), <<~YAML)
      release:
        target_branches:
          - main
          - r1_8-even-v0
    YAML
    out = StringIO.new

    status = described_class.call(["gha-sha-pins", "--root", @tmpdir], out: out, err: StringIO.new)

    expect(status).to eq(0)
    expect(out.string).to include("release targets: main, r1_8-even-v0")
    expect(out.string.scan("release_checkout").size).to eq(2)
    expect(out.string.scan("alpha gha-sha-pins").size).to eq(2)
    expect(out.string.scan("alpha commit_gha_sha_pins").size).to eq(2)
  end

  it "passes GitHub Actions SHA pin check and upgrade options through the CLI" do
    write_gem("alpha")
    out = StringIO.new

    status = described_class.call(["gha-sha-pins", "--root", @tmpdir, "--check", "--upgrade", "minor", "--json"], out: out, err: StringIO.new)

    expect(status).to eq(0)
    result = JSON.parse(out.string).fetch("results").first
    expect(result.fetch("phase")).to eq("gha-sha-pins")
    expect(result.fetch("command")).to eq(["sh", "-lc", "bundle exec kettle-gha-sha-pins --check --upgrade minor"])
  end

  it "plans workflow environment overrides after mise" do
    write_gem("alpha")
    File.write(File.join(@tmpdir, "alpha", "mise.toml"), "[env]\nK_JEM_TEMPLATING = \"false\"\n")
    out = StringIO.new

    status = described_class.call(
      [
        "template",
        "--root",
        @tmpdir,
        "--env",
        "K_JEM_TEMPLATING=true",
        "--env",
        "SMORG_RB_DEV=/workspace/structuredmerge/ruby/gems",
        "--json"
      ],
      out: out,
      err: StringIO.new
    )

    expect(status).to eq(0)
    command = JSON.parse(out.string).fetch("results").first.fetch("command")
    expect(command).to eq(
      [
        "mise",
        "exec",
        "-C",
        File.join(@tmpdir, "alpha"),
        "--",
        "env",
        "-u",
        "DEBUG",
        "-u",
        "DEBUG_RESOLVER",
        "-u",
        "DEBUG_RESOLVER_TREE",
        "-u",
        "BUNDLER_DEBUG_RESOLVER",
        "-u",
        "BUNDLER_DEBUG_RESOLVER_TREE",
        "-u",
        "DEBUG_COMPACT_INDEX",
        "-u",
        "MOLINILLO_DEBUG",
        "K_JEM_TEMPLATING=true",
        "SMORG_RB_DEV=/workspace/structuredmerge/ruby/gems",
        "KETTLE_JEM_QUIET=true",
        "KETTLE_JEM_DEBUG=false",
        "KETTLE_DEV_DEBUG=false",
        "SMORG_RB_DEBUG=false",
        "BUNDLE_QUIET=true",
        "BUNDLE_DEBUG=false",
        "BUNDLER_DEBUG=false",
        "BUNDLE_VERBOSE=false",
        "BUNDLE_SILENCE_DEPRECATIONS=true",
        "BUNDLE_SILENCE_ROOT_WARNING=true",
        "BUNDLE_SUPPRESS_INSTALL_USING_MESSAGES=true",
        "sh",
        "-lc",
        "kettle-jem install --quiet --json"
      ]
    )
  end

  it "preserves template debug environment only when debug is enabled" do
    write_gem("alpha")
    File.write(File.join(@tmpdir, "alpha", "mise.toml"), "[env]\nDEBUG = \"false\"\n")
    out = StringIO.new

    status = described_class.call(
      [
        "template",
        "--root",
        @tmpdir,
        "--env",
        "DEBUG=true",
        "--env",
        "BUNDLE_DEBUG=true",
        "--debug",
        "--json"
      ],
      out: out,
      err: StringIO.new
    )

    expect(status).to eq(0)
    command = JSON.parse(out.string).fetch("results").first.fetch("command")
    expect(command).to include("DEBUG=true", "BUNDLE_DEBUG=true")
    expect(command).not_to include("DEBUG=false", "BUNDLE_DEBUG=false")
  end

  it "rejects invalid workflow environment overrides" do
    write_gem("alpha")
    err = StringIO.new

    status = described_class.call(["template", "--root", @tmpdir, "--env", "not-valid"], out: StringIO.new, err: err)

    expect(status).to eq(1)
    expect(err.string).to include("--env requires KEY=VALUE")
  end

  it "rejects stray positional arguments after options" do
    write_gem("alpha")
    err = StringIO.new

    status = described_class.call(
      ["template", "--root", @tmpdir, "--env", "K_JEM_TEMPLATING=true", "SMORG_RB_DEV=/workspace"],
      out: StringIO.new,
      err: err
    )

    expect(status).to eq(1)
    expect(err.string).to include("unexpected argument(s): SMORG_RB_DEV=/workspace")
  end

  it "checks version bumps without writing", :prism do
    write_gem("alpha")
    out = StringIO.new

    status = described_class.call(["bump-version", "1.1.0", "--root", @tmpdir, "--check"], out: out, err: StringIO.new)

    expect(status).to eq(1)
    expect(out.string).to include("failed alpha bump-version")
    expect(out.string).to include("version changes required")
  end

  it "accepts kettle-bump style version bump targets", :prism do
    write_gem("alpha")
    initialize_git_repo(@tmpdir)
    out = StringIO.new

    status = described_class.call(["bump-version", "patch", "--root", @tmpdir, "--execute"], out: out, err: StringIO.new)

    expect(status).to eq(0)
    expect(out.string).to include("alpha bump-version")
    expect(out.string).to include("alpha commit_version_bump")
    expect(File.read(File.join(@tmpdir, "alpha", "lib", "alpha", "version.rb"))).to include('VERSION = "1.0.1"')
  end

  it "describes the accepted bump-version targets when omitted" do
    err = StringIO.new

    status = described_class.call(["bump-version"], out: StringIO.new, err: err)

    expect(status).to eq(1)
    expect(err.string).to include("bump-version requires VERSION, major, minor, patch, or pre")
  end

  it "plans version bumps across configured release target branches", :prism do
    write_gem("alpha")
    File.write(File.join(@tmpdir, ".kettle-family.yml"), <<~YAML)
      release:
        target_branches:
          - r1_8-even-v0
          - r1_9-even-v2
    YAML
    out = StringIO.new

    status = described_class.call(["bump-version", "1.1.0", "--root", @tmpdir], out: out, err: StringIO.new)

    expect(status).to eq(0)
    expect(out.string.scan("release_checkout").size).to eq(2)
    expect(out.string.scan("alpha bump-version").size).to eq(2)
    expect(out.string.scan("alpha commit_version_bump").size).to eq(2)
  end

  it "plans version bump commits across configured release target branches", :prism do
    write_gem("alpha")
    File.write(File.join(@tmpdir, ".kettle-family.yml"), <<~YAML)
      release:
        target_branches:
          - r1
          - r2
    YAML
    initialize_git_repo(@tmpdir, branches: %w[r1 r2])
    out = StringIO.new

    status = described_class.call(["bump-version", "patch", "--root", @tmpdir, "--execute"], out: out, err: StringIO.new)

    expect(status).to eq(0)
    expect(out.string.scan("release_checkout").size).to eq(2)
    expect(out.string.scan("alpha bump-version").size).to eq(2)
    expect(out.string.scan("alpha commit_version_bump").size).to eq(2)
    expect(out.string).to include("1.0.0 -> 1.0.1")
    expect(out.string).to include("updated")
    expect(out.string).not_to include("would update")
  end

  it "plans version bumps across member-local release target branches", :prism do
    write_gem("alpha")
    File.write(File.join(@tmpdir, "alpha", ".kettle-family.yml"), <<~YAML)
      release:
        target_branches:
          - r1
          - r2
    YAML
    out = StringIO.new

    status = described_class.call(["bump-version", "patch", "--root", @tmpdir], out: out, err: StringIO.new)

    expect(status).to eq(0)
    expect(out.string).to include("member release targets:")
    expect(out.string).to include("alpha: r1, r2")
    expect(out.string.scan("release_checkout").size).to eq(2)
    expect(out.string.scan("alpha bump-version").size).to eq(2)
    expect(out.string.scan("alpha commit_version_bump").size).to eq(2)
  end

  it "plans local installs across member-local release target branches" do
    write_gem("alpha")
    File.write(File.join(@tmpdir, "alpha", ".kettle-family.yml"), <<~YAML)
      release:
        target_branches:
          - main
          - r1
          - r2
    YAML
    out = StringIO.new

    status = described_class.call(["install", "--root", @tmpdir], out: out, err: StringIO.new)

    expect(status).to eq(0)
    expect(out.string).to include("member release targets:")
    expect(out.string).to include("alpha: r1, r2")
    expect(out.string).not_to include("git checkout main")
    expect(out.string.scan("release_checkout").size).to eq(2)
    expect(out.string.scan("alpha install").size).to eq(2)
  end

  it "plans local installs across root member release target branches" do
    write_gem("alpha")
    File.write(File.join(@tmpdir, ".kettle-family.yml"), <<~YAML)
      release:
        member_target_branches:
          alpha:
            - main
            - r1
            - r2
    YAML
    out = StringIO.new

    status = described_class.call(["install", "--root", @tmpdir], out: out, err: StringIO.new)

    expect(status).to eq(0)
    expect(out.string).to include("member release targets:")
    expect(out.string).to include("alpha: r1, r2")
    expect(out.string).not_to include("git checkout main")
    expect(out.string.scan("release_checkout").size).to eq(2)
    expect(out.string.scan("alpha install").size).to eq(2)
  end

  it "plans local installs from member-local release target config on another branch" do
    write_gem("alpha")
    initialize_git_repo(@tmpdir)
    run_git(@tmpdir, "switch", "--quiet", "-c", "branch-stack-config")
    File.write(File.join(@tmpdir, "alpha", ".kettle-family.yml"), <<~YAML)
      release:
        target_branches:
          - r1
          - r2
    YAML
    run_git(@tmpdir, "add", ".")
    run_git(@tmpdir, "commit", "--quiet", "-m", "Add branch stack config")
    run_git(@tmpdir, "switch", "--quiet", "-")
    out = StringIO.new

    status = described_class.call(["install", "--root", @tmpdir], out: out, err: StringIO.new)

    expect(status).to eq(0)
    expect(out.string).to include("alpha: r1, r2")
    expect(out.string.scan("release_checkout").size).to eq(2)
    expect(out.string.scan("alpha install").size).to eq(2)
  end

  it "plans changelog entry additions per member" do
    write_gem("alpha")
    out = StringIO.new

    status = described_class.call(
      ["add-changelog", "--root", @tmpdir, "--section", "Changed", "--entry", "Added support for JRuby 10.1.", "--json"],
      out: out,
      err: StringIO.new
    )

    expect(status).to eq(0)
    result = JSON.parse(out.string).fetch("results").first
    expect(result.fetch("phase")).to eq("add-changelog")
    expect(result.fetch("command")).to eq([
      File.join(Gem.bindir, "kettle-changelog"),
      "--add-unreleased-entry",
      "--section",
      "Changed",
      "--entry",
      "Added support for JRuby 10.1."
    ])
  end

  it "plans changelog entry additions across configured release target branches" do
    write_gem("alpha")
    File.write(File.join(@tmpdir, ".kettle-family.yml"), <<~YAML)
      release:
        target_branches:
          - r1_8-even-v0
          - r1_9-even-v2
    YAML
    out = StringIO.new

    status = described_class.call(
      ["add-changelog", "--root", @tmpdir, "--section", "Changed", "--entry", "Added support for JRuby 10.1."],
      out: out,
      err: StringIO.new
    )

    expect(status).to eq(0)
    expect(out.string.scan("release_checkout").size).to eq(2)
    expect(out.string.scan("alpha add-changelog").size).to eq(2)
    expect(out.string.scan("commit_changelog").size).to eq(2)
  end

  it "plans changelog entry additions across member-local release target branches" do
    write_gem("alpha")
    File.write(File.join(@tmpdir, "alpha", ".kettle-family.yml"), <<~YAML)
      release:
        target_branches:
          - r1
          - r2
    YAML
    out = StringIO.new

    status = described_class.call(
      ["add-changelog", "--root", @tmpdir, "--section", "Changed", "--entry", "Added support for JRuby 10.1."],
      out: out,
      err: StringIO.new
    )

    expect(status).to eq(0)
    expect(out.string).to include("alpha: r1, r2")
    expect(out.string.scan("release_checkout").size).to eq(2)
    expect(out.string.scan("alpha add-changelog").size).to eq(2)
  end

  it "plans releases in fixed configured order" do
    write_ready_gem("alpha")
    write_ready_gem("beta")
    File.write(File.join(@tmpdir, ".kettle-family.yml"), <<~YAML)
      members:
        order:
          mode: fixed
          hints:
            - beta
            - alpha
    YAML
    out = StringIO.new

    status = described_class.call(["release", "--root", @tmpdir], out: out, err: StringIO.new)

    expect(status).to eq(0)
    expect(out.string).to include("release mode: build-only")
    expect(out.string.index("* beta")).to be < out.string.index("* alpha")
    expect(out.string).to include("skipped beta release_build")
  end

  it "prints publish mode when release publishing is requested" do
    write_ready_gem("alpha")
    out = StringIO.new

    status = described_class.call(["release", "--root", @tmpdir, "--publish"], out: out, err: StringIO.new)

    expect(status).to eq(0)
    expect(out.string).to include("release mode: publish")
    expect(out.string).to include("skipped alpha release_publish")
  end

  it "prints configured release target branches in release plans" do
    write_ready_gem("alpha")
    File.write(File.join(@tmpdir, ".kettle-family.yml"), <<~YAML)
      release:
        target_branches:
          - r1_8-even-v0
          - r1_9-even-v2
    YAML
    out = StringIO.new

    status = described_class.call(["release", "--root", @tmpdir], out: out, err: StringIO.new)

    expect(status).to eq(0)
    expect(out.string).to include("release targets: r1_8-even-v0, r1_9-even-v2")
    expect(out.string).to include("skipped #{File.basename(@tmpdir)} release_checkout")
  end

  it "skips main when planning releases across configured release target branches" do
    write_ready_gem("alpha")
    File.write(File.join(@tmpdir, ".kettle-family.yml"), <<~YAML)
      release:
        target_branches:
          - main
          - r1_8-even-v0
    YAML
    out = StringIO.new

    status = described_class.call(["release", "--root", @tmpdir], out: out, err: StringIO.new)

    expect(status).to eq(0)
    expect(out.string).to include("release targets: r1_8-even-v0")
    expect(out.string).not_to include("git checkout main")
    expect(out.string.scan("release_checkout").size).to eq(1)
    expect(out.string.scan("alpha release_build").size).to eq(1)
  end

  it "plans standalone git sync commands per member" do
    write_gem("alpha")
    write_gem("beta")
    out = StringIO.new

    status = described_class.call(["up", "--root", @tmpdir, "--json"], out: out, err: StringIO.new)

    expect(status).to eq(0)
    results = JSON.parse(out.string).fetch("results")
    expect(results.map { |result| [result.fetch("member"), result.fetch("phase"), result.fetch("command")] }).to eq([
      ["alpha", "pull", %w[git pull --rebase]],
      ["alpha", "push", %w[git push]],
      ["beta", "pull", %w[git pull --rebase]],
      ["beta", "push", %w[git push]]
    ])
  end

  it "plans standalone git sync commands across member-local release target branches" do
    write_gem("alpha")
    File.write(File.join(@tmpdir, "alpha", ".kettle-family.yml"), <<~YAML)
      release:
        target_branches:
          - main
          - r1
    YAML
    out = StringIO.new

    status = described_class.call(["up", "--root", @tmpdir], out: out, err: StringIO.new)

    expect(status).to eq(0)
    expect(out.string).to include("alpha: main, r1")
    expect(out.string.scan("release_checkout").size).to eq(2)
    expect(out.string.scan("alpha pull").size).to eq(2)
    expect(out.string.scan("alpha push").size).to eq(2)
  end

  it "fails hard when an executed standalone git sync command fails" do
    write_gem("alpha")
    write_gem("beta")
    out = StringIO.new

    status = described_class.call(["pull", "--root", @tmpdir, "--execute", "--json"], out: out, err: StringIO.new)

    expect(status).to eq(1)
    results = JSON.parse(out.string).fetch("results")
    expect(results.size).to eq(1)
    expect(results.first.fetch("member")).to eq("alpha")
    expect(results.first.fetch("phase")).to eq("pull")
    expect(results.first.fetch("success")).to be(false)
  end

  it "prints and plans member-local release target branches in root release plans" do
    write_ready_gem("alpha")
    File.write(File.join(@tmpdir, "alpha", ".kettle-family.yml"), <<~YAML)
      release:
        target_branches:
          - r1
          - r2
    YAML
    out = StringIO.new

    status = described_class.call(["release", "--root", @tmpdir], out: out, err: StringIO.new)

    expect(status).to eq(0)
    expect(out.string).to include("member release targets:")
    expect(out.string).to include("alpha: r1, r2")
    expect(out.string.scan("release_checkout").size).to eq(2)
    expect(out.string.scan("alpha release_build").size).to eq(2)
  end

  it "starts member-local release target branches at MEMBER@BRANCH" do
    write_ready_gem("alpha")
    File.write(File.join(@tmpdir, "alpha", ".kettle-family.yml"), <<~YAML)
      release:
        target_branches:
          - r1_8-even-v0
          - r1_9-even-v2
          - r2_0-even-v4
    YAML
    out = StringIO.new

    status = described_class.call(["release", "--root", @tmpdir, "--start-at", "alpha@r1_9-even-v2"], out: out, err: StringIO.new)

    expect(status).to eq(0)
    expect(out.string).to include("alpha: r1_9-even-v2, r2_0-even-v4")
    expect(out.string).not_to include("git checkout r1_8-even-v0")
    expect(out.string.scan("release_checkout").size).to eq(2)
    expect(out.string.scan("alpha release_build").size).to eq(2)
  end

  it "rejects unknown member-local start branches" do
    write_ready_gem("alpha")
    File.write(File.join(@tmpdir, "alpha", ".kettle-family.yml"), <<~YAML)
      release:
        target_branches:
          - r1_8-even-v0
    YAML
    err = StringIO.new

    status = described_class.call(["release", "--root", @tmpdir, "--start-at", "alpha@missing"], out: StringIO.new, err: err)

    expect(status).to eq(1)
    expect(err.string).to include("unknown branch target \"missing\"")
  end

  it "passes release resume options through the CLI" do
    write_ready_gem("alpha")
    out = StringIO.new

    status = described_class.call(
      ["release", "--root", @tmpdir, "--publish", "--start-step", "10", "--skip-steps", "10", "--local-ci", "--continue-ci-failures", "--json"],
      out: out,
      err: StringIO.new
    )

    expect(status).to eq(0)
    report = JSON.parse(out.string)
    release = report.fetch("results").find { |result| result.fetch("phase") == "release_publish" }
    expect(release.fetch("command")).to eq(["sh", "-lc", "bundle exec kettle-release start_step=10 skip_steps=10 --local-ci"])
  end

  it "passes interactive accept mode through release workflows" do
    write_ready_gem("alpha")
    workflow = instance_double(Kettle::Family::Workflow, results: [])
    allow(Kettle::Family::Workflow).to receive(:new).and_return(workflow)

    status = described_class.call(["release", "--root", @tmpdir, "--no-accept"], out: StringIO.new, err: StringIO.new)

    expect(status).to eq(0)
    expect(Kettle::Family::Workflow).to have_received(:new).with(hash_including(accept: false))
  end

  it "prints a release-state table" do
    write_gem("alpha")
    result = Kettle::Family::ReleaseStateResult.new(
      member_name: "alpha",
      command: %w[bundle exec kettle-changelog --release-state --json],
      workdir: File.join(@tmpdir, "alpha"),
      status: 0,
      success: true,
      stdout: "",
      stderr: "",
      elapsed_seconds: 0.1,
      state: {
        "gem_name" => "alpha",
        "version" => "1.2.4",
        "latest_released" => "1.2.3",
        "latest_changelog_version" => "1.2.4",
        "unreleased_entries" => false,
        "prepared_release_pending" => true,
        "pending_release" => true
      }
    )
    checker = instance_double(Kettle::Family::ReleaseStateCheck, results: [result])
    allow(Kettle::Family::ReleaseStateCheck).to receive(:new).and_return(checker)
    out = StringIO.new

    status = described_class.call(["release-state", "--root", @tmpdir], out: out, err: StringIO.new)

    expect(status).to eq(0)
    expect(out.string).to include("release state:")
    expect(out.string).to include("latest released")
    expect(out.string).to include("alpha")
    expect(out.string).to include("1.2.3")
    expect(out.string).to include("yes")
  end

  it "does not require dependency ordering for release-state reports" do
    write_gem("alpha", dependencies: ["beta"])
    write_gem("beta", dependencies: ["alpha"])
    results = %w[alpha beta].map do |name|
      Kettle::Family::ReleaseStateResult.new(
        member_name: name,
        command: %w[bundle exec kettle-changelog --release-state --json],
        workdir: File.join(@tmpdir, name),
        status: 0,
        success: true,
        stdout: "",
        stderr: "",
        elapsed_seconds: 0.1,
        state: {
          "gem_name" => name,
          "version" => "1.0.0",
          "latest_released" => "1.0.0",
          "latest_changelog_version" => "1.0.0",
          "unreleased_entries" => false,
          "prepared_release_pending" => false,
          "pending_release" => false
        }
      )
    end
    checker = instance_double(Kettle::Family::ReleaseStateCheck, results: results)
    allow(Kettle::Family::ReleaseStateCheck).to receive(:new).and_return(checker)

    status = described_class.call(["release-state", "--root", @tmpdir], out: StringIO.new, err: StringIO.new)

    expect(status).to eq(0)
  end

  def write_gem(name, dependencies: [], license: nil, authors: [], required_ruby_version: nil)
    root = File.join(@tmpdir, name)
    write_gem_at(root, name, dependencies: dependencies, license: license, authors: authors, required_ruby_version: required_ruby_version)
  end

  def write_gem_at(root, name, dependencies: [], license: nil, authors: [], required_ruby_version: nil)
    FileUtils.mkdir_p(File.join(root, "lib", name))
    File.write(File.join(root, "lib", name, "version.rb"), <<~RUBY)
      module #{name.capitalize}
        VERSION = "1.0.0"
      end
    RUBY
    metadata_lines = []
    metadata_lines << %(spec.required_ruby_version = "#{required_ruby_version}") if required_ruby_version
    metadata_lines << %(spec.licenses = ["#{license}"]) if license
    metadata_lines << %(spec.authors = #{authors.inspect}) unless authors.empty?
    File.write(File.join(root, "#{name}.gemspec"), <<~RUBY)
      Gem::Specification.new do |spec|
        spec.name = "#{name}"
        spec.version = "1.0.0"
        #{dependencies.map { |dependency| %(spec.add_dependency "#{dependency}") }.join("\n")}
        #{metadata_lines.join("\n")}
      end
    RUBY
  end

  def write_ready_gem(name)
    write_gem(name)
    root = File.join(@tmpdir, name)
    FileUtils.mkdir_p(File.join(root, "bin"))
    %w[Gemfile Rakefile README.md LICENSE.md].each do |path|
      File.write(File.join(root, path), "stub\n")
    end
    File.write(File.join(root, "CHANGELOG.md"), "## [Unreleased]\n")
    %w[bin/rake bin/rspec].each do |path|
      full_path = File.join(root, path)
      File.write(full_path, "#!/bin/sh\n")
      FileUtils.chmod("u+x", full_path)
    end
  end

  def initialize_git_repo(path, branches: [])
    run_git(path, "init", "--quiet")
    run_git(path, "config", "user.email", "kettle-family@example.test")
    run_git(path, "config", "user.name", "Kettle Family")
    run_git(path, "add", ".")
    run_git(path, "commit", "--quiet", "-m", "Initial fixture")
    branches.each { |branch| run_git(path, "branch", branch) }
  end

  def run_git(path, *args)
    stdout, stderr, status = Open3.capture3("git", *args, chdir: path)
    raise "git #{args.join(" ")} failed: #{stderr}#{stdout}" unless status.success?

    stdout
  end

  def clean_entrypoint_env
    {
      "DEBUG" => nil,
      "DEBUG_RESOLVER" => nil,
      "DEBUG_RESOLVER_TREE" => nil,
      "BUNDLER_DEBUG_RESOLVER" => nil,
      "BUNDLER_DEBUG_RESOLVER_TREE" => nil,
      "DEBUG_COMPACT_INDEX" => nil,
      "MOLINILLO_DEBUG" => nil
    }
  end
end
