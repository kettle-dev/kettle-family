# frozen_string_literal: true

require "fileutils"
require "open3"
require "shellwords"
require "tmpdir"
require "yaml"

RSpec.describe Kettle::Family::Workflow do
  around do |example|
    Dir.mktmpdir("kettle-family-template-workflow-spec") do |dir|
      @tmpdir = dir
      example.run
    end
  end

  it "allows member templating commits by default and adds lockfile normalization" do
    write_template_config
    config = Kettle::Family::Config.load(root: @tmpdir)
    member = member_at("alpha")

    results = described_class.new(command: "template", config: config, members: [member]).results

    expect(results.map(&:phase)).to eq(%w[prepare_lockfiles template normalize_lockfiles])
    expect(results.fetch(1).command).not_to include("--skip-commit")
    expect(results.fetch(1).command).not_to include("--quiet")
    expect(results).to all(satisfy(&:skipped))
  end

  it "passes skip-commit to member templating when commits are disabled" do
    write_template_config
    config = Kettle::Family::Config.load(root: @tmpdir)
    member = member_at("alpha")

    results = described_class.new(command: "template", config: config, members: [member], commit: false).results

    expect(results.map(&:phase)).to eq(%w[prepare_lockfiles template normalize_lockfiles])
    expect(results.fetch(1).command).to end_with("--skip-commit")
  end

  it "defers kettle-jem bootstrap commits during executed monorepo templating" do
    write_template_config(command: ["bundle", "exec", "kettle-jem", "install"], normalize_lockfiles: false)
    config = Kettle::Family::Config.load(root: @tmpdir)
    member = member_at("alpha")
    workflow = described_class.new(command: "template", config: config, members: [member], execute: true)

    expect(workflow.send(:template_command, member)).to eq(%w[bundle exec kettle-jem install --quiet --events --skip-commit])
    expect(workflow.send(:template_prepare_command, member)).to eq(%w[bundle exec kettle-jem prepare --quiet --events --skip-commit])
  end

  it "runs the local kettle-jem executable directly when templating from a local StructuredMerge stack" do
    write_template_config(command: ["bundle", "exec", "kettle-jem", "install"], normalize_lockfiles: false)
    local_stack = File.join(@tmpdir, "gems")
    local_exe = File.join(local_stack, "kettle-jem", "exe", "kettle-jem")
    FileUtils.mkdir_p(File.dirname(local_exe))
    File.write(local_exe, "#!/usr/bin/env ruby\n")
    config = Kettle::Family::Config.load(root: @tmpdir)
    member = member_at("alpha")
    workflow = described_class.new(
      command: "template",
      config: config,
      members: [member],
      execute: true,
      env_overrides: {"STRUCTUREDMERGE_DEV" => local_stack}
    )

    expect(workflow.send(:template_command, member)).to eq([
      RbConfig.ruby,
      local_exe,
      "install",
      "--quiet",
      "--events",
      "--skip-commit"
    ])
    expect(workflow.send(:template_prepare_command, member)).to eq([
      RbConfig.ruby,
      local_exe,
      "prepare",
      "--quiet",
      "--events",
      "--skip-commit"
    ])

    expect(workflow.send(:localize_kettle_jem_template_command, "bundle exec kettle-jem install")).to eq([
      RbConfig.ruby,
      local_exe,
      "install"
    ])
  end

  it "serializes deferred monorepo template commits with member-scoped pathspecs" do
    write_template_config(
      command: [RbConfig.ruby, "-e", "File.write('templated.txt', File.basename(Dir.pwd))"],
      normalize_lockfiles: false
    )
    config_hash = YAML.load_file(File.join(@tmpdir, ".kettle-family.yml"))
    config_hash.fetch("template")["command"] = "bundle exec kettle-jem install"
    File.write(File.join(@tmpdir, ".kettle-family.yml"), YAML.dump(config_hash))
    config = Kettle::Family::Config.load(root: @tmpdir)
    alpha = member_at("alpha")
    beta = member_at("beta")
    initialize_git_repo(@tmpdir, branches: [])
    commands = Queue.new
    runner = lambda do |command, chdir:, env:, quiet:|
      command_text = Array(command).join(" ")
      if command_text.include?("kettle-jem prepare") && command_text.include?("--skip-commit")
        {success: true, exitstatus: 0, stdout: "", stderr: ""}
      elsif command_text.include?("kettle-jem install") && command_text.include?("--skip-commit")
        File.write(File.join(chdir, "templated.txt"), File.basename(chdir))
        {success: true, exitstatus: 0, stdout: "", stderr: ""}
      else
        commands << command
        stdout, stderr, status = Open3.capture3(*command, chdir: chdir)
        {success: status.success?, exitstatus: status.exitstatus, stdout: stdout, stderr: stderr}
      end
    end
    allow_any_instance_of(Kettle::Family::CommandRunner).to receive(:call) do |_instance, member:, phase:, command:, env: {}, **_args|
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      result = runner.call(command, chdir: member.root, env: env, quiet: true)
      Kettle::Family::CommandResult.new(
        member.name,
        phase,
        command,
        member.root,
        result.fetch(:exitstatus),
        result.fetch(:success),
        result.fetch(:stdout),
        result.fetch(:stderr),
        (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).round(3),
        false,
        result.fetch(:success) ? nil : "command failed"
      )
    end

    results = described_class.new(command: "template", config: config, members: [alpha, beta], execute: true, jobs: 2).results

    expect(results).to all(be_ok)
    expect(results.map(&:phase)).to eq(%w[prepare_template_dependencies template commit_template prepare_template_dependencies template commit_template])
    expect(commands.size).to eq(2)
    commands.size.times do
      command = commands.pop
      expect(command[0, 2]).to eq(["sh", "-lc"])
      expect(command.fetch(2)).to include("git status --porcelain -- .")
      expect(command.fetch(2)).to include("git add -A -- .")
      expect(command.fetch(2)).to match(/git commit -m .*Template\\ (alpha|beta)\\ by\\ kettle-family/)
    end
    expect(`git -C #{Shellwords.escape(@tmpdir)} status --short`).to eq("")
    log = `git -C #{Shellwords.escape(@tmpdir)} log --format=%s`
    expect(log).to include("🎨 Template alpha by kettle-family")
    expect(log).to include("🎨 Template beta by kettle-family")
  end

  it "serializes template waves for members sharing a git checkout" do
    write_template_config
    config = Kettle::Family::Config.load(root: @tmpdir)
    alpha = member_at("alpha")
    beta = member_at("beta")
    independent = member_at("independent")
    workflow = described_class.new(command: "template", config: config, members: [alpha, beta, independent])

    allow(workflow).to receive(:git_root_for).with(alpha).and_return("/repo/shared")
    allow(workflow).to receive(:git_root_for).with(beta).and_return("/repo/shared")
    allow(workflow).to receive(:git_root_for).with(independent).and_return("/repo/independent")

    waves = workflow.send(:template_dependency_waves, [alpha, beta, independent])

    expect(waves.map { |wave| wave.map(&:name) }).to eq([["alpha", "independent"], ["beta"]])
  end

  it "initializes the template commit mutex before worker threads can race" do
    write_template_config(command: ["bundle", "exec", "kettle-jem", "install"])
    config = Kettle::Family::Config.load(root: @tmpdir)
    workflow = described_class.new(command: "template", config: config, members: [member_at("alpha")], execute: true)

    expect(workflow.instance_variable_get(:@template_commit_mutex)).to be_a(Mutex)

    active = 0
    max_active = 0
    state_mutex = Mutex.new
    start_queue = Queue.new
    # rubocop:disable ThreadSafety/NewThread -- the race regression requires concurrent callers.
    threads = Array.new(8) do
      Thread.new do
        start_queue.pop
        workflow.send(:synchronize_template_commit) do
          state_mutex.synchronize do
            active += 1
            max_active = [max_active, active].max
          end
          sleep 0.01
          state_mutex.synchronize { active -= 1 }
        end
      end
    end
    # rubocop:enable ThreadSafety/NewThread
    threads.length.times { start_queue << true }
    threads.each(&:join)

    expect(max_active).to eq(1)
  end

  it "removes Bundler-reported stale checksum entries and retries pre-template lockfile normalization" do
    normalize_script = <<~RUBY
      lockfile = File.read("Gemfile.lock")
      if lockfile.include?("sha256=bad")
        warn "Bundler found mismatched checksums. This is a potential security risk."
        warn "token-resolver (2.0.6)"
        warn "    from the lockfile CHECKSUMS at Gemfile.lock:9:26"
        exit 1
      end
      File.write("normalized.txt", "ok")
    RUBY
    write_template_config(command: [RbConfig.ruby, "-e", "puts 'templated'"])
    config_hash = YAML.load_file(File.join(@tmpdir, ".kettle-family.yml"))
    config_hash.fetch("template")["normalize_lockfiles_command"] = [RbConfig.ruby, "-e", normalize_script]
    File.write(File.join(@tmpdir, ".kettle-family.yml"), YAML.dump(config_hash))
    config = Kettle::Family::Config.load(root: @tmpdir)
    member = member_at("alpha")
    File.write(File.join(member.root, "Gemfile.lock"), <<~LOCK)
      GEM
        remote: https://gem.coop/
        specs:
          token-resolver (2.0.6)

      CHECKSUMS
        rake (13.3.1) sha256=good
        rspec (3.13.1) sha256=good
        token-resolver (2.0.6) sha256=bad
    LOCK

    results = described_class.new(command: "template", config: config, members: [member], execute: true).results

    expect(results.fetch(0).phase).to eq("prepare_lockfiles")
    expect(results.fetch(0)).to be_ok
    expect(File.read(File.join(member.root, "Gemfile.lock"))).not_to include("token-resolver (2.0.6) sha256=bad")
    expect(File.read(File.join(member.root, "normalized.txt"))).to eq("ok")
  end

  it "updates locked template bootstrap gems before running template preparation for legacy members" do
    write_template_config(
      command: "bundle exec kettle-jem install",
      normalize_lockfiles: true
    )
    config_hash = YAML.load_file(File.join(@tmpdir, ".kettle-family.yml"))
    config_hash.fetch("template")["normalize_lockfiles_command"] = "bundle update --bundler"
    File.write(File.join(@tmpdir, ".kettle-family.yml"), YAML.dump(config_hash))
    config = Kettle::Family::Config.load(root: @tmpdir)
    member = member_at("alpha")
    File.write(File.join(member.root, "Gemfile.lock"), <<~LOCK)
      GEM
        remote: https://gem.coop/
        specs:
          kettle-dev (2.5.0)
          nomono (1.1.0)
    LOCK

    results = described_class.new(command: "template", config: config, members: [member], execute: false).results

    expect(results.fetch(0).phase).to eq("prepare_lockfiles")
    expect(results.fetch(0).command).to eq(["sh", "-lc", "bundle update nomono kettle-dev --bundler"])
    expect(results.fetch(3).phase).to eq("normalize_lockfiles")
    expect(results.fetch(3).command).to eq(["sh", "-lc", "bundle update --bundler"])
  end

  it "installs the bundle before template preparation when the member has no lockfile" do
    write_template_config(
      command: "bundle exec kettle-jem install",
      normalize_lockfiles: true
    )
    config_hash = YAML.load_file(File.join(@tmpdir, ".kettle-family.yml"))
    config_hash.fetch("template")["normalize_lockfiles_command"] = "bundle update --bundler"
    File.write(File.join(@tmpdir, ".kettle-family.yml"), YAML.dump(config_hash))
    config = Kettle::Family::Config.load(root: @tmpdir)
    member = member_at("alpha")

    results = described_class.new(command: "template", config: config, members: [member], execute: false).results

    expect(results.fetch(0).phase).to eq("prepare_lockfiles")
    expect(results.fetch(0).command).to eq(%w[bundle install])
    expect(results.fetch(3).phase).to eq("normalize_lockfiles")
    expect(results.fetch(3).command).to eq(["sh", "-lc", "bundle update --bundler"])
  end

  it "does not update nomono before a legacy member declares it" do
    write_template_config(command: "bundle exec kettle-jem install", normalize_lockfiles: true)
    config_hash = YAML.load_file(File.join(@tmpdir, ".kettle-family.yml"))
    config_hash.fetch("template")["normalize_lockfiles_command"] = "bundle update nomono --bundler"
    File.write(File.join(@tmpdir, ".kettle-family.yml"), YAML.dump(config_hash))
    member = member_at("alpha")
    File.write(File.join(member.root, "Gemfile"), "source \"https://rubygems.org\"\n")
    File.write(File.join(member.root, "Gemfile.lock"), "GEM\n")

    results = described_class.new(
      command: "template",
      config: Kettle::Family::Config.load(root: @tmpdir),
      members: [member],
      execute: false
    ).results

    expect(results.fetch(0).command).to eq(["sh", "-lc", "bundle update --bundler"])
  end

  it "passes template profile and repository topology environment when executing" do
    write_template_config(
      command: [
        RbConfig.ruby,
        "-e",
        "puts [ENV['KETTLE_JEM_TEMPLATE_PROFILE'], ENV['KJ_REPOSITORY_TOPOLOGY']].join('/')",
        "--",
        "--skip-commit"
      ]
    )
    config = Kettle::Family::Config.load(root: @tmpdir)
    member = member_at("alpha")

    results = described_class.new(command: "template", config: config, members: [member], execute: true).results

    expect(results.fetch(1).stdout).to eq("full/standalone\n")
  end

  it "budgets kettle-jem thread workers from family template concurrency" do
    allow(Etc).to receive(:nprocessors).and_return(22)
    config = Kettle::Family::Config.load(root: @tmpdir)
    workflow = described_class.new(command: "template", config: config, members: [member_at("alpha"), member_at("beta")], jobs: 2)

    expect(workflow.send(:workflow_env).fetch("KETTLE_JEM_THREAD_WORKERS")).to eq("10")
    expect(workflow.send(:workflow_env).fetch("BUNDLE_DISABLE_CHECKSUM_VALIDATION")).to eq("true")
  end

  it "preserves an explicit kettle-jem thread worker override" do
    config = Kettle::Family::Config.load(root: @tmpdir)
    workflow = described_class.new(
      command: "template",
      config: config,
      members: [member_at("alpha")],
      env_overrides: {"KETTLE_JEM_THREAD_WORKERS" => "3"}
    )

    expect(workflow.send(:workflow_env).fetch("KETTLE_JEM_THREAD_WORKERS")).to eq("3")
  end

  it "does not inject an implicit family local path env for no-config single-member templating" do
    config = Kettle::Family::Config.load(root: @tmpdir)
    member = Kettle::Family::Member.new(
      name: File.basename(@tmpdir),
      root: @tmpdir,
      gemspec_path: File.join(@tmpdir, "#{File.basename(@tmpdir)}.gemspec"),
      version: "1.0.0",
      dependencies: []
    )
    File.write(File.join(@tmpdir, "mise.toml"), "[env]\nK_JEM_TEMPLATING = \"false\"\n")
    File.write(File.join(@tmpdir, "Gemfile"), <<~RUBY)
      eval_gemfile "gemfiles/modular/templating.gemfile" if ENV.fetch("K_JEM_TEMPLATING", "false").casecmp("true").zero?
    RUBY

    results = described_class.new(
      command: "template",
      config: config,
      members: [member],
      env_overrides: {
        "K_JEM_TEMPLATING" => "true",
        "STRUCTUREDMERGE_DEV" => "/workspace/structuredmerge/ruby/gems"
      }
    ).results

    template_command = results.find { |result| result.phase == "template" }.command
    expect(template_command).not_to include("#{family_local_env_name}=#{@tmpdir}")
    expect(template_command).to include("K_JEM_TEMPLATING=true")
    expect(template_command).to include("STRUCTUREDMERGE_DEV=/workspace/structuredmerge/ruby/gems")
  end

  it "passes a shared git operation lock to monorepo kettle-jem templating" do
    write_template_config(command: ["bundle", "exec", "kettle-jem", "install"])
    config = Kettle::Family::Config.load(root: @tmpdir)
    member = member_at("alpha")
    File.write(File.join(member.root, "mise.toml"), "[env]\n")

    results = described_class.new(command: "template", config: config, members: [member]).results

    expect(results.fetch(1).command).to include(
      "KETTLE_JEM_GIT_LOCK=#{File.join(@tmpdir, ".git", "kettle-family-template-commit.lock")}"
    )
    expect(results.fetch(1).command).to include(
      "KETTLE_JEM_GIT_COMMIT_LOCK=#{File.join(@tmpdir, ".git", "kettle-family-template-commit.lock")}"
    )
  end

  it "does not serialize git commits for sibling repository templating" do
    write_template_config(command: ["bundle", "exec", "kettle-jem", "install"], family_mode: "sibling_repos")
    config = Kettle::Family::Config.load(root: @tmpdir)
    member = member_at("alpha")
    File.write(File.join(member.root, "mise.toml"), "[env]\n")

    results = described_class.new(command: "template", config: config, members: [member]).results

    expect(results.fetch(1).command.join(" ")).not_to include("KETTLE_JEM_GIT_COMMIT_LOCK")
  end

  it "passes family corporate sponsors to kettle-jem templating environment" do
    write_template_config(
      command: [
        RbConfig.ruby,
        "-rjson",
        "-e",
        "puts JSON.parse(ENV.fetch('KETTLE_JEM_CORPORATE_SPONSORS_JSON')).first.fetch('name')",
        "--",
        "--skip-commit"
      ]
    )
    config_path = File.join(@tmpdir, ".kettle-family.yml")
    config_data = YAML.load_file(config_path)
    config_data["readme"] = {
      "corporate_sponsors" => [
        {
          "name" => "Family Sponsor",
          "url" => "https://sponsor.example",
          "img_src" => "https://sponsor.example/logo.svg"
        }
      ]
    }
    File.write(config_path, YAML.dump(config_data))
    config = Kettle::Family::Config.load(root: @tmpdir)
    member = member_at("alpha")

    results = described_class.new(command: "template", config: config, members: [member], execute: true).results

    expect(config.readme_corporate_sponsors).to eq([
      {
        "name" => "Family Sponsor",
        "url" => "https://sponsor.example",
        "img_src" => "https://sponsor.example/logo.svg"
      }
    ])
    expect(results.fetch(1).stdout).to eq("Family Sponsor\n")
  end

  it "executes custom non-kettle-jem template commands without prepare dependency results" do
    write_template_config(
      command: [RbConfig.ruby, "-e", "puts 'custom templated'"],
      normalize_lockfiles: false
    )
    config = Kettle::Family::Config.load(root: @tmpdir)
    member = member_at("alpha")

    results = described_class.new(command: "template", config: config, members: [member], execute: true).results

    expect(results.map(&:phase)).to eq(["template"])
    expect(results.fetch(0).stdout).to eq("custom templated\n")
  end

  it "streams custom non-kettle-jem template commands without prepare dependency results" do
    write_template_config(
      command: [RbConfig.ruby, "-e", "puts 'custom templated'"],
      normalize_lockfiles: false
    )
    config = Kettle::Family::Config.load(root: @tmpdir)
    members = [member_at("alpha"), member_at("beta")]

    results = described_class.new(command: "template", config: config, members: members, execute: true, jobs: 2).results

    expect(results.map(&:phase)).to eq(%w[template template])
    expect(results.map(&:stdout)).to eq(["custom templated\n", "custom templated\n"])
  end

  it "adds quiet JSON flags and disables noisy debug environment for kettle-jem family templating" do
    config = Kettle::Family::Config.load(root: @tmpdir)
    member = member_at("alpha")
    File.write(File.join(member.root, "Gemfile"), <<~RUBY)
      eval_gemfile "gemfiles/modular/templating.gemfile" if ENV.fetch("K_JEM_TEMPLATING", "false").casecmp("true").zero?
    RUBY

    results = described_class.new(command: "template", config: config, members: [member]).results

    expect(results.fetch(0).phase).to eq("prepare_template_dependencies")
    expect(results.fetch(0).command).to eq(["sh", "-lc", "bundle exec kettle-jem prepare --quiet --events"])
    expect(results.fetch(1).command).to eq(["sh", "-lc", "bundle exec kettle-jem install --quiet --events"])
  end

  it "passes verbose mode through to kettle-jem templating while keeping event output" do
    config = Kettle::Family::Config.load(root: @tmpdir)
    member = member_at("alpha")
    File.write(File.join(member.root, "Gemfile"), <<~RUBY)
      eval_gemfile "gemfiles/modular/templating.gemfile" if ENV.fetch("K_JEM_TEMPLATING", "false").casecmp("true").zero?
    RUBY

    results = described_class.new(command: "template", config: config, members: [member], verbose: true).results

    expect(results.fetch(0).command).to eq(["sh", "-lc", "bundle exec kettle-jem prepare --verbose --events"])
    expect(results.fetch(1).command).to eq(["sh", "-lc", "bundle exec kettle-jem install --verbose --events"])
    expect(results.fetch(1).command.join(" ")).not_to include("--quiet")
    expect(results.fetch(1).command.join(" ")).to include("--events")
  end

  it "disables the implicit family local path env during template prepare" do
    config = Kettle::Family::Config.load(root: @tmpdir)
    member = member_at("alpha")
    File.write(File.join(member.root, "mise.toml"), "[env]\n")
    File.write(File.join(member.root, "Gemfile"), <<~RUBY)
      eval_gemfile "gemfiles/modular/templating.gemfile" if ENV.fetch("K_JEM_TEMPLATING", "false").casecmp("true").zero?
    RUBY

    results = described_class.new(command: "template", config: config, members: [member]).results

    expect(results.fetch(0).phase).to eq("prepare_template_dependencies")
    expect(results.fetch(0).command).to include("#{family_local_env_name}=false")
  end

  it "preserves an explicit family local path env during template prepare" do
    config = Kettle::Family::Config.load(root: @tmpdir)
    member = member_at("alpha")
    File.write(File.join(member.root, "mise.toml"), "[env]\n")
    File.write(File.join(member.root, "Gemfile"), <<~RUBY)
      eval_gemfile "gemfiles/modular/templating.gemfile" if ENV.fetch("K_JEM_TEMPLATING", "false").casecmp("true").zero?
    RUBY

    results = described_class.new(
      command: "template",
      config: config,
      members: [member],
      env_overrides: {family_local_env_name => "/explicit/family"}
    ).results

    expect(results.fetch(0).phase).to eq("prepare_template_dependencies")
    expect(results.fetch(0).command).to include("#{family_local_env_name}=/explicit/family")
    expect(results.fetch(0).command).not_to include("#{family_local_env_name}=false")
  end

  it "aligns stale nomono bootstrap dependencies before member template preparation runs" do
    write_template_config(
      command: ["bundle", "exec", "kettle-jem", "install"],
      normalize_lockfiles: false,
      family_mode: "sibling_repos"
    )
    config = Kettle::Family::Config.load(root: @tmpdir)
    alpha = member_at("alpha")
    beta = member_at("beta")
    write_nomono_bundle(alpha, floor: "1.1.0", locked: "1.1.0")
    write_nomono_bundle(beta, floor: "1.1.1", locked: "1.1.1")
    captured_calls = []
    stub_latest_nomono("1.1.1")
    stub_successful_runner(captured_calls)

    results = described_class.new(command: "template", config: config, members: [alpha, beta], execute: true, jobs: 1).results

    expect(results).to all(be_ok)
    expect(results.map { |result| [result.member_name, result.phase] }).to eq([
      ["alpha", "template_bootstrap_dependencies"],
      ["alpha", "template_bootstrap_dependencies"],
      ["alpha", "prepare_template_dependencies"],
      ["alpha", "template"],
      ["beta", "prepare_template_dependencies"],
      ["beta", "template"]
    ])
    bundle_update = captured_calls.find do |call|
      call.fetch(:phase) == "template_bootstrap_dependencies" && call.fetch(:command) == %w[bundle update nomono --bundler]
    end
    expect(bundle_update).not_to be_nil
    expect(bundle_update.fetch(:env)).to include(family_local_env_name => "false")
    expect(File.read(File.join(alpha.root, "Gemfile"))).to include('gem "nomono", "~> 1.1", ">= 1.1.1", require: false')
  end

  it "disables implicit local dependency switches during nomono bootstrap" do
    write_template_config(
      command: ["bundle", "exec", "kettle-jem", "install"],
      normalize_lockfiles: false,
      family_mode: "sibling_repos"
    )
    config = Kettle::Family::Config.load(root: @tmpdir)
    alpha = member_at("alpha")
    write_nomono_bundle(alpha, floor: "1.1.0", locked: "1.1.0")
    captured_calls = []
    stub_latest_nomono("1.1.1")
    stub_successful_runner(captured_calls)

    described_class.new(
      command: "template",
      config: config,
      members: [alpha],
      execute: true,
      jobs: 1,
      env_overrides: {family_local_env_name => "/workspace/family"}
    ).results

    bundle_update = captured_calls.find do |call|
      call.fetch(:phase) == "template_bootstrap_dependencies" && call.fetch(:command) == %w[bundle update nomono --bundler]
    end
    expect(bundle_update.fetch(:env)).to include(family_local_env_name => "/workspace/family")
    expect(bundle_update.fetch(:env)).to include("K_JEM_TEMPLATING" => "false")
    expect(bundle_update.fetch(:env)).to include("BUNDLE_DISABLE_CHECKSUM_VALIDATION" => "true")
  end

  it "fails before member bundles run when an already activated nomono is stale" do
    write_template_config(command: ["bundle", "exec", "kettle-jem", "install"], normalize_lockfiles: false)
    config = Kettle::Family::Config.load(root: @tmpdir)
    member = member_at("alpha")
    write_nomono_bundle(member, floor: "1.1.0", locked: "1.1.0")
    stub_latest_nomono("1.1.1")
    allow(Gem).to receive(:loaded_specs).and_return(
      "nomono" => instance_double(Gem::Specification, version: Gem::Version.new("1.1.0"))
    )
    command_runner = instance_double(Kettle::Family::CommandRunner)
    allow(Kettle::Family::CommandRunner).to receive(:new).and_return(command_runner)
    expect(command_runner).not_to receive(:call)

    results = described_class.new(command: "template", config: config, members: [member], execute: true, jobs: 1).results

    expect(results.length).to eq(1)
    expect(results.first).not_to be_ok
    expect(results.first.phase).to eq("template_bootstrap_dependencies")
    expect(results.first.stderr).to include("activated nomono 1.1.0 is older than latest released 1.1.1")
  end

  it "passes explicit environment overrides through member mise execution" do
    write_template_config(command: ["bundle", "exec", "kettle-jem", "install"])
    config = Kettle::Family::Config.load(root: @tmpdir)
    member = member_at("alpha")
    File.write(File.join(member.root, "mise.toml"), "[env]\nK_JEM_TEMPLATING = \"false\"\n")

    results = described_class.new(
      command: "template",
      config: config,
      members: [member],
      env_overrides: {
        "K_JEM_TEMPLATING" => "true",
        "STRUCTUREDMERGE_DEV" => "/workspace/structuredmerge/ruby/gems",
        "RUBOCOP_LTS_LOCAL" => "/workspace/rubocop-lts"
      }
    ).results

    expect(results.fetch(1).phase).to eq("prepare_template_dependencies")
    expect(results.fetch(1).command.last(4)).to eq(["kettle-jem", "prepare", "--quiet", "--events"])
    expect(results.fetch(2).command).to eq(
      [
        "mise",
        "exec",
        "-C",
        member.root,
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
        "#{family_local_env_name}=#{@tmpdir}",
        "BUNDLE_DISABLE_CHECKSUM_VALIDATION=true",
        "KETTLE_JEM_TEMPLATE_PROFILE=full",
        "KJ_REPOSITORY_TOPOLOGY=standalone",
        "KETTLE_JEM_THREAD_WORKERS=#{[1, Etc.nprocessors - 1].max}",
        "KETTLE_JEM_GIT_LOCK=#{File.join(@tmpdir, ".git", "kettle-family-template-commit.lock")}",
        "KETTLE_JEM_GIT_COMMIT_LOCK=#{File.join(@tmpdir, ".git", "kettle-family-template-commit.lock")}",
        "K_JEM_TEMPLATING=true",
        "STRUCTUREDMERGE_DEV=/workspace/structuredmerge/ruby/gems",
        "RUBOCOP_LTS_LOCAL=/workspace/rubocop-lts",
        "KETTLE_JEM_QUIET=true",
        "KETTLE_JEM_DEBUG=false",
        "KETTLE_DEV_DEBUG=false",
        "STRUCTUREDMERGE_DEBUG=false",
        "BUNDLE_QUIET=true",
        "BUNDLE_DEBUG=false",
        "BUNDLER_DEBUG=false",
        "BUNDLE_VERBOSE=false",
        "BUNDLE_SILENCE_DEPRECATIONS=true",
        "BUNDLE_SILENCE_ROOT_WARNING=true",
        "BUNDLE_SUPPRESS_INSTALL_USING_MESSAGES=true",
        "bundle",
        "exec",
        "kettle-jem",
        "install",
        "--quiet",
        "--events"
      ]
    )

    [results.fetch(0), results.fetch(3)].each do |result|
      expect(result.command).to include(
        "K_JEM_TEMPLATING=true",
        "#{family_local_env_name}=#{@tmpdir}",
        "STRUCTUREDMERGE_DEV=/workspace/structuredmerge/ruby/gems",
        "RUBOCOP_LTS_LOCAL=/workspace/rubocop-lts",
        "BUNDLE_QUIET=true"
      )
      expect(result.command.last(3)).to eq([RbConfig.ruby, "-e", "puts 'normalized'"])
    end
  end

  it "overrides noisy template debug environment unless debug is enabled" do
    write_template_config(command: ["bundle", "exec", "kettle-jem", "install"])
    config = Kettle::Family::Config.load(root: @tmpdir)
    member = member_at("alpha")
    File.write(File.join(member.root, "mise.toml"), "[env]\nDEBUG = \"true\"\n")

    quiet_results = described_class.new(
      command: "template",
      config: config,
      members: [member],
      env_overrides: {
        "DEBUG" => "true",
        "BUNDLE_DEBUG" => "true",
        "BUNDLER_DEBUG" => "true",
        "DEBUG_RESOLVER" => "true",
        "STRUCTUREDMERGE_DEBUG" => "true"
      }
    ).results
    debug_results = described_class.new(
      command: "template",
      config: config,
      members: [member],
      env_overrides: {
        "DEBUG" => "true",
        "BUNDLE_DEBUG" => "true",
        "BUNDLER_DEBUG" => "true",
        "DEBUG_RESOLVER" => "true",
        "STRUCTUREDMERGE_DEBUG" => "true"
      },
      debug: true
    ).results

    quiet_command = quiet_results.find { |result| result.phase == "template" }.command
    quiet_env = quiet_command.grep(/DEBUG|RESOLVER/)
    debug_env = debug_results.find { |result| result.phase == "template" }.command.grep(/DEBUG|RESOLVER/)
    expect(quiet_command).to include(
      "-u",
      "DEBUG",
      "-u",
      "DEBUG_RESOLVER",
      "BUNDLE_DEBUG=false",
      "BUNDLER_DEBUG=false",
      "STRUCTUREDMERGE_DEBUG=false"
    )
    expect(quiet_env).not_to include(
      "DEBUG=true",
      "DEBUG=false",
      "BUNDLE_DEBUG=true",
      "BUNDLER_DEBUG=true",
      "DEBUG_RESOLVER=true",
      "DEBUG_RESOLVER=false",
      "STRUCTUREDMERGE_DEBUG=true"
    )
    expect(debug_env).to include(
      "DEBUG=true",
      "BUNDLE_DEBUG=true",
      "BUNDLER_DEBUG=true",
      "DEBUG_RESOLVER=true",
      "STRUCTUREDMERGE_DEBUG=true"
    )
  end

  it "sets KETTLE_JEM_VERBOSE and does not force quiet environment in verbose mode" do
    write_template_config(command: ["bundle", "exec", "kettle-jem", "install"])
    config = Kettle::Family::Config.load(root: @tmpdir)
    member = member_at("alpha")
    File.write(File.join(member.root, "mise.toml"), "[env]\n")

    results = described_class.new(command: "template", config: config, members: [member], verbose: true).results

    command_env = results.find { |result| result.phase == "template" }.command.grep(/KETTLE_JEM|BUNDLE_QUIET/)
    expect(command_env).to include("KETTLE_JEM_VERBOSE=true")
    expect(command_env).not_to include("KETTLE_JEM_QUIET=true")
    expect(command_env).not_to include("BUNDLE_QUIET=true")
  end

  it "runs executed templating members in parallel and emits member progress" do
    write_template_config(command: [
      RbConfig.ruby,
      "-e",
      "puts '{\"changed_files\":[\"Gemfile\"]}'"
    ])
    config = Kettle::Family::Config.load(root: @tmpdir)
    members = [member_at("alpha"), member_at("beta")]
    progress = StringIO.new

    results = described_class.new(
      command: "template",
      config: config,
      members: members,
      execute: true,
      jobs: 2,
      progress_io: progress
    ).results

    expect(results.count { |result| result.phase == "template" }).to eq(2)
    expect(progress.string).to include("templating 2 members with 2 jobs:")
    expect(progress.string).to match(/\[alpha\]\s+\(0\/3\)\s+\d{2}:\d{2}\s+>\s+prepare_lockfiles/)
    expect(progress.string).to match(/\[beta\]\s+\(0\/3\)\s+\d{2}:\d{2}\s+>\s+prepare_lockfiles/)
    expect(progress.string).to match(/\[alpha\]\s+\(2\/3\)\s+\d{2}:\d{2}\s+\.\s+template/)
    expect(progress.string).to match(/\[beta\]\s+\(2\/3\)\s+\d{2}:\d{2}\s+\.\s+template/)
    expect(progress.string).to include("template summary: 2/2 members ok, 2 files changed")
  end

  it "keeps kettle-jem NDJSON template events summarized by default" do
    event_script = [
      "require 'json';",
      "puts JSON.generate(event_version: 1, type: 'phase_start', phase: 'recipes', status: 'started');",
      "puts JSON.generate(event_version: 1, type: 'phase_finish', phase: 'recipes', status: 'ok');",
      "puts JSON.generate(event_version: 1, type: 'recipe', path: 'Gemfile', changed: true, mark: '*');",
      "puts JSON.generate(event_version: 1, type: 'post_apply_step', phase: 'post_apply', name: 'git_hooks_executable', status: 'updated', mark: '*');",
      "puts JSON.generate(event_version: 1, type: 'command_step', phase: 'install', name: 'bundle_install', status: 'started', mark: '>');",
      "puts JSON.generate(event_version: 1, type: 'diagnostic', message: 'example warning');",
      "puts JSON.generate(event_version: 1, type: 'summary', changed_count: 1, checksum_hit_count: 2, checksum_protected_count: 4, unchanged_count: 3);"
    ].join(" ")
    write_template_config(command: [RbConfig.ruby, "-e", event_script])
    config = Kettle::Family::Config.load(root: @tmpdir)
    members = [member_at("alpha"), member_at("beta")]
    progress = StringIO.new

    results = described_class.new(
      command: "template",
      config: config,
      members: members,
      execute: true,
      jobs: 2,
      progress_io: progress
    ).results

    expect(results.find { |result| result.phase == "template" }.stdout).to include("\"type\":\"recipe\"")
    expect(progress.string).to include("templating 2 members with 2 jobs:")
    expect(progress.string).to match(/\[alpha\]\s+\(2\/3\)\s+\d{2}:\d{2}\s+\.\s+template/)
    expect(progress.string).not_to include("[alpha] > recipes")
    expect(progress.string).not_to include("[alpha] * Gemfile")
    expect(progress.string).not_to include("[alpha] ! example warning")
    expect(progress.string).to match(/\[alpha\]\s+\(3\/3\)\s+\d{2}:\d{2}\s+done\s+2 checksum hits, 4 checksum-protected changes, 3 unchanged, 1 file changed/)
    expect(progress.string).to include("template summary: 2/2 members ok, 4 checksum hits, 8 checksum-protected changes, 6 unchanged, 2 files changed")
  end

  it "deduplicates changed files from repeated kettle-jem NDJSON summaries" do
    event_script = [
      "require 'json';",
      "puts JSON.generate(event_version: 1, type: 'summary', changed_files: ['Gemfile', 'Rakefile'], changed_count: 2);",
      "puts JSON.generate(event_version: 1, type: 'summary', changed_files: ['Gemfile', 'Rakefile', '.yard-lint.yml'], changed_count: 3);",
      "puts JSON.generate(event_version: 1, type: 'summary', changed_files: ['Rakefile', '.yard-lint.yml'], changed_count: 2);"
    ].join(" ")
    write_template_config(command: [RbConfig.ruby, "-e", event_script])
    config = Kettle::Family::Config.load(root: @tmpdir)
    member = member_at("alpha")
    progress = StringIO.new

    described_class.new(
      command: "template",
      config: config,
      members: [member],
      execute: true,
      jobs: 1,
      progress_io: progress
    ).results

    expect(progress.string).to match(/\[alpha\]\s+\(3\/3\)\s+\d{2}:\d{2}\s+done\s+3 files changed/)
    expect(progress.string).to include("template summary: 1/1 members ok, 3 files changed")
    expect(progress.string).not_to include("7 files changed")
  end

  it "uses the last kettle-jem NDJSON changed count when changed files are unavailable" do
    event_script = [
      "require 'json';",
      "puts JSON.generate(event_version: 1, type: 'summary', changed_count: 2);",
      "puts JSON.generate(event_version: 1, type: 'summary', changed_count: 3);"
    ].join(" ")
    write_template_config(command: [RbConfig.ruby, "-e", event_script])
    config = Kettle::Family::Config.load(root: @tmpdir)
    member = member_at("alpha")
    progress = StringIO.new

    described_class.new(
      command: "template",
      config: config,
      members: [member],
      execute: true,
      jobs: 1,
      progress_io: progress
    ).results

    expect(progress.string).to match(/\[alpha\]\s+\(3\/3\)\s+\d{2}:\d{2}\s+done\s+3 files changed/)
    expect(progress.string).to include("template summary: 1/1 members ok, 3 files changed")
    expect(progress.string).not_to include("5 files changed")
  end

  it "streams kettle-jem NDJSON template events as member progress lines when verbose" do
    event_script = [
      "require 'json';",
      "puts JSON.generate(event_version: 1, type: 'phase_start', phase: 'recipes', status: 'started');",
      "puts JSON.generate(event_version: 1, type: 'phase_finish', phase: 'recipes', status: 'ok');",
      "puts JSON.generate(event_version: 1, type: 'recipe', path: 'Gemfile', changed: true, mark: '*');",
      "puts JSON.generate(event_version: 1, type: 'post_apply_step', phase: 'post_apply', name: 'git_hooks_executable', status: 'updated', mark: '*');",
      "puts JSON.generate(event_version: 1, type: 'command_step', phase: 'install', name: 'bundle_install', status: 'started', mark: '>');",
      "puts JSON.generate(event_version: 1, type: 'diagnostic', message: 'example warning');",
      "puts JSON.generate(event_version: 1, type: 'summary', changed_count: 1);"
    ].join(" ")
    write_template_config(command: [RbConfig.ruby, "-e", event_script])
    config = Kettle::Family::Config.load(root: @tmpdir)
    members = [member_at("alpha"), member_at("beta")]
    progress = StringIO.new

    described_class.new(
      command: "template",
      config: config,
      members: members,
      execute: true,
      jobs: 2,
      progress_io: progress,
      verbose: true
    ).results

    expect(progress.string).to include("[alpha] > recipes")
    expect(progress.string).to include("[alpha] . recipes")
    expect(progress.string).to include("[alpha] * Gemfile")
    expect(progress.string).to include("[alpha] * post_apply:git_hooks_executable")
    expect(progress.string).to include("[alpha] > install:bundle_install")
    expect(progress.string).to include("[alpha] ! example warning")
    expect(progress.string).to include("[alpha] done 1 file changed")
    expect(progress.string).to include("template summary: 2/2 members ok, 2 files changed")
  end

  it "summarizes structured template diagnostics for TTY progress rows" do
    write_template_config
    config = Kettle::Family::Config.load(root: @tmpdir)
    member = member_at("alpha")
    updates = []
    progress = Class.new do
      define_method(:initialize) { |target| @target = target }
      define_method(:tty?) { true }
      define_method(:update) do |_member, status:, mark:|
        @target << [status, mark]
      end
    end.new(updates)
    workflow = described_class.new(command: "template", config: config, members: [member], progress_io: StringIO.new)

    handler = workflow.send(:template_event_line_handler, member, progress: progress)
    handler.call(JSON.generate(
      event_version: 1,
      type: "diagnostic",
      message: {
        kind: "plugin_lifecycle",
        configured_plugins: ["kettle-drift"],
        registered_hooks: [{plugin_name: "kettle-drift", phase: "remaining_files"}]
      }
    ))

    expect(updates).to include(["plugin_lifecycle", "!"])
  end

  it "keeps kettle-jem NDJSON template events summarized for single-job templating" do
    event_script = [
      "require 'json';",
      "puts JSON.generate(event_version: 1, type: 'recipe', path: 'Gemfile', changed: true, mark: '*');",
      "puts JSON.generate(event_version: 1, type: 'summary', changed_count: 1);"
    ].join(" ")
    write_template_config(command: [RbConfig.ruby, "-e", event_script])
    config = Kettle::Family::Config.load(root: @tmpdir)
    member = member_at("alpha")
    progress = StringIO.new

    results = described_class.new(
      command: "template",
      config: config,
      members: [member],
      execute: true,
      jobs: 1,
      progress_io: progress
    ).results

    expect(results.find { |result| result.phase == "template" }.stdout).to include("\"type\":\"recipe\"")
    expect(progress.string).to include("templating 1 member with 1 job:")
    expect(progress.string).to match(/\[alpha\]\s+\(2\/3\)\s+\d{2}:\d{2}\s+\.\s+template/)
    expect(progress.string).not_to include("[alpha] * Gemfile")
    expect(progress.string).to match(/\[alpha\]\s+\(3\/3\)\s+\d{2}:\d{2}\s+done\s+1 file changed/)
    expect(progress.string).to include("template summary: 1/1 members ok, 1 file changed")
  end

  it "plans templating across configured release target branches" do
    write_template_config(
      release_target_branches: %w[r1_8-even-v0 r1_9-even-v2]
    )
    config = Kettle::Family::Config.load(root: @tmpdir)
    member = member_at("alpha")

    results = described_class.new(command: "template", config: config, members: [member]).results

    expect(results.map(&:phase)).to eq(
      %w[
        release_checkout
        prepare_lockfiles
        template
        normalize_lockfiles
        commit_normalized_lockfiles
        release_checkout
        prepare_lockfiles
        template
        normalize_lockfiles
        commit_normalized_lockfiles
      ]
    )
    expect(results.fetch(0).command).to eq(["git", "checkout", "r1_8-even-v0"])
    expect(results.fetch(5).command).to eq(["git", "checkout", "r1_9-even-v2"])
  end

  it "plans member workflow commands across configured release target branches" do
    write_template_config(
      release_target_branches: %w[r1_8-even-v0 r1_9-even-v2]
    )
    config = Kettle::Family::Config.load(root: @tmpdir)
    member = member_at("alpha")
    workflow = described_class.new(command: "test", config: config, members: [member])
    allow(workflow).to receive(:rediscovered_selected_members).and_return([member])

    results = workflow.results

    expect(results.map(&:phase)).to eq(%w[
      release_checkout test
      release_checkout test
    ])
    expect(results.select { |result| result.phase == "release_checkout" }.map(&:command)).to eq([
      ["git", "checkout", "r1_8-even-v0"],
      ["git", "checkout", "r1_9-even-v2"]
    ])
  end

  it "fails before templating when member target branch checkout would be blocked by local changes" do
    write_template_config
    config = Kettle::Family::Config.load(root: @tmpdir)
    member = member_at("alpha")
    write_template_config(root: member.root, release_target_branches: %w[r1 r2])
    initialize_git_repo(member.root, branches: %w[r1 r2])
    File.write(File.join(member.root, "scratch.txt"), "dirty\n")

    results = described_class.new(command: "template", config: config, members: [member], execute: true, autostash: false).results

    expect(results.map(&:phase)).to eq(["release_checkout_preflight"])
    expect(results.first).not_to be_ok
    expect(results.first.member_name).to eq("alpha")
    expect(results.first.stderr).to include("local changes would block release target branch checkout")
    expect(results.first.stderr).to include("scratch.txt")
  end

  it "resets a sole local-path Gemfile.lock before branch target checkout" do
    write_template_config
    config = Kettle::Family::Config.load(root: @tmpdir)
    member = member_at("alpha")
    write_template_config(root: member.root, release_target_branches: %w[r1 r2])
    File.write(File.join(member.root, "Gemfile.lock"), <<~LOCK)
      PATH
        remote: /workspace/alpha
        specs:
    LOCK

    calls = []
    stub_successful_runner(calls)
    allow(Kettle::Family::GitStatus).to receive(:dirty_paths).with(member.root).and_return([" M Gemfile.lock"], [])

    workflow = described_class.new(command: "template", config: config, members: [member], execute: true)
    allow(workflow).to receive(:validate_reset_gemfile_lock)

    results = workflow.results

    expect(results.map(&:phase)).to include("template_lockfile_recovery", "release_checkout")
    expect(calls.find { |call| call[:phase] == "template_lockfile_recovery" }.fetch(:env)).to include(
      "BUNDLE_GEMFILE" => nil,
      "K_JEM_TEMPLATING" => "false"
    )
  end

  it "commits a sole released-dependency Gemfile.lock before branch target checkout" do
    write_template_config
    config = Kettle::Family::Config.load(root: @tmpdir)
    member = member_at("alpha")
    write_template_config(root: member.root, release_target_branches: %w[r1 r2])
    File.write(File.join(member.root, "Gemfile.lock"), <<~LOCK)
      GEM
        remote: https://gem.coop/
        specs:
    LOCK

    calls = []
    stub_successful_runner(calls)
    allow(Kettle::Family::GitStatus).to receive(:dirty_paths).with(member.root).and_return([" M Gemfile.lock"], [])

    results = described_class.new(command: "template", config: config, members: [member], execute: true).results

    expect(results.map(&:phase)).to include("commit_normalized_lockfiles", "release_checkout")
    commit_command = calls.find { |call| call[:phase] == "commit_normalized_lockfiles" }.fetch(:command).join(" ")
    expect(commit_command).to include("Normalize\\ lockfiles\\ after\\ templating")
    expect(calls.map { |call| call[:phase] }).not_to include("template_lockfile_recovery")
  end

  it "resets and retries template preparation when its bundled executable cannot boot" do
    write_template_config(command: "bundle exec kettle-jem install")
    config = Kettle::Family::Config.load(root: @tmpdir)
    member = member_at("alpha")
    calls = []
    runner = instance_double(Kettle::Family::CommandRunner)
    allow(Kettle::Family::CommandRunner).to receive(:new).and_return(runner)
    allow(runner).to receive(:call) do |member:, phase:, command:, env: {}, **_args|
      calls << {phase: phase, command: command, env: env}
      failure = phase == "prepare_template_dependencies" && calls.count { |call| call[:phase] == phase } == 1
      Kettle::Family::CommandResult.new(
        member.name,
        phase,
        command,
        member.root,
        failure ? 1 : 0,
        !failure,
        "",
        failure ? "Bundler::GemNotFound: Could not find kettle-soup-cover-3.0.0.rc6" : "",
        0.0,
        false,
        nil
      )
    end

    workflow = described_class.new(command: "template", config: config, members: [member], execute: true)
    allow(workflow).to receive(:validate_reset_gemfile_lock)

    results = workflow.results

    expect(results).to all(be_ok)
    expect(calls.map { |call| call[:phase] }).to include(
      "prepare_template_dependencies",
      "prepare_template_dependencies_recovery",
      "commit_normalized_lockfiles"
    )
    expect(calls.count { |call| call[:phase] == "prepare_template_dependencies" }).to eq(2)
  end

  it "retries template lockfile normalization once after a Bundler materialization failure" do
    write_template_config
    config = Kettle::Family::Config.load(root: @tmpdir)
    member = member_at("alpha")
    calls = []
    runner = instance_double(Kettle::Family::CommandRunner)
    allow(Kettle::Family::CommandRunner).to receive(:new).and_return(runner)
    allow(runner).to receive(:call) do |member:, phase:, command:, env: {}, **_args|
      calls << {phase: phase, command: command, env: env}
      failure = phase == "prepare_lockfiles" && calls.count { |call| call[:phase] == "prepare_lockfiles" } == 1
      Kettle::Family::CommandResult.new(
        member.name,
        phase,
        command,
        member.root,
        failure ? 1 : 0,
        !failure,
        "",
        failure ? "Bundler::GemNotFound: Could not find stale-gem-1.0.0" : "",
        0.0,
        false,
        nil
      )
    end

    workflow = described_class.new(command: "template", config: config, members: [member], execute: true)
    allow(workflow).to receive(:validate_reset_gemfile_lock)

    results = workflow.results

    expect(results).to all(be_ok)
    expect(calls.map { |call| call[:phase] }).to start_with(
      "prepare_lockfiles",
      "prepare_lockfiles_recovery",
      "commit_normalized_lockfiles",
      "prepare_lockfiles"
    )
    expect(calls.count { |call| call[:phase] == "prepare_lockfiles" }).to eq(2)
    expect(calls.find { |call| call[:phase] == "prepare_lockfiles_recovery" }.fetch(:env)).to include(
      "BUNDLE_GEMFILE" => nil,
      "K_JEM_TEMPLATING" => "false"
    )
  end

  it "updates Bundler and retries checksum-aware template normalization when required" do
    write_template_config(command: [RbConfig.ruby, "-e", "puts 'templated'"])
    config_hash = YAML.load_file(File.join(@tmpdir, ".kettle-family.yml"))
    config_hash.fetch("template")["normalize_lockfiles_command"] = %w[bundle lock --update --add-checksums]
    File.write(File.join(@tmpdir, ".kettle-family.yml"), YAML.dump(config_hash))
    config = Kettle::Family::Config.load(root: @tmpdir)
    member = member_at("alpha")
    calls = []
    runner = instance_double(Kettle::Family::CommandRunner)
    allow(Kettle::Family::CommandRunner).to receive(:new).and_return(runner)
    allow(runner).to receive(:call) do |member:, phase:, command:, env: {}, **_args|
      calls << {phase: phase, command: command, env: env}
      unsupported = phase == "prepare_lockfiles" && calls.count { |call| call[:phase] == "prepare_lockfiles" } == 1
      Kettle::Family::CommandResult.new(
        member.name,
        phase,
        command,
        member.root,
        unsupported ? 1 : 0,
        !unsupported,
        "",
        unsupported ? "Unknown switches \"--add-checksums\"" : "",
        0.0,
        false,
        nil
      )
    end

    results = described_class.new(command: "template", config: config, members: [member], execute: true).results

    expect(results).to all(be_ok)
    expect(calls.map { |call| call[:phase] }).to start_with(
      "prepare_lockfiles",
      "prepare_lockfiles_bundler_recovery",
      "prepare_lockfiles"
    )
    expect(calls.fetch(1).fetch(:command)).to eq(%w[bundle update --bundler])
    expect(calls.fetch(2).fetch(:command)).to eq(%w[bundle lock --update])
    expect(calls.count { |call| call[:phase] == "prepare_lockfiles" }).to eq(2)
  end

  it "preserves shell operators when retrying a checksum-aware compound command" do
    write_template_config(command: [RbConfig.ruby, "-e", "puts 'templated'"])
    config_hash = YAML.load_file(File.join(@tmpdir, ".kettle-family.yml"))
    config_hash.fetch("template")["normalize_lockfiles_command"] = "bundle update nomono --bundler && bundle lock --add-checksums"
    File.write(File.join(@tmpdir, ".kettle-family.yml"), YAML.dump(config_hash))
    config = Kettle::Family::Config.load(root: @tmpdir)
    member = member_at("alpha")
    File.write(File.join(member.root, "Gemfile.lock"), <<~LOCK)
      GEM
        specs:
          kettle-dev (2.5.14)
          nomono (1.1.2)

      BUNDLED WITH
       2.0.0
    LOCK
    stub_latest_nomono("1.1.2")
    calls = []
    runner = instance_double(Kettle::Family::CommandRunner)
    allow(Kettle::Family::CommandRunner).to receive(:new).and_return(runner)
    allow(runner).to receive(:call) do |member:, phase:, command:, env: {}, **_args|
      calls << {phase: phase, command: command, env: env}
      unsupported = phase == "prepare_lockfiles" && calls.count { |call| call[:phase] == "prepare_lockfiles" } == 1
      Kettle::Family::CommandResult.new(
        member.name, phase, command, member.root, unsupported ? 1 : 0, !unsupported,
        "", unsupported ? "Unknown switches \"--add-checksums\"" : "", 0.0, false, nil
      )
    end

    results = described_class.new(command: "template", config: config, members: [member], execute: true).results

    expect(results).to all(be_ok)
    expect(calls.fetch(0).fetch(:command)).to eq("bundle update nomono kettle-dev --bundler && bundle lock --add-checksums")
    expect(calls.fetch(2).fetch(:command)).to eq("bundle update nomono kettle-dev --bundler && bundle lock")
  end

  it "allows dirty member target branch checkout preflight when explicitly requested" do
    write_template_config
    config = Kettle::Family::Config.load(root: @tmpdir)
    member = member_at("alpha")
    write_template_config(root: member.root, release_target_branches: %w[r1 r2])
    initialize_git_repo(member.root, branches: %w[r1 r2])
    File.write(File.join(member.root, "scratch.txt"), "dirty\n")

    results = described_class.new(
      command: "template",
      config: config,
      members: [member],
      execute: true,
      allow_dirty: true
    ).results

    expect(results.map(&:phase)).to include("release_checkout")
    expect(results.map(&:phase)).not_to include("release_checkout_preflight")
    expect(results).to all(be_ok)
  end

  it "blocks template sync on a dirty worktree when autostash is disabled" do
    write_template_config
    config = Kettle::Family::Config.load(root: @tmpdir)
    member = member_at("alpha")
    initialize_git_repo(member.root, branches: [])
    File.write(File.join(member.root, "scratch.txt"), "dirty\n")

    results = described_class.new(command: "template", config: config, members: [member], execute: true, autostash: false).results

    expect(results).to contain_exactly(have_attributes(phase: "template_sync_preflight", success: false))
    expect(results.first.stderr).to include("remove --no-autostash")
  end

  it "keeps an autostash out of template work and restores it afterward" do
    write_template_config(command: [RbConfig.ruby, "-e", "File.write('templated.txt', 'ok')"], normalize_lockfiles: false)
    config = Kettle::Family::Config.load(root: @tmpdir)
    member = member_at("alpha")
    initialize_git_repo(member.root, branches: [])
    File.write(File.join(member.root, "scratch.txt"), "dirty\n")

    workflow = described_class.new(command: "template", config: config, members: [member], execute: true)
    runner = Kettle::Family::CommandRunner.new(execute: true, accept: true)
    results, stashes = workflow.send(:template_worktree_sync_results, runner: runner)

    expect(results).to all(be_ok)
    expect(stashes).to contain_exactly(include(member: member))
    expect(File).not_to exist(File.join(member.root, "scratch.txt"))

    restores = workflow.send(:restore_template_autostashes, stashes, runner: runner)

    expect(restores).to all(be_ok)
    expect(File.read(File.join(member.root, "scratch.txt"))).to eq("dirty\n")
  end

  it "restores a stashed lockfile when uncommitted template lockfile dirt blocks stash pop" do
    write_template_config(normalize_lockfiles: false)
    config = Kettle::Family::Config.load(root: @tmpdir)
    member = member_at("alpha")
    initialize_git_repo(member.root, branches: [])
    File.write(File.join(member.root, "Gemfile.lock"), "local\n")

    workflow = described_class.new(command: "template", config: config, members: [member], execute: true)
    runner = Kettle::Family::CommandRunner.new(execute: true, accept: true)
    _results, stashes = workflow.send(:template_worktree_sync_results, runner: runner)
    File.write(File.join(member.root, "Gemfile.lock"), "template\n")

    restores = workflow.send(:restore_template_autostashes, stashes, runner: runner)

    expect(restores).to all(be_ok), restores.map { |result| [result.stdout, result.stderr].join("\n") }.join("\n")
    expect(File.read(File.join(member.root, "Gemfile.lock"))).to eq("local\n")
    expect(`git -C #{member.root} stash list`).to be_empty
  end

  it "rolls back failed template output before restoring an autostash" do
    write_template_config(command: [RbConfig.ruby, "-e", "File.write('templated.txt', 'partial'); exit 1"], normalize_lockfiles: false)
    config = Kettle::Family::Config.load(root: @tmpdir)
    member = member_at("alpha")
    initialize_git_repo(member.root, branches: [])
    File.write(File.join(member.root, "scratch.txt"), "dirty\n")

    results = described_class.new(command: "template", config: config, members: [member], execute: true).results

    expect(results.map(&:phase)).to include("template_autostash_rollback")
    expect(results.find { |result| result.phase == "template_autostash_rollback" }).to be_ok
    expect(File.read(File.join(member.root, "scratch.txt"))).to eq("dirty\n")
    expect(File).not_to exist(File.join(member.root, "templated.txt"))
    expect(`git -C #{member.root} stash list`).to be_empty
  end

  it "keeps a generated Gemfile lockfile when restoring a dirty lockfile would conflict" do
    write_template_config(normalize_lockfiles: false)
    config = Kettle::Family::Config.load(root: @tmpdir)
    member = member_at("alpha")
    initialize_git_repo(member.root, branches: [])
    File.write(File.join(member.root, "Gemfile.lock"), "local\n")

    workflow = described_class.new(command: "template", config: config, members: [member], execute: true)
    runner = Kettle::Family::CommandRunner.new(execute: true, accept: true)
    _results, stashes = workflow.send(:template_worktree_sync_results, runner: runner)
    File.write(File.join(member.root, "Gemfile.lock"), "template\n")
    run_git(member.root, "add", "Gemfile.lock")
    run_git(member.root, "commit", "--quiet", "-m", "Template lockfile")

    restores = workflow.send(:restore_template_autostashes, stashes, runner: runner)

    expect(restores).to all(be_ok)
    expect(File.read(File.join(member.root, "Gemfile.lock"))).to eq("template\n")
    expect(`git -C #{member.root} diff --name-only --diff-filter=U`).to be_empty
  end

  it "keeps the generated kettle-jem lockfile when restoring its prior state would conflict" do
    write_template_config(normalize_lockfiles: false)
    config = Kettle::Family::Config.load(root: @tmpdir)
    member = member_at("alpha")
    initialize_git_repo(member.root, branches: [])
    lockfile = File.join(member.root, ".structuredmerge", "kettle-jem.lock")
    FileUtils.mkdir_p(File.dirname(lockfile))
    File.write(lockfile, "base\n")
    run_git(member.root, "add", ".structuredmerge/kettle-jem.lock")
    run_git(member.root, "commit", "--quiet", "-m", "Track kettle-jem state")
    File.write(lockfile, "local\n")

    workflow = described_class.new(command: "template", config: config, members: [member], execute: true)
    runner = Kettle::Family::CommandRunner.new(execute: true, accept: true)
    _results, stashes = workflow.send(:template_worktree_sync_results, runner: runner)
    FileUtils.mkdir_p(File.dirname(lockfile))
    File.write(lockfile, "template\n")
    run_git(member.root, "add", ".structuredmerge/kettle-jem.lock")
    run_git(member.root, "commit", "--quiet", "-m", "Template kettle-jem state")

    restores = workflow.send(:restore_template_autostashes, stashes, runner: runner)

    expect(restores).to all(be_ok), restores.map { |result| [result.stdout, result.stderr].join("\n") }.join("\n")
    expect(File.read(lockfile)).to eq("template\n")
    expect(`git -C #{member.root} diff --name-only --diff-filter=U`).to be_empty
  end

  it "pulls an upstream branch before a clean template run" do
    write_template_config
    config = Kettle::Family::Config.load(root: @tmpdir)
    member = member_at("alpha")
    initialize_git_repo(member.root, branches: [])
    remote = File.join(@tmpdir, "alpha-origin.git")
    run_git(@tmpdir, "init", "--bare", "--quiet", remote)
    run_git(member.root, "remote", "add", "origin", remote)
    run_git(member.root, "push", "--quiet", "--set-upstream", "origin", "HEAD")

    workflow = described_class.new(command: "template", config: config, members: [member], execute: true)
    runner = Kettle::Family::CommandRunner.new(execute: true, accept: true)
    results, = workflow.send(:template_worktree_sync_results, runner: runner)

    expect(results).to contain_exactly(have_attributes(phase: "template_sync", success: true))
  end

  it "bootstraps legacy members without bundle exec when templating wiring is absent" do
    config = Kettle::Family::Config.load(root: @tmpdir)
    member = member_at("alpha")

    results = described_class.new(command: "template", config: config, members: [member]).results

    expect(results.fetch(0).command).to eq(["sh", "-lc", "kettle-jem prepare --quiet --events"])
    expect(results.fetch(1).command).to eq(["sh", "-lc", "kettle-jem install --quiet --events"])
  end

  def write_template_config(root: @tmpdir, command: [RbConfig.ruby, "-e", "puts 'templated'"], release_target_branches: nil, normalize_lockfiles: true, family_mode: nil)
    config = {
      "template" => {
        "command" => command,
        "profile" => "full",
        "repository_topology" => "standalone",
        "normalize_lockfiles" => normalize_lockfiles,
        "normalize_lockfiles_command" => [RbConfig.ruby, "-e", "puts 'normalized'"]
      }
    }
    config["family"] = {"mode" => family_mode} if family_mode
    config["release"] = {"target_branches" => release_target_branches} if release_target_branches
    File.write(
      File.join(root, ".kettle-family.yml"),
      YAML.dump(config)
    )
  end

  def family_local_env_name
    "#{File.basename(@tmpdir).gsub(/[^A-Za-z0-9]+/, "_").upcase}_DEV"
  end

  def member_at(name)
    root = File.join(@tmpdir, name)
    FileUtils.mkdir_p(root)
    Kettle::Family::Member.new(name: name, root: root, gemspec_path: File.join(root, "#{name}.gemspec"), version: "1.0.0", dependencies: [])
  end

  def write_nomono_bundle(member, floor:, locked:)
    File.write(File.join(member.root, "Gemfile"), <<~RUBY)
      source "https://gem.coop"

      gem "nomono", "~> 1.1", ">= #{floor}", require: false
    RUBY
    File.write(File.join(member.root, "Gemfile.lock"), <<~LOCK)
      GEM
        remote: https://gem.coop/
        specs:
          nomono (#{locked})

      DEPENDENCIES
        nomono (~> 1.1, >= #{floor})
    LOCK
  end

  def stub_latest_nomono(version)
    allow(Kettle::Dev::RubyGemsVersions).to receive(:fetch).with("nomono").and_return([{"number" => version}])
  end

  def stub_successful_runner(captured_calls)
    command_runner = instance_double(Kettle::Family::CommandRunner)
    allow(Kettle::Family::CommandRunner).to receive(:new).and_return(command_runner)
    allow(command_runner).to receive(:call) do |member:, phase:, command:, env: {}, **_args|
      captured_calls << {member: member.name, phase: phase, command: command, env: env}
      Kettle::Family::CommandResult.new(
        member.name,
        phase,
        command,
        member.root,
        0,
        true,
        (phase == "template") ? "{\"event_version\":1,\"type\":\"summary\",\"changed_count\":0}\n" : "",
        "",
        0.0,
        false,
        nil
      )
    end
  end

  def initialize_git_repo(root, branches:)
    run_git(root, "init", "--quiet")
    run_git(root, "config", "user.email", "kettle-family@example.test")
    run_git(root, "config", "user.name", "Kettle Family")
    File.write(File.join(root, "Gemfile.lock"), "clean\n")
    run_git(root, "add", ".")
    run_git(root, "commit", "--quiet", "-m", "Initial")
    branches.each { |branch| run_git(root, "branch", branch) }
  end

  def run_git(root, *args)
    system("git", *args, chdir: root, exception: true)
  end
end
