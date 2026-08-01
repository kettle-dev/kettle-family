# frozen_string_literal: true

require "kettle/dev"

module Kettle
  module Family
    # Removes the obsolete byebug debugger stack before Bundler evaluates a
    # legacy member. This must happen before kettle-jem can template Gemfile.
    class DebuggerBootstrap
      DEBUG_GEM = "debug"
      OBSOLETE_NAME_FRAGMENT = "byebug"
      DECLARATION_METHODS = %i[gem add_dependency add_development_dependency].freeze

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
          "template_bootstrap_debugger",
          ["internal", "debugger-bootstrap", DEBUG_GEM],
          member.root,
          0,
          true,
          "replaced obsolete byebug debugger dependencies with #{DEBUG_GEM} in #{edits.map { |edit| File.basename(edit.fetch(:path)) }.uniq.join(", ")}\n",
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
        [File.join(member.root, "Gemfile"), member.gemspec_path].filter_map { |path| file_edits(path) }.flatten
      end

      def file_edits(path)
        return [] unless File.file?(path)

        source = File.read(path)
        declarations = debugger_declarations(source, path)
        return [] if declarations.empty?

        declarations.filter_map.with_index do |declaration, index|
          debugger_edit(path, source, declaration, replace: index.zero?)
        end
      end

      def debugger_declarations(source, path)
        parse_result = Kettle::Dev::VersionBump.parse_source(source, path)
        Kettle::Dev::VersionBump.each_node(parse_result.value).filter_map do |node|
          next unless node.is_a?(Prism::CallNode)
          next unless DECLARATION_METHODS.include?(node.name)

          name_node = node.arguments&.arguments&.first
          next unless name_node.is_a?(Prism::StringNode)
          next unless name_node.unescaped.include?(OBSOLETE_NAME_FRAGMENT)

          {node: node, name_node: name_node}
        end
      end

      def debugger_edit(path, source, declaration, replace:)
        node = declaration.fetch(:node)
        if replace
          replacement = debugger_replacement(node, declaration.fetch(:name_node))
          return Kettle::Dev::VersionBump.file_edit(
            path, source, node.location.start_offset, node.location.end_offset, replacement
          )
        end

        line_start = source.rindex("\n", node.location.start_offset - 1).to_i + 1
        line_end = source.index("\n", node.location.end_offset) || source.length
        line_end += 1 if line_end < source.length
        Kettle::Dev::VersionBump.file_edit(path, source, line_start, line_end, "")
      end

      def debugger_replacement(node, name_node)
        receiver = node.receiver ? "#{node.receiver.location.slice}." : ""
        quote = Kettle::Dev::VersionBump.quote_like(name_node.location.slice, DEBUG_GEM)
        suffix = (node.name == :gem) ? ", require: false" : ""
        "#{receiver}#{node.name} #{quote}#{suffix}"
      end
    end
  end
end
