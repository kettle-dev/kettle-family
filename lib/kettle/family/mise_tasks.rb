# frozen_string_literal: true

require "ast/crispr"
require "ast/crispr/toml"
require "psych/merge"

module Kettle
  module Family
    # Slice-1044 family mise tasks primitive: ensure a destination root
    # `mise.toml` references the kettle-family-managed TOML task file via
    # `[task_config] includes`, and report (optionally clean) task
    # redefinitions between the root file and the managed file.
    #
    # Precedence contract (mise): a task defined in the root `mise.toml` wins
    # over the same name from a task file. Redefinition is therefore allowed
    # and only reported; `clean` is always opt-in.
    #
    # All edits go through ast-crispr Actors with the ast-crispr-toml adapter.
    module MiseTasks
      TomlSelectors = Ast::Crispr::Toml::Selectors

      # Managed task file name, relative to the family root (the directory
      # containing .kettle-family.yml and the root mise.toml that includes it).
      DEFAULT_TASK_FILE_NAME = "mise-family.tasks.toml"

      # changed:         the root content was modified
      # include_present: the include reference is (now) present and correct
      # content:         the resulting root mise.toml content
      # redefinitions:   task names defined in BOTH the root and the managed file
      Result = Struct.new(:changed, :include_present, :content, :redefinitions)

      # Task names declared in a mise.toml / TOML task file.
      #
      # The two shapes differ:
      # - a root `mise.toml` (`managed: false`, default) namespaces tasks
      #   under `[tasks]` / `[tasks.<name>]`;
      # - a TOML task file loaded through `[task_config].includes`
      #   (`managed: true`) uses the mise-task schema: each top-level table
      #   IS a task (bare name), e.g. `[family-canary]`.
      #
      # @param content [String] TOML source
      # @param managed [Boolean] parse as a managed TOML task file
      # @return [Array<String>]
      def self.task_names(content, managed: false)
        context = Ast::Crispr::Toml.document_context(content: content, source_label: "mise.toml")
        if managed
          tables = context.structural_owners(owner_scope: :tables)
          names = tables.reject { |table| table.name == "task_config" }.map(&:name)
          context.structural_owners(owner_scope: :root_pairs).each do |pair|
            names << pair.name.to_s unless pair.full_path == "includes" || pair.full_path.include?(".")
          end
          return names.compact.reject(&:empty?).uniq
        end

        names = []
        context.structural_owners(owner_scope: :tables).each do |table|
          next unless table.name == "tasks" || table.name.start_with?("tasks.")

          # `[tasks.<name>]` sub-tables ARE task definitions; their inner
          # pairs are task configuration, not task names. Only the bare
          # `[tasks]` table carries trivial task entries as pairs.
          if table.name == "tasks"
            table.wrapper.pairs.each { |pair| names << pair.key_name.to_s }
          else
            names << table.name.sub(/\Atasks\./, "")
          end
        end
        context.structural_owners(owner_scope: :root_pairs).each do |pair|
          names << pair.name.to_s if pair.full_path == "tasks"
        end
        names.compact.reject(&:empty?).uniq
      end

      # Register the managed task file as kettle-jem template-managed in the
      # destination's kettle-jem config. The registration is a template-side
      # fragment merged into the destination YAML with psych-merge:
      # destination entries always win, so an existing strategy choice is
      # never overridden — only a missing registration is added.
      #
      # Skips silently (changed: false) when the destination has no
      # kettle-jem config: a project that is not kettle-jem-templated has
      # nothing to register.
      #
      # @param config_content [String] destination kettle-jem config YAML
      # @param task_file_name [String] managed task file name
      # @return [Result]-shaped Struct (changed, include_present, content, redefinitions: [])
      def self.register_in_jem_config(config_content:, task_file_name:)
        fragment = <<~YAML
          files:
            #{task_file_name}:
              strategy: keep_destination
        YAML

        merge_result = Psych::Merge.merge_yaml(
          fragment,
          config_content,
          "yaml",
          add_template_only_nodes: true,
          preference: :destination
        )
        raise Error, Array(merge_result[:diagnostics]).map { |d| d[:message] || d["message"] }.join("; ") unless merge_result[:ok]

        updated = merge_result[:output]
        Result.new(changed: updated != config_content, include_present: true, content: updated, redefinitions: [])
      end

      # Ensure kettle-family is listed under `plugins:` in the destination's
      # kettle-jem config, so templating runs load it and materialize the
      # managed task suite. Appends to an existing `plugins:` list without
      # disturbing entries already there (sequence items present only in the
      # fragment are added; destination items always win); a no-op when the
      # plugin is already listed.
      #
      # @param config_content [String] destination kettle-jem config YAML
      # @return [Result]-shaped Struct (changed, include_present, content, redefinitions: [])
      def self.register_plugin_in_jem_config(config_content:)
        fragment = <<~YAML
          plugins:
            - kettle-family
        YAML

        merge_result = Psych::Merge.merge_yaml(
          fragment,
          config_content,
          "yaml",
          add_template_only_nodes: true,
          add_template_only_sequence_items: true,
          preference: :destination
        )
        raise Error, Array(merge_result[:diagnostics]).map { |d| d[:message] || d["message"] }.join("; ") unless merge_result[:ok]

        updated = merge_result[:output]
        Result.new(changed: updated != config_content, include_present: true, content: updated, redefinitions: [])
      end

      # Task names defined in BOTH the root mise.toml and the managed task file.
      #
      # @param root_content [String] destination mise.toml content
      # @param task_file_content [String, nil] managed task file content
      # @return [Array<String>] sorted redefined task names (empty when task_file_content is nil)
      def self.redefinitions(root_content:, task_file_content:)
        return [] if task_file_content.nil?

        (task_names(root_content) & task_names(task_file_content, managed: true)).sort
      end

      # Ensure the root mise.toml contains `[task_config] includes = ["<task_file_name>"]`.
      #
      # @param root_content [String] the destination's mise.toml content
      # @param task_file_name [String] managed task file name, relative to the config root
      # @param task_file_content [String, nil] managed task file content, for redefinition detection
      # @return [Result]
      def self.ensure_include(root_content:, task_file_name:, task_file_content: nil)
        redefs = redefinitions(root_content: root_content, task_file_content: task_file_content)
        context = Ast::Crispr::Toml.document_context(content: root_content, source_label: "mise.toml")

        if include_present?(context, task_file_name)
          return Result.new(changed: false, include_present: true, content: root_content, redefinitions: redefs)
        end

        updated = add_include(context, task_file_name)
        Result.new(
          changed: updated != root_content,
          include_present: true,
          content: updated,
          redefinitions: redefinitions(root_content: updated, task_file_content: task_file_content)
        )
      end

      # Remove duplicate task definitions from the root mise.toml.
      # Opt-in (`--clean`); never runs implicitly.
      #
      # @param root_content [String] the destination's mise.toml content
      # @param task_file_content [String] managed task file content
      # @param task_file_name [String] managed task file name
      # @return [Result]
      def self.clean_redefinitions(root_content:, task_file_content:, task_file_name:)
        redefs = redefinitions(root_content: root_content, task_file_content: task_file_content)
        content = root_content
        redefs.each do |name|
          # A task can be defined as a `[tasks.<name>]` table block or as a
          # trivial `name = "…"` pair inside `[tasks]`; try both owners.
          [
            TomlSelectors.table(path: "tasks.#{name}"),
            TomlSelectors.pair(path: "tasks.#{name}")
          ].each do |target|
            result = Ast::Crispr::Delete.result(
              content: content,
              target: target,
              source_label: "mise.toml"
            )
            content = result.updated_content if result.success? && result.changed
          end
        end

        context = Ast::Crispr::Toml.document_context(content: content, source_label: "mise.toml")
        Result.new(
          changed: content != root_content,
          include_present: include_present?(context, task_file_name),
          content: content,
          redefinitions: redefinitions(root_content: content, task_file_content: task_file_content)
        )
      end

      # Kinds to try when deleting a task definition: a `[tasks.<name>]`
      # table block or a `name = "…"` pair inside `[tasks]`.
      TASK_OWNER_KINDS = %i[table pair].freeze

      class << self
        # Build a successful Result. `include_present` is always true on an
        # ensure_include outcome: a no-op means the reference was already correct.
        def ok_result(content, redefs, changed: false)
          Result.new(changed: changed, include_present: true, content: content, redefinitions: redefs)
        end

        private

        def document_context(content)
          Ast::Crispr::Toml.document_context(content: content, source_label: "mise.toml")
        end

        def include_present?(context, task_file_name)
          includes_entries(context).any? { |entry| entry == task_file_name.to_s }
        end

        # String entries of `task_config.includes`; empty when the table or
        # the pair does not exist.
        def includes_entries(context)
          table = context.structural_owners(owner_scope: :tables).find { |owner| owner.name == "task_config" }
          return [] unless table

          pair = table.wrapper.pairs.find { |candidate| candidate.key_name.to_s.strip == "includes" }
          return [] unless pair

          value = pair.value_node
          if value&.array?
            value.elements.map { |element| unquote(element.text) }
          else
            [unquote(value&.text)]
          end.compact
        end

        def unquote(text)
          text.to_s.strip.gsub(/\A["']|["']\z/, "")
        end

        def add_include(context, task_file_name)
          content = context.content
          block = "[task_config]\nincludes = [\"#{task_file_name}\"]\n"

          table = context.structural_owners(owner_scope: :tables).find { |owner| owner.name == "task_config" }
          if table.nil?
            result = Ast::Crispr::Insert.result(
              content: content,
              text: block,
              destination: nil,
              if_missing: :append,
              source_label: "mise.toml"
            )
            return fail_or(result)
          end

          pairs = table.wrapper.pairs
          result =
            if pairs.empty?
              Ast::Crispr::Replace.result(
                content: content,
                target: TomlSelectors.table(path: "task_config"),
                replacement: block.rstrip + "\n",
                source_label: "mise.toml"
              )
            else
              last = pairs.last
              Ast::Crispr::Replace.result(
                content: content,
                target: TomlSelectors.pair(path: "task_config.#{last.key_name}"),
                replacement: "#{last.text}\nincludes = [\"#{task_file_name}\"]\n",
                source_label: "mise.toml"
              )
            end
          fail_or(result)
        end

        def fail_or(result)
          raise Error, result.error.to_s unless result.success?

          result.updated_content
        end
      end

      # kettle-jem plugin hook (kettle-jem-appraisals pattern). During
      # templating of a family root, materialize the comprehensive managed
      # task suite from the family config facts and ensure the root mise.toml
      # includes it. Skips non-family roots (member dirs have no
      # .kettle-family.yml).
      #
      # @param context [Hash] kettle-jem plugin context (:project_root)
      def self.materialize_managed_suite(context:)
        root = context[:project_root].to_s
        return if root.empty?

        root = File.expand_path(root)
        return unless File.file?(File.join(root, ".kettle-family.yml"))

        config = Config.load(root: root)
        content = ManagedSuite.new(config).content
        content += "\n" unless content.end_with?("\n")

        task_file_path = File.join(root, DEFAULT_TASK_FILE_NAME)
        File.write(task_file_path, content) unless File.exist?(task_file_path) && File.read(task_file_path) == content

        root_mise = File.join(root, "mise.toml")
        return unless File.file?(root_mise)

        result = ensure_include(
          root_content: File.read(root_mise),
          task_file_name: DEFAULT_TASK_FILE_NAME,
          task_file_content: content
        )
        File.write(root_mise, result.content) if result.changed
      rescue Error, SystemCallError => e
        warn("kettle-family: could not materialize managed mise tasks: #{e.class}: #{e.message}")
      end

      # Comprehensive managed family mise task suite, generated from family
      # config facts. Tasks are thin delegations to kettle-family commands,
      # which resolve changelog targets, local-path env, and members_root
      # from the family config at run time. The bup/bupb env wiring is the
      # one piece of shape baked at generation time, derived from the same
      # config the workflow uses (family.local_path_env,
      # release.disable_local_path_env, family.mode, family.members_root).
      class ManagedSuite
        TASK_DESCRIPTIONS = {
          "test" => "Run each member gem suite with its own bundle",
          "lint" => "Run read-only lint checks across family members",
          "state" => "Report release state for every family member",
          "release-state" => "Report changelog release state for every family member",
          "template" => "Apply kettle-jem templates across family members",
          "bump" => "Bump member gem versions",
          "changelog" => "Add a structured entry to the family changelog",
          "bup" => "Update dependencies and commit lockfiles; pass gems or options after --",
          "bupb" => "Install latest stable Bundler and update family lockfiles; pass options after --",
          "update-bundler" => "Install latest stable Bundler and update family lockfiles; pass options after --"
        }.freeze

        attr_reader :config

        def initialize(config)
          @config = config
        end

        def content
          tasks = {
            "test" => "bundle exec kettle-family test --execute",
            "lint" => "bundle exec kettle-family lint",
            "state" => "bundle exec kettle-family release-state",
            "release-state" => "bundle exec kettle-family release-state",
            "template" => "bundle exec kettle-family template",
            "bump" => "bundle exec kettle-family bump --execute",
            # Targeting is resolved by kettle-family from the family config:
            # shared-changelog families write the root changelog, member-local
            # families write each member's own.
            "changelog" => "bundle exec kettle-family add-changelog --execute"
          }
          tasks["bup"] = "bundle exec kettle-family bup --execute --commit"
          tasks["bupb"] = "bundle exec kettle-family update-bundler --execute --commit"
          tasks["update-bundler"] = tasks["bupb"]

          neutral = neutralize_assignments
          wiring = env_wiring_flags
          %w[bup bupb].each do |name|
            prefix = neutral.empty? ? "" : "env #{neutral} -- "
            tasks[name] = "#{prefix}#{tasks[name]}#{wiring}"
          end
          tasks["update-bundler"] = tasks["bupb"]

          render(tasks)
        end

        private

        # Neutralize ambient local-path wiring so the command starts from the
        # family config, then hand kettle-family the intended overrides.
        def neutralize_assignments
          pairs = {}
          if (name = config.family_local_path_env_name)
            pairs[name] = "false"
          end
          config.release_disable_local_path_env.each { |name| pairs[name] = "false" }
          pairs.map { |name, value| "#{name}=#{value}" }.join(" ")
        end

        def env_wiring_flags
          flags = +""
          return flags unless config.family_mode == "monorepo"
          return flags unless (relative = members_root_relative)

          if (name = config.family_local_path_env_name)
            flags << " --env #{name}={{config_root}}/#{relative}"
          end
          flags << " --env K_JEM_TEMPLATING=true"
          flags
        end

        def members_root_relative
          require "pathname"
          Pathname.new(config.members_root.to_s)
                  .relative_path_from(Pathname.new(config.root.to_s)).to_s
        rescue ArgumentError
          nil
        end

        def render(tasks)
          out = +<<~HEADER
            # kettle-family managed family mise tasks
            #
            # This file is owned by kettle-family and is overwritten on
            # template updates (and on kettle-jem templating runs for this
            # family). It uses the mise-task schema: each top-level table is a
            # task, addressable from the destination root mise.toml via
            # [task_config] includes.
            #
            # Family-specific tasks (for example a release task with the
            # family's publish flags and secrets provider) belong in the root
            # mise.toml, where they shadow the managed definitions.
          HEADER
          tasks.each do |name, run|
            out << "\n[#{name}]\n"
            out << "description = #{TASK_DESCRIPTIONS.fetch(name).inspect}\n"
            out << "raw = true\n"
            out << "run = #{run.inspect}\n"
          end
          out
        end
      end
    end
  end
end
