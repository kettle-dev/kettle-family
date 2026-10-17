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
    end
  end
end
