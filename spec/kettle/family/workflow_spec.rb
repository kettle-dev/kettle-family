# frozen_string_literal: true

require "fileutils"
require "gitmoji/regex"
require "tmpdir"

RSpec.describe Kettle::Family::Workflow do
  around do |example|
    Dir.mktmpdir("kettle-family-workflow-spec") do |dir|
      @tmpdir = dir
      example.run
    end
  end

  it "uses configured commands and stops on first execution failure" do
    write_config(command: [RbConfig.ruby, "-e", "exit 3"])
    alpha = member_at("alpha")
    beta = member_at("beta")
    config = Kettle::Family::Config.load(root: @tmpdir)

    results = described_class.new(command: "test", config: config, members: [alpha, beta], execute: true).results

    expect(results.size).to eq(1)
    expect(results.first.member_name).to eq("alpha")
    expect(results.first.status).to eq(3)
  end

  it "plans default commands without executing them" do
    config = Kettle::Family::Config.load(root: @tmpdir)
    member = member_at("alpha")

    results = described_class.new(command: "lint", config: config, members: [member]).results

    expect(results.first.skipped).to be(true)
    expect(results.first.command).to eq(["sh", "-lc", "bundle exec rake rubocop_gradual"])
  end

  it "plans template preparation through the member bundle when templating wiring is present" do
    config = Kettle::Family::Config.load(root: @tmpdir)
    member = member_at("alpha")
    File.write(File.join(member.root, "Gemfile"), <<~RUBY)
      source "https://gem.coop"
      gemspec
      eval_gemfile "gemfiles/modular/templating.gemfile" if ENV.fetch("K_JEM_TEMPLATING", "false") == "true"
    RUBY

    results = described_class.new(command: "template", config: config, members: [member]).results

    expect(results.first.phase).to eq("prepare_template_dependencies")
    expect(results.first.command).to eq(["sh", "-lc", "bundle exec kettle-jem prepare --quiet --events"])
  end

  it "uses gitmoji-valid generated commit subjects" do
    # Commit subjects are embedded in shell command literals, so scan only the
    # generated command source rather than trying to parse shell with Ruby AST.
    subjects = %w[workflow cli].flat_map do |source|
      File.read(File.expand_path("../../../lib/kettle/family/#{source}.rb", __dir__))
        .scan(/git commit -m '([^']+)'/)
        .flatten
    end

    expect(subjects).not_to be_empty
    expect(subjects).to all(match(Gitmoji::Regex::REGEX))
    expect(subjects.map { |subject| subject =~ Gitmoji::Regex::REGEX }).to all(eq(0))
  end

  it "runs internal check results" do
    config = Kettle::Family::Config.load(root: @tmpdir)
    member = member_at("alpha")

    results = described_class.new(command: "check", config: config, members: [member]).results

    expect(results.first.phase).to eq("check")
    expect(results.first.command).to eq(["internal", "readiness"])
  end

  it "plans Gemfile.lock resets with checksum-gap updates" do
    config = Kettle::Family::Config.load(root: @tmpdir)
    member = member_at("alpha")
    write_lockfile(member.root, <<~LOCK)
      GEM
        remote: https://gem.coop/
        specs:
          alpha (1.0.0)
          beta (2.0.0)

      CHECKSUMS
        alpha (1.0.0)
        beta (2.0.0) sha256=abc123
    LOCK

    results = described_class.new(command: "reset", reset_target: "Gemfile.lock", config: config, members: [member], commit: false).results

    expect(results.map(&:phase)).to eq(["reset_gemfile_lock"])
    expect(results.first.command).to eq(expected_reset_command)
    expect(results.first.command).not_to include("bundle", "exec", "kettle-reset")
    expect(results.first.command.join("\n")).to include("bundler/inline", "gem \"kettle-dev\"", "https://gem.coop")
    expect(results.first.command.join("\n")).not_to include("gem install")
    expect(results.first.skipped).to be(true)
  end

  it "executes Gemfile.lock resets with local path environments disabled" do
    File.write(File.join(@tmpdir, ".kettle-family.yml"), <<~YAML)
      family:
        local_path_env: KETTLE_DEV_DEV
      release:
        disable_local_path_env:
          - K_JEM_TEMPLATING
    YAML
    fake_bin = File.join(@tmpdir, "bin")
    FileUtils.mkdir_p(fake_bin)
    fake_ruby = write_fake_reset_ruby(fake_bin)
    File.write(File.join(fake_bin, "bundle"), <<~RUBY)
      #!/usr/bin/env ruby
      File.write("bundle-reset.txt", [ARGV.join(" "), ENV["KETTLE_DEV_DEV"], ENV["BUNDLE_GEMFILE"]].join("\\n"))
      File.write("Gemfile.lock", <<~LOCK)
        GEM
          remote: https://gem.coop/
          specs:
            alpha (1.0.0)

        CHECKSUMS
          alpha (1.0.0) sha256=abc123
      LOCK
      exit(0)
    RUBY
    FileUtils.chmod("+x", File.join(fake_bin, "bundle"))
    config = Kettle::Family::Config.load(root: @tmpdir)
    member = member_at("alpha")
    write_gemfile(member.root)
    write_lockfile(member.root, <<~LOCK)
      PATH
        remote: #{@tmpdir}/beta
        specs:
          beta (2.0.0)

      GEM
        remote: https://gem.coop/
        specs:
          alpha (1.0.0)

      CHECKSUMS
        alpha (1.0.0)
    LOCK

    results = described_class.new(
      command: "reset",
      reset_target: "Gemfile.lock",
      config: config,
      members: [member],
      execute: true,
      commit: false,
      env_overrides: {
        "KETTLE_FAMILY_RESET_RUBY" => fake_ruby,
        "PATH" => "#{fake_bin}:#{ENV.fetch("PATH")}"
      }
    ).results

    expect(results.map(&:phase)).to eq(["reset_gemfile_lock"])
    expect(results.first).to be_ok
    expect(File.read(File.join(member.root, "bundle-reset.txt"))).to eq("lock --update --add-checksums\nfalse\n#{File.join(member.root, "Gemfile")}")
    expect(File.read(File.join(member.root, "reset-helper.txt"))).to include("release-lockfiles", "true", "\n")
  end

  it "executes Gemfile.lock resets without materializing the broken member bundle" do
    fake_bin = File.join(@tmpdir, "bin")
    FileUtils.mkdir_p(fake_bin)
    fake_ruby = write_fake_reset_ruby(fake_bin)
    File.write(File.join(fake_bin, "bundle"), <<~RUBY)
      #!/usr/bin/env ruby
      File.write("bundle-reset.txt", [ARGV.join(" "), ENV["BUNDLE_GEMFILE"]].join("\\n"))
      File.write("Gemfile.lock", <<~LOCK)
        PATH
          remote: .
          specs:
            alpha (1.0.0)

        GEM
          remote: https://gem.coop/
          specs:
            kettle-dev (2.3.10)

        CHECKSUMS
          kettle-dev (2.3.10) sha256=abc123
      LOCK
      exit(0)
    RUBY
    FileUtils.chmod("+x", File.join(fake_bin, "bundle"))
    config = Kettle::Family::Config.load(root: @tmpdir)
    member = member_at("alpha")
    write_gemfile(member.root)
    write_lockfile(member.root, <<~LOCK)
      PATH
        remote: .
        specs:
          alpha (1.0.0)

      GEM
        remote: https://gem.coop/
        specs:
          kettle-dev (999.999.999)

      CHECKSUMS
        kettle-dev (999.999.999)
    LOCK

    results = described_class.new(
      command: "reset",
      reset_target: "Gemfile.lock",
      config: config,
      members: [member],
      execute: true,
      commit: false,
      env_overrides: {
        "KETTLE_FAMILY_RESET_RUBY" => fake_ruby,
        "PATH" => "#{fake_bin}:#{ENV.fetch("PATH")}"
      }
    ).results

    expect(results.map(&:phase)).to eq(["reset_gemfile_lock"])
    expect(results.first).to be_ok
    expect(File.read(File.join(member.root, "bundle-reset.txt"))).to eq("lock --update --add-checksums\n#{File.join(member.root, "Gemfile")}")
    expect(File.read(File.join(member.root, "reset-helper.txt"))).to include("release-lockfiles", "true", "\n")
  end

  it "fails Gemfile.lock resets that leave release-invalid lockfiles" do
    fake_bin = File.join(@tmpdir, "bin")
    FileUtils.mkdir_p(fake_bin)
    fake_ruby = write_fake_reset_ruby(fake_bin)
    File.write(File.join(fake_bin, "bundle"), <<~RUBY)
      #!/usr/bin/env ruby
      File.write("Gemfile.lock", <<~LOCK)
        PATH
          remote: #{@tmpdir}/beta
          specs:
            beta (2.0.0)

        GEM
          remote: https://gem.coop/
          specs:
            alpha (1.0.0)

        CHECKSUMS
          alpha (1.0.0)
      LOCK
      exit(0)
    RUBY
    FileUtils.chmod("+x", File.join(fake_bin, "bundle"))
    config = Kettle::Family::Config.load(root: @tmpdir)
    member = member_at("alpha")
    write_gemfile(member.root)
    write_lockfile(member.root, <<~LOCK)
      GEM
        remote: https://gem.coop/
        specs:
          alpha (1.0.0)

      CHECKSUMS
        alpha (1.0.0)
    LOCK

    results = described_class.new(
      command: "reset",
      reset_target: "Gemfile.lock",
      config: config,
      members: [member],
      execute: true,
      commit: false,
      env_overrides: {
        "KETTLE_FAMILY_RESET_RUBY" => fake_ruby,
        "PATH" => "#{fake_bin}:#{ENV.fetch("PATH")}"
      }
    ).results

    expect(results.map(&:phase)).to eq(%w[reset_gemfile_lock reset_gemfile_lock_readiness])
    expect(results.last).not_to be_ok
    expect(results.last.stderr).to include("Gemfile.lock has local path remote")
  end

  it "plans GitHub Actions SHA pin writes with the default patch upgrade" do
    config = Kettle::Family::Config.load(root: @tmpdir)
    member = member_at("alpha")

    results = described_class.new(command: "gha-sha-pins", config: config, members: [member]).results

    expect(results.first.phase).to eq("gha-sha-pins")
    expect(results.first.command).to eq(["sh", "-lc", "bundle exec kettle-gha-pins --write --upgrade patch --events"])
  end

  it "reviews family action metadata once before running member pin updates offline" do
    fake_bin = File.join(@tmpdir, "bin")
    FileUtils.mkdir_p(fake_bin)
    File.write(File.join(fake_bin, "bundle"), <<~RUBY)
      #!/usr/bin/env ruby
      require "json"
      File.open("gha-calls.log", "a") { |file| file.puts(ARGV.join(" ")) }
      if ARGV.include?("--list")
        puts JSON.generate("schema_version" => 1, "repositories" => ["actions/checkout"])
      elsif ARGV.include?("--review")
        puts JSON.generate("mode" => "review", "repositories" => [{"repository" => "actions/checkout"}])
      end
    RUBY
    FileUtils.chmod("+x", File.join(fake_bin, "bundle"))
    config = Kettle::Family::Config.load(root: @tmpdir)
    alpha = member_at("alpha")
    beta = member_at("beta")

    results = described_class.new(
      command: "gha-sha-pins",
      config: config,
      members: [alpha, beta],
      execute: true,
      commit: false,
      env_overrides: {"PATH" => "#{fake_bin}:#{ENV.fetch("PATH")}"}
    ).results

    expect(results.map(&:phase)).to eq(%w[gha_sha_pins_list gha_sha_pins_list gha_sha_pins_review gha-sha-pins gha-sha-pins])
    member_commands = results.select { |result| result.phase == "gha-sha-pins" }.map(&:command)
    expect(member_commands).to all(satisfy { |command| command.join(" ").include?("--offline") })
    expect(File.read(File.join(alpha.root, "gha-calls.log")).lines.grep(/--list/).length).to eq(1)
    expect(File.read(File.join(beta.root, "gha-calls.log")).lines.grep(/--list/).length).to eq(1)
    expect(File.read(File.join(alpha.root, "gha-calls.log")).lines.grep(/--review/).length).to eq(1)
  end

  it "plans full bundle updates by default" do
    config = Kettle::Family::Config.load(root: @tmpdir)
    member = member_at("alpha")

    results = described_class.new(command: "bup", config: config, members: [member]).results

    expect(results.first.phase).to eq("bup")
    expect(results.first.command).to eq(%w[bundle update --all])
    expect(results.fetch(1).phase).to eq("commit_bundle_update")
  end

  it "preserves explicitly requested local path environments for bundle updates" do
    File.write(File.join(@tmpdir, ".kettle-family.yml"), <<~YAML)
      family:
        local_path_env: KETTLE_DEV_DEV
    YAML
    config = Kettle::Family::Config.load(root: @tmpdir)
    member = member_at("alpha")
    File.write(File.join(member.root, "mise.toml"), "[env]\n")

    workflow = described_class.new(
      command: "bup",
      config: config,
      members: [member],
      env_overrides: {"KETTLE_DEV_DEV" => "true", "K_JEM_TEMPLATING" => "true"}
    )

    expect(workflow.send(:bundle_update_env).fetch("KETTLE_DEV_DEV")).to eq("true")
    expect(workflow.send(:bundle_update_env).fetch("K_JEM_TEMPLATING")).to eq("true")
  end

  it "disables family local path environments for bundle updates even when release env already disables them" do
    File.write(File.join(@tmpdir, ".kettle-family.yml"), <<~YAML)
      family:
        local_path_env: STRUCTUREDMERGE_DEV
        members_root: gems
      release:
        env:
          STRUCTUREDMERGE_DEV: false
    YAML
    config = Kettle::Family::Config.load(root: @tmpdir)
    member = member_at("alpha")

    workflow = described_class.new(command: "bup", config: config, members: [member])

    expect(config.family_local_path_env).to eq("STRUCTUREDMERGE_DEV" => File.join(@tmpdir, "gems"))
    expect(workflow.send(:bundle_update_env).fetch("STRUCTUREDMERGE_DEV")).to eq("false")
  end

  it "preserves explicitly requested local path environments for bundler updates" do
    File.write(File.join(@tmpdir, ".kettle-family.yml"), <<~YAML)
      family:
        local_path_env: KETTLE_DEV_DEV
    YAML
    config = Kettle::Family::Config.load(root: @tmpdir)
    member = member_at("alpha")

    workflow = described_class.new(
      command: "bupb",
      config: config,
      members: [member],
      env_overrides: {"KETTLE_DEV_DEV" => "yes"}
    )

    expect(workflow.send(:bundle_update_env).fetch("KETTLE_DEV_DEV")).to eq("yes")
  end

  it "does not commit bundle updates that produce local path lockfile remotes" do
    fake_bin = File.join(@tmpdir, "bin")
    FileUtils.mkdir_p(fake_bin)
    File.write(File.join(fake_bin, "bundle"), <<~RUBY)
      #!/usr/bin/env ruby
      File.write("Gemfile.lock", "PATH\\n  remote: #{@tmpdir}/beta\\n")
      exit(0)
    RUBY
    FileUtils.chmod("+x", File.join(fake_bin, "bundle"))
    config = Kettle::Family::Config.load(root: @tmpdir)
    member = member_at("alpha")

    results = described_class.new(
      command: "bup",
      config: config,
      members: [member],
      execute: true,
      env_overrides: {"PATH" => "#{fake_bin}:#{ENV.fetch("PATH")}"}
    ).results

    expect(results.map(&:phase)).to eq(%w[bup bundle_update_readiness])
    expect(results.last).not_to be_ok
    expect(results.last.reason).to eq("bundle update produced release-invalid lockfile")
    expect(results.last.stdout).to include("release lockfile has local path remote")
  end

  it "plans named bundle updates when bup args are provided" do
    config = Kettle::Family::Config.load(root: @tmpdir)
    member = member_at("alpha")

    results = described_class.new(command: "bup", config: config, members: [member], bup_args: ["rake"]).results

    expect(results.first.command).to eq(%w[bundle update rake])
  end

  it "skips bundle update commits when commits are disabled" do
    config = Kettle::Family::Config.load(root: @tmpdir)
    member = member_at("alpha")

    results = described_class.new(command: "bup", config: config, members: [member], commit: false).results

    expect(results.map(&:phase)).to eq(["bup"])
  end

  it "plans bundler updates" do
    config = Kettle::Family::Config.load(root: @tmpdir)
    member = member_at("alpha")

    results = described_class.new(command: "bupb", config: config, members: [member]).results

    expect(results.first.phase).to eq("bupb")
    expect(results.first.command).to eq(%w[bundle update --bundler])
    expect(results.fetch(1).phase).to eq("commit_bundle_update")
  end

  it "updates the appraisal root lockfile and resets appraisal lockfiles with bupb" do
    config = Kettle::Family::Config.load(root: @tmpdir)
    member = member_at("alpha")
    File.write(File.join(member.root, "Appraisal.root.gemfile"), "gemspec\n")

    results = described_class.new(command: "bupb", config: config, members: [member]).results

    expect(results.map(&:phase)).to eq(%w[bupb bupb_appraisal_root bupb_appraisal_reset commit_bundle_update])
    expect(results.fetch(1).command).to eq(%w[bundle update --bundler])
    expect(results.fetch(2).command).to eq(%w[bundle exec rake appraisal:reset])
  end

  it "targets Appraisal.root.gemfile.lock only for the appraisal root bupb phase" do
    fake_bin = File.join(@tmpdir, "bin")
    FileUtils.mkdir_p(fake_bin)
    File.write(File.join(fake_bin, "bundle"), <<~RUBY)
      #!/usr/bin/env ruby
      File.open("bupb-env.txt", "a") do |file|
        file.puts([ARGV.join(" "), ENV["BUNDLE_GEMFILE"], ENV["BUNDLE_LOCKFILE"]].inspect)
      end
    RUBY
    FileUtils.chmod("+x", File.join(fake_bin, "bundle"))

    config = Kettle::Family::Config.load(root: @tmpdir)
    member = member_at("alpha")
    File.write(File.join(member.root, "Appraisal.root.gemfile"), "gemspec\n")

    results = described_class.new(
      command: "bupb",
      config: config,
      members: [member],
      execute: true,
      commit: false,
      env_overrides: {"PATH" => "#{fake_bin}:#{ENV.fetch("PATH")}"}
    ).results

    expect(results).to all(be_ok)
    calls = File.readlines(File.join(member.root, "bupb-env.txt"), chomp: true)
    expect(calls).to include(include("Appraisal.root.gemfile", "Appraisal.root.gemfile.lock"))
    expect(calls.count { |call| call.include?("appraisal:reset") }).to eq(1)
  end

  it "plans bundle exec commands with provided args" do
    config = Kettle::Family::Config.load(root: @tmpdir)
    member = member_at("alpha")

    results = described_class.new(command: "bex", config: config, members: [member], bex_args: %w[rake spec]).results

    expect(results.first.phase).to eq("bex")
    expect(results.first.command).to eq(%w[bundle exec rake spec])
    expect(results.fetch(1).phase).to eq("commit_bex")
  end

  it "skips bundle exec commits when commits are disabled" do
    config = Kettle::Family::Config.load(root: @tmpdir)
    member = member_at("alpha")

    results = described_class.new(command: "bex", config: config, members: [member], bex_args: %w[rake spec], commit: false).results

    expect(results.map(&:phase)).to eq(["bex"])
  end

  it "plans GitHub Actions SHA pin checks with the selected upgrade level" do
    config = Kettle::Family::Config.load(root: @tmpdir)
    member = member_at("alpha")

    results = described_class.new(
      command: "gha-sha-pins",
      config: config,
      members: [member],
      gha_sha_pins_check: true,
      gha_sha_pins_upgrade: "minor"
    ).results

    expect(results.first.command).to eq(["sh", "-lc", "bundle exec kettle-gha-pins --check --upgrade minor --events"])
  end

  it "plans member workflow commands across member-local target branches" do
    config = Kettle::Family::Config.load(root: @tmpdir)
    member = member_at("alpha")
    File.write(File.join(member.root, ".kettle-family.yml"), <<~YAML)
      release:
        target_branches:
          - r1
          - r2
    YAML

    results = described_class.new(command: "lint", config: config, members: [member]).results

    expect(results.map(&:phase)).to eq(%w[release_checkout lint release_checkout lint])
    expect(results.select { |result| result.phase == "release_checkout" }.map(&:command)).to eq([
      ["git", "checkout", "r1"],
      ["git", "checkout", "r2"]
    ])
  end

  def write_config(command:)
    File.write(File.join(@tmpdir, ".kettle-family.yml"), <<~YAML)
      commands:
        test:
          - #{command[0].dump}
          - #{command[1].dump}
          - #{command[2].dump}
    YAML
  end

  def member_at(name)
    root = File.join(@tmpdir, name)
    FileUtils.mkdir_p(root)
    Kettle::Family::Member.new(name: name, root: root, gemspec_path: File.join(root, "#{name}.gemspec"), version: "1.0.0", dependencies: [])
  end

  def write_lockfile(root, content)
    File.write(File.join(root, "Gemfile.lock"), content)
  end

  def write_gemfile(root)
    File.write(File.join(root, "Gemfile"), <<~RUBY)
      source "https://gem.coop"
      gemspec
    RUBY
  end

  def expected_reset_command
    [
      "env",
      "-u",
      "BUNDLE_BIN_PATH",
      "-u",
      "BUNDLE_FROZEN",
      "-u",
      "BUNDLE_GEMFILE",
      "-u",
      "BUNDLER_VERSION",
      "-u",
      "RUBYOPT",
      RbConfig.ruby,
      "-e",
      described_class::RESET_LOCKFILE_HELPER,
      "release-lockfiles"
    ]
  end

  def write_fake_reset_ruby(fake_bin)
    path = File.join(fake_bin, "fake-reset-ruby")
    File.write(path, <<~RUBY)
      #!/usr/bin/env ruby
      script = ARGV.fetch(1)
      File.write("reset-helper.txt", [ARGV.join(" "), script.include?("https://gem.coop"), ENV["BUNDLE_GEMFILE"].inspect].join("\\n"))
      ENV["BUNDLE_GEMFILE"] = File.expand_path("Gemfile", Dir.pwd)
      system("bundle", "lock", "--update", "--add-checksums")
      exit($?.exitstatus)
    RUBY
    FileUtils.chmod("+x", path)
    path
  end
end
