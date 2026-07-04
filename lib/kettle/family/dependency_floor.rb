# frozen_string_literal: true

require "kettle/dev"

module Kettle
  module Family
    class DependencyFloor
      DEPENDENCY_METHODS = %i[add_dependency add_runtime_dependency].freeze

      def initialize(released_members:, dependent_members:, mode: :dry_run)
        @released_members = released_members
        @dependent_members = dependent_members
        @mode = mode
        @released_versions = released_members.to_h { |member| [member.name, Gem::Version.new(member.version.to_s)] }
      end

      def results
        dependent_members.filter_map { |member| result_for(member) }
      end

      private

      attr_reader :released_members, :dependent_members, :mode, :released_versions

      def result_for(member)
        edits = collect_edits(member)
        return if edits.empty?

        write_edits(edits) if mode == :execute
        CommandResult.new(
          member_name: member.name,
          phase: "dependency_floor",
          command: ["internal", "dependency-floor", released_versions.keys.join(",")],
          workdir: member.root,
          status: 0,
          success: true,
          stdout: edit_summary(member: member, edits: edits),
          stderr: "",
          elapsed_seconds: 0.0,
          skipped: mode != :execute,
          reason: (mode == :execute) ? nil : "dry-run; pass --execute to write"
        )
      end

      def collect_edits(member)
        return [] unless member.gemspec_path && File.file?(member.gemspec_path)

        source = File.read(member.gemspec_path)
        parse_result = with_dev_errors { Kettle::Dev::VersionBump.parse_source(source, member.gemspec_path) }
        Kettle::Dev::VersionBump.each_node(parse_result.value).filter_map do |node|
          dependency_edit_for(member.gemspec_path, source, node)
        end
      end

      def dependency_edit_for(path, source, node)
        return unless node.is_a?(Prism::CallNode) && DEPENDENCY_METHODS.include?(node.name)

        args = node.arguments&.arguments || []
        name_node = args.first
        return unless name_node.is_a?(Prism::StringNode)

        dependency_name = name_node.unescaped
        released_version = released_versions[dependency_name]
        return unless released_version

        floor_node = requirement_nodes(args.drop(1)).find do |requirement_node|
          requirement_node.unescaped.start_with?(">= ")
        end
        return unless floor_node

        current_floor = floor_node.unescaped.delete_prefix(">= ").strip
        return unless floor_lower_than?(current_floor, released_version)

        replacement = Kettle::Dev::VersionBump.quote_like(floor_node.location.slice, ">= #{released_version}")
        Kettle::Dev::VersionBump.file_edit(path, source, floor_node.location.start_offset, floor_node.location.end_offset, replacement)
      end

      def requirement_nodes(nodes)
        nodes.flat_map do |node|
          case node
          when Prism::StringNode
            [node]
          when Prism::ArrayNode
            requirement_nodes(node.elements)
          else
            []
          end
        end
      end

      def floor_lower_than?(current_floor, released_version)
        Gem::Version.new(current_floor) < released_version
      rescue ArgumentError
        false
      end

      def write_edits(edits)
        Kettle::Dev::VersionBump.write_edits(edits)
      end

      def edit_summary(member:, edits:)
        verb = (mode == :execute) ? "updated" : "would update"
        ["#{verb} #{edits.length} family dependency floor(s) for #{member.name}", *edits.map { |edit| "#{verb} #{edit.fetch(:path)}" }.uniq].join("\n")
      end

      def with_dev_errors
        yield
      rescue Kettle::Dev::Error => error
        raise Error, error.message
      end
    end
  end
end
