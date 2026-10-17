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
      expect(result.content).to include('includes = ["other.toml"]')
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
end
