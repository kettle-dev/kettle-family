# frozen_string_literal: true

require "kettle/dev"

module Kettle
  module Family
    # Removes the retired pre-fork appraisal source before Bundler evaluates a
    # legacy member. kettle-jem owns the current appraisal wiring.
    class AppraisalBootstrap
      LEGACY_GEM_NAME = "appraisal"
      LEGACY_GITHUB = "pboling/appraisal"
      LEGACY_BRANCH = "galtzo"

      def initialize(mode: :dry_run)
        @mode = mode
      end

      attr_reader :mode

      def member_needs_bootstrap?(member)
        edits_for(member).any?
      end

      def bootstrap_member(member)
        edits = edits_for(member)
        write_edits(edits)
        CommandResult.new(
          member.name,
          "template_bootstrap_appraisal",
          ["internal", "appraisal-bootstrap", LEGACY_GITHUB],
          member.root,
          0,
          true,
          "removed retired #{LEGACY_GITHUB} appraisal dependency from #{edits.map { |edit| File.basename(edit.fetch(:path)) }.uniq.join(", ")}\n",
          "",
          0.0,
          mode != :execute,
          (mode == :execute) ? nil : "dry run"
        )
      end

      private

      def write_edits(edits)
        return if mode != :execute || edits.empty?

        Kettle::Dev::VersionBump.write_edits(edits)
      end

      def edits_for(member)
        [File.join(member.root, "Gemfile"), File.join(member.root, "Appraisal.root.gemfile")].filter_map do |path|
          file_edits(path)
        end.flatten
      end

      def file_edits(path)
        return [] unless File.file?(path)

        source = File.read(path)
        parse_result = Kettle::Dev::VersionBump.parse_source(source, path)
        Kettle::Dev::VersionBump.each_node(parse_result.value).filter_map do |node|
          obsolete_appraisal_edit(path, source, node)
        end
      end

      def obsolete_appraisal_edit(path, source, node)
        return unless legacy_appraisal_call?(node)

        line_start = source.rindex("\n", node.location.start_offset - 1).to_i + 1
        line_end = source.index("\n", node.location.end_offset) || source.length
        line_end += 1 if line_end < source.length
        Kettle::Dev::VersionBump.file_edit(path, source, line_start, line_end, "")
      end

      def legacy_appraisal_call?(node)
        return false unless node.is_a?(Prism::CallNode) && node.name == :gem

        arguments = node.arguments&.arguments || []
        name_node = arguments.first
        return false unless name_node.is_a?(Prism::StringNode) && name_node.unescaped == LEGACY_GEM_NAME

        keyword_values(arguments).values_at("github", "branch") == [LEGACY_GITHUB, LEGACY_BRANCH]
      end

      def keyword_values(arguments)
        arguments.grep(Prism::KeywordHashNode).flat_map(&:elements).each_with_object({}) do |association, values|
          next unless association.is_a?(Prism::AssocNode)
          next unless association.key.is_a?(Prism::SymbolNode) && association.value.is_a?(Prism::StringNode)

          values[association.key.unescaped] = association.value.unescaped
        end
      end
    end
  end
end
