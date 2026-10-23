# frozen_string_literal: true

RSpec.describe Kettle::Family::MiseTasks do
  let(:root_without) do
    <<~TOML
      [tools]
      ruby = "4.0"

      [env]
      FOO = "bar"

      [tasks.clean]
      run = "echo clean"
    TOML
  end

  # Managed task files use the mise-task schema: bare top-level task tables
  # (confirmed against real mise via the slice-1044 canary).
  let(:task_file) do
    <<~TOML
      [family-lint]
      description = "Family lint"
      run = "bin/rake lint"
    TOML
  end

  describe ".ensure_include" do
    before do
      skip_for(engine: "ruby", versions: "head", reason: "Ruby head is permanently unsupported by tree_sitter_language_pack's released-ABI-only native gem policy")
    end

    it "appends the task_config block when absent" do
      result = described_class.ensure_include(root_content: root_without, task_file_name: "mise-family.tasks.toml")

      expect(result.changed).to be(true)
      expect(result.include_present).to be(true)
      expect(result.content).to include("[task_config]")
      expect(result.content).to include('includes = ["mise-family.tasks.toml"]')
      expect(result.content).to include("[tasks.clean]")
      expect(::Toml::Merge::FileAnalysis.new(result.content)).to be_valid
    end

    it "is idempotent when the include already exists" do
      first = described_class.ensure_include(root_content: root_without, task_file_name: "mise-family.tasks.toml")
      second = described_class.ensure_include(root_content: first.content, task_file_name: "mise-family.tasks.toml")

      expect(second.changed).to be(false)
      expect(second.content).to eq(first.content)
    end

    it "adds the entry to an existing task_config table without escaping the table" do
      root_with = <<~TOML
        [task_config]
        includes = ["other.toml"]

        [tasks.clean]
        run = "echo clean"
      TOML

      result = described_class.ensure_include(root_content: root_with, task_file_name: "mise-family.tasks.toml")

      expect(result.changed).to be(true)
      expect(result.content).to include('includes = ["other.toml", "mise-family.tasks.toml"]')
      expect(result.content).to include('"mise-family.tasks.toml"')
      analysis = ::Toml::Merge::FileAnalysis.new(result.content)
      expect(analysis).to be_valid
      # the entry must land inside [task_config], not inside a later table
      includes_line = result.content.lines.index { |line| line.include?("mise-family.tasks.toml") }
      tasks_line = result.content.lines.index { |line| line.start_with?("[tasks.clean]") }
      expect(includes_line).to be < tasks_line
      task_config = analysis.tables.find { |table| table.table_name == "task_config" }
      expect(task_config.pairs.map(&:key_name)).to include("includes")
    end

    it "reports redefinitions between the root and the managed task file" do
      root_with_duplicate = "#{root_without}\n[tasks.family-lint]\nrun = \"echo local\"\n"

      result = described_class.ensure_include(
        root_content: root_with_duplicate,
        task_file_name: "mise-family.tasks.toml",
        task_file_content: task_file
      )

      expect(result.redefinitions).to eq(["family-lint"])
    end
  end

  describe ".task_names" do
    before do
      skip_for(engine: "ruby", versions: "head", reason: "Ruby head is permanently unsupported by tree_sitter_language_pack's released-ABI-only native gem policy")
    end

    it "parses a managed TOML task file using bare top-level task tables" do
      managed = <<~TOML
        [family-canary]
        description = "Canary"
        run = "echo family-canary"
      TOML

      expect(described_class.task_names(managed, managed: true)).to eq(["family-canary"])
    end

    it "excludes task_config and the includes pair from managed task names" do
      managed = "[task_config]\nincludes = [\"x\"]\n\n[family-canary]\nrun = \"echo\"\n"

      expect(described_class.task_names(managed, managed: true)).to eq(["family-canary"])
    end

    it "parses root mise.toml tasks namespaced under [tasks]" do
      expect(described_class.task_names(root_without)).to eq(["clean"])
    end
  end

  describe ".register_in_jem_config" do
    let(:config) do
      <<~YAML
        defaults:
          preference: "template"
        files:
          Gemfile:
            strategy: accept_template
      YAML
    end

    it "adds a keep_destination registration for the managed task file" do
      result = described_class.register_in_jem_config(config_content: config, task_file_name: "mise-family.tasks.toml")

      expect(result.changed).to be(true)
      require "yaml"
      parsed = YAML.safe_load(result.content)
      expect(parsed.dig("files", "mise-family.tasks.toml", "strategy")).to eq("keep_destination")
      # destination-owned entries are untouched
      expect(parsed.dig("files", "Gemfile", "strategy")).to eq("accept_template")
      expect(parsed.dig("defaults", "preference")).to eq("template")
    end

    it "registers the kettle-family plugin, appending to an existing list" do
      with_plugins = <<~YAML
        files:
          Gemfile:
            strategy: accept_template
        plugins:
          - kettle-drift
      YAML

      result = described_class.register_plugin_in_jem_config(config_content: with_plugins)

      expect(result.changed).to be(true)
      require "yaml"
      parsed = YAML.safe_load(result.content)
      expect(parsed.fetch("plugins")).to include("kettle-family", "kettle-drift")
    end

    it "creates the plugins list when absent" do
      result = described_class.register_plugin_in_jem_config(config_content: config)

      expect(result.changed).to be(true)
      require "yaml"
      parsed = YAML.safe_load(result.content)
      expect(parsed.fetch("plugins")).to eq(["kettle-family"])
      expect(parsed.dig("files", "Gemfile", "strategy")).to eq("accept_template")
    end

    it "is idempotent when the plugin is already listed" do
      first = described_class.register_plugin_in_jem_config(config_content: config)
      second = described_class.register_plugin_in_jem_config(config_content: first.content)

      expect(second.changed).to be(false)
      require "yaml"
      expect(YAML.safe_load(second.content).fetch("plugins")).to eq(["kettle-family"])
    end

    it "is idempotent when the registration already exists" do
      first = described_class.register_in_jem_config(config_content: config, task_file_name: "mise-family.tasks.toml")
      second = described_class.register_in_jem_config(config_content: first.content, task_file_name: "mise-family.tasks.toml")

      expect(second.changed).to be(false)
      expect(second.content).to eq(first.content)
    end

    it "keeps the destination strategy when the file is already registered differently" do
      override = config.gsub("strategy: accept_template", "strategy: merge") if config.include?("accept_template")
      pre_registered = described_class.register_in_jem_config(config_content: override, task_file_name: "mise-family.tasks.toml")
      tweaked = pre_registered.content.sub("keep_destination", "merge")

      second = described_class.register_in_jem_config(config_content: tweaked, task_file_name: "mise-family.tasks.toml")

      expect(second.changed).to be(false)
      expect(second.content).to include("strategy: merge")
    end
  end

  describe ".redefinitions" do
    before do
      skip_for(engine: "ruby", versions: "head", reason: "Ruby head is permanently unsupported by tree_sitter_language_pack's released-ABI-only native gem policy")
    end

    it "finds table and trivial-pair collisions" do
      root = "#{root_without}\n[tasks.family-lint]\nrun = \"echo local\"\n"
      managed = "#{task_file}\n[clean]\nrun = \"echo managed clean\"\n"

      expect(described_class.redefinitions(root_content: root, task_file_content: managed))
        .to eq(%w[clean family-lint])
    end

    it "returns empty when the managed file has no overlaps" do
      expect(described_class.redefinitions(root_content: root_without, task_file_content: task_file)).to be_empty
    end
  end

  describe ".clean_redefinitions" do
    before do
      skip_for(engine: "ruby", versions: "head", reason: "Ruby head is permanently unsupported by tree_sitter_language_pack's released-ABI-only native gem policy")
    end

    it "removes duplicate table definitions from the root" do
      root_with_duplicates = "#{root_without}\n[tasks.family-lint]\nrun = \"echo local\"\n"
      result = described_class.clean_redefinitions(
        root_content: root_with_duplicates,
        task_file_content: task_file,
        task_file_name: "mise-family.tasks.toml"
      )

      expect(result.changed).to be(true)
      expect(result.redefinitions).to be_empty
      expect(result.content).not_to include("echo local")
      expect(result.content).to include("[tasks.clean]")
      expect(::Toml::Merge::FileAnalysis.new(result.content)).to be_valid
    end

    it "removes trivial pair duplicates" do
      root_with_pair = "#{root_without}\n[tasks]\nfamily-lint = \"echo local\"\n"

      result = described_class.clean_redefinitions(
        root_content: root_with_pair,
        task_file_content: task_file,
        task_file_name: "mise-family.tasks.toml"
      )

      expect(result.changed).to be(true)
      expect(result.redefinitions).to be_empty
      expect(result.content).not_to include("echo local")
    end
  end

  describe ".materialize_managed_suite" do
    before do
      skip_for(engine: "ruby", versions: "head", reason: "Ruby head is permanently unsupported by tree_sitter_language_pack's released-ABI-only native gem policy")
    end

    around do |example|
      Dir.mktmpdir("kettle-family-mise-suite") do |dir|
        @tmpdir = dir
        example.run
      end
    end

    it "is a no-op on a non-family root" do
      described_class.materialize_managed_suite(context: {project_root: @tmpdir})

      expect(File.exist?(File.join(@tmpdir, described_class::DEFAULT_TASK_FILE_NAME))).to be(false)
    end

    it "writes the managed suite and includes it from the root mise.toml" do
      File.write(File.join(@tmpdir, ".kettle-family.yml"), <<~YAML)
        family:
          mode: monorepo
          local_path_env: STRUCTUREDMERGE_DEV
        release:
          disable_local_path_env:
            - K_JEM_TEMPLATING
        members:
          root: gems
      YAML
      File.write(File.join(@tmpdir, "mise.toml"), "[tasks.clean]\nrun = \"echo clean\"\n")

      described_class.materialize_managed_suite(context: {project_root: @tmpdir})

      task_file = File.join(@tmpdir, described_class::DEFAULT_TASK_FILE_NAME)
      expect(File).to exist(task_file)
      content = File.read(task_file)
      expect(described_class.task_names(content, managed: true)).to include("bup", "bupb", "changelog", "test")
      root_content = File.read(File.join(@tmpdir, "mise.toml"))
      result = described_class.ensure_include(root_content: root_content, task_file_name: described_class::DEFAULT_TASK_FILE_NAME, task_file_content: content)
      expect(result.include_present).to be(true)
      expect(result.changed).to be(false)
    end

    it "replaces the legacy placeholder, preserves root task redefinitions, and reports them" do
      File.write(File.join(@tmpdir, ".kettle-family.yml"), "family:\n  mode: sibling_repos\n  local_path_env: RUBOCOP_LTS_DEV\n")
      File.write(File.join(@tmpdir, "mise-family.tasks.toml"), "# legacy placeholder\n")
      File.write(File.join(@tmpdir, "mise.toml"), <<~TOML)
        [env]
        FORGE_ORG = "rubocop-lts"
        [tools]
        ruby = "4.0.7"
        [tasks.bupb]
        run = "bundle _$(ruby broken.rb)_ exec kettle-family update-bundler"
        [tasks.bupb.env]
        CUSTOM_LEGACY_ENV = "old"
        [tasks.lint]
        run = "old lint command"
        [tasks.release]
        run = "bundle exec kettle-family release --execute --publish --secrets-provider op"
        [tasks.my-custom-task]
        run = "echo custom"
      TOML

      result = described_class.materialize_managed_suite(context: {project_root: @tmpdir})
      root = File.read(File.join(@tmpdir, "mise.toml"))
      managed = File.read(File.join(@tmpdir, "mise-family.tasks.toml"))
      # Root redefinitions shadow the managed definitions under mise
      # precedence and may be deliberate local overrides: materialization
      # reports them and leaves them in place; removal is `--clean` only.
      expect(result.redefinitions).to eq(%w[bupb lint])
      expect(root).to include('FORGE_ORG = "rubocop-lts"', 'ruby = "4.0.7"', "[tasks.release]", "[tasks.my-custom-task]")
      expect(root).to include("broken.rb", "old lint command", "CUSTOM_LEGACY_ENV")
      expect(managed).to include("kettle-family lint --execute", "kettle-family template --execute")
      expect(managed).not_to include("ruby broken.rb")
      before = [root, managed]
      described_class.materialize_managed_suite(context: {project_root: @tmpdir})
      expect([File.read(File.join(@tmpdir, "mise.toml")), File.read(File.join(@tmpdir, "mise-family.tasks.toml"))]).to eq(before)
    end

    it "is idempotent" do
      File.write(File.join(@tmpdir, ".kettle-family.yml"), "family:\n  mode: sibling_repos\n")
      File.write(File.join(@tmpdir, "mise.toml"), "")

      described_class.materialize_managed_suite(context: {project_root: @tmpdir})
      first = File.read(File.join(@tmpdir, described_class::DEFAULT_TASK_FILE_NAME))
      described_class.materialize_managed_suite(context: {project_root: @tmpdir})
      second = File.read(File.join(@tmpdir, described_class::DEFAULT_TASK_FILE_NAME))

      expect(second).to eq(first)
    end
  end

  describe "Kettle::Family.register_kettle_jem_plugin" do
    it "registers a remaining_files phase hook" do
      registrar = Object.new
      captured = nil
      allow(registrar).to receive(:on_phase) do |phase, **_opts, &block|
        captured = [phase, block]
      end

      Kettle::Family.register_kettle_jem_plugin(registrar)

      expect(captured[0]).to eq("remaining_files")
      expect(captured[1]).to respond_to(:call)
    end
  end

  describe "Kettle::Family::ManagedSuite" do
    before do
      skip_for(engine: "ruby", versions: "head", reason: "Ruby head is permanently unsupported by tree_sitter_language_pack's released-ABI-only native gem policy")
    end

    let(:monorepo_config) do
      instance_double(
        Kettle::Family::Config,
        root: "/fam",
        members_root: "/fam/gems",
        family_mode: "monorepo",
        family_local_path_env_name: "STRUCTUREDMERGE_DEV",
        release_disable_local_path_env: %w[K_JEM_TEMPLATING TSLP_DEV]
      )
    end

    let(:sibling_config) do
      instance_double(
        Kettle::Family::Config,
        root: "/fam",
        members_root: "/fam",
        family_mode: "sibling_repos",
        family_local_path_env_name: "KETTLE_DEV_DEV",
        release_disable_local_path_env: []
      )
    end

    it "wires monorepo bup/bupb from facts: neutralized local-path env plus members_root override" do
      content = described_class::ManagedSuite.new(monorepo_config).content

      expect(content).to include(
        "run = \"env -- STRUCTUREDMERGE_DEV=false K_JEM_TEMPLATING=false TSLP_DEV=false " \
        "bundle exec kettle-family bup --execute --commit " \
        "--env STRUCTUREDMERGE_DEV={{config_root}}/gems --env K_JEM_TEMPLATING=true\""
      )
      expect(content).not_to include("ruby -e")
      expect(content).not_to include("installed_stable")
    end

    it "keeps delegations shape-agnostic: changelog carries no env scoping" do
      content = described_class::ManagedSuite.new(monorepo_config).content

      expect(content).to include("run = \"bundle exec kettle-family add-changelog --execute\"")
      expect(content).not_to include("K_CHANGELOG_PATH")
      expect(content).not_to include("[release]")
    end

    it "emits sibling_repos bup/bupb without members_root env" do
      content = described_class::ManagedSuite.new(sibling_config).content

      expect(content).to include(
        "run = \"env -- KETTLE_DEV_DEV=false bundle exec kettle-family bup --execute --commit\""
      )
      expect(content).not_to include("--env")
      expect(content).not_to include("{{config_root}}")
    end

    it "executes the generated env wrapper and forwards arguments to bundle" do
      Dir.mktmpdir("managed-task-command") do |dir|
        File.write(File.join(dir, "bundle"), "#!/bin/sh\nprintf '%s\\n' \"$KETTLE_DEV_DEV\" \"$@\"\n")
        FileUtils.chmod(0o755, File.join(dir, "bundle"))
        analysis = ::Toml::Merge::FileAnalysis.new(described_class::ManagedSuite.new(sibling_config).content)
        task = analysis.tables.find { |table| table.table_name == "bupb" }
        command = JSON.parse(task.pairs.find { |pair| pair.key_name == "run" }.value_node.text)
        output, status = Open3.capture2({"PATH" => [dir, ENV.fetch("PATH")].join(File::PATH_SEPARATOR)}, "sh", "-c", "#{command} --only alpha")
        expect(status.success?).to be(true)
        expect(output.lines.map(&:strip)).to eq(%w[false exec kettle-family update-bundler --execute --commit --only alpha])
      end
    end

    it "renders TOML that parses as a managed task file" do
      content = described_class::ManagedSuite.new(monorepo_config).content

      expect(described_class.task_names(content, managed: true)).to include(
        "test", "lint", "state", "release-state", "template", "bump", "changelog", "bup", "bupb", "update-bundler"
      )
    end
  end
end
