# frozen_string_literal: true

require "prism"

module Kettle
  module Family
    class VersionBump
      DEPENDENCY_METHODS = %i[add_dependency add_runtime_dependency].freeze

      def initialize(members:, target_version:, from_version: nil, mode: :dry_run)
        @members = members
        @target_version = validate_version(target_version)
        @from_version = validate_version(from_version) if from_version
        @mode = mode
        @member_names = members.map(&:name)
      end

      def results
        members.map { |member| result_for(member) }
      end

      private

      attr_reader :members, :target_version, :from_version, :mode, :member_names

      def validate_version(version)
        Gem::Version.new(version).to_s
      rescue ArgumentError => error
        raise Error, "invalid version #{version.inspect}: #{error.message}"
      end

      def result_for(member)
        raise Error, "#{member.name} is #{member.version}, not --from #{from_version}" if from_version && member.version != from_version

        edits = collect_edits(member)
        write_edits(edits) if mode == :execute
        CommandResult.new(
          member_name: member.name,
          phase: "bump-version",
          command: ["internal", "bump-version", target_version],
          workdir: member.root,
          status: check_failed?(edits) ? 1 : 0,
          success: !check_failed?(edits),
          stdout: edit_summary(edits),
          stderr: "",
          elapsed_seconds: 0.0,
          skipped: mode == :dry_run,
          reason: result_reason(edits)
        )
      end

      def check_failed?(edits)
        mode == :check && edits.any?
      end

      def result_reason(edits)
        return nil if edits.empty?
        return "version changes required" if mode == :check
        return "dry-run; pass --execute to write" if mode == :dry_run

        nil
      end

      def collect_edits(member)
        edits = []
        edits << version_file_edit(member) if member.version_file
        edits.concat(gemspec_dependency_edits(member))
        edits.compact
      end

      def version_file_edit(member)
        source = File.read(member.version_file)
        node = version_string_node(source, member.version_file)
        current = node.unescaped
        return nil if current == target_version

        replacement = quote_like(node.location.slice, target_version)
        file_edit(member.version_file, source, node.location.start_offset, node.location.end_offset, replacement)
      end

      def version_string_node(source, path)
        parse_result = Prism.parse(source)
        raise Error, "could not parse #{path}" unless parse_result.success?

        constant = each_node(parse_result.value).find do |node|
          node.is_a?(Prism::ConstantWriteNode) && node.name == :VERSION && node.value.is_a?(Prism::StringNode)
        end || raise(Error, "could not find string VERSION constant in #{path}")
        constant.value
      end

      def gemspec_dependency_edits(member)
        source = File.read(member.gemspec_path)
        parse_result = Prism.parse(source)
        raise Error, "could not parse #{member.gemspec_path}" unless parse_result.success?

        each_node(parse_result.value).filter_map do |node|
          dependency_edit_for(member.gemspec_path, source, node)
        end
      end

      def each_node(root)
        return enum_for(__method__, root) unless block_given?

        queue = [root]
        until queue.empty?
          node = queue.shift
          yield node
          queue.concat(node.child_nodes.compact) if node.respond_to?(:child_nodes)
        end
      end

      def dependency_edit_for(path, source, node)
        return unless node.is_a?(Prism::CallNode) && DEPENDENCY_METHODS.include?(node.name)

        args = node.arguments&.arguments || []
        name_node, requirement_node = args
        return unless name_node.is_a?(Prism::StringNode) && member_names.include?(name_node.unescaped)
        return unless requirement_node
        raise Error, "ambiguous family dependency #{name_node.unescaped.inspect} in #{path}" unless requirement_node.is_a?(Prism::StringNode)

        current = requirement_node.unescaped
        exact_prefix = "= "
        raise Error, "ambiguous family dependency #{name_node.unescaped.inspect} requirement #{current.inspect} in #{path}" unless current.start_with?(exact_prefix)
        return if current == "#{exact_prefix}#{target_version}"

        replacement = quote_like(requirement_node.location.slice, "#{exact_prefix}#{target_version}")
        file_edit(path, source, requirement_node.location.start_offset, requirement_node.location.end_offset, replacement)
      end

      def file_edit(path, source, start_offset, end_offset, replacement)
        {path: path, source: source, start_offset: start_offset, end_offset: end_offset, replacement: replacement}
      end

      def quote_like(original, value)
        quote = original.start_with?("'") ? "'" : '"'
        "#{quote}#{value}#{quote}"
      end

      def write_edits(edits)
        edits.group_by { |edit| edit.fetch(:path) }.each_value do |file_edits|
          source = file_edits.first.fetch(:source)
          file_edits.sort_by { |edit| -edit.fetch(:start_offset) }.each do |edit|
            source[edit.fetch(:start_offset)...edit.fetch(:end_offset)] = edit.fetch(:replacement)
          end
          File.write(file_edits.first.fetch(:path), source)
        end
      end

      def edit_summary(edits)
        return "no version changes needed" if edits.empty?

        edits.map { |edit| "would update #{edit.fetch(:path)}" }.uniq.join("\n")
      end
    end
  end
end
