# frozen_string_literal: true

require "kettle/dev"

module Kettle
  module Family
    class VersionBump
      DEPENDENCY_METHODS = %i[add_dependency add_runtime_dependency add_development_dependency].freeze

      def initialize(members:, target_version:, from_version: nil, mode: :dry_run, phase: "bump-version", dependency_target_versions: nil)
        @members = members
        @target_version = target_version.to_s
        @explicit_target_version = validate_version(target_version) unless Kettle::Dev::VersionBump::BUMP_TYPES.include?(@target_version)
        @from_version = validate_version(from_version) if from_version
        @mode = mode
        @phase = phase
        @member_names = members.map(&:name)
        @member_target_versions = members.each_with_object({}) do |member, memo|
          memo[member.name] = resolve_target_version(member)
        end
        @dependency_target_versions = dependency_target_versions || member_target_versions
        @dependency_member_names = @dependency_target_versions.keys
      end

      def results
        members.map { |member| result_for(member) }
      end

      def target_versions
        member_target_versions.dup
      end

      private

      attr_reader :members, :target_version, :explicit_target_version, :from_version, :mode, :phase, :member_target_versions, :dependency_target_versions, :dependency_member_names

      def validate_version(version)
        with_dev_errors { Kettle::Dev::VersionBump.validate_version(version) }
      end

      def result_for(member)
        raise Error, "#{member.name} is #{member.version}, not --from #{from_version}" if from_version && member.version != from_version

        member_target_version = target_version_for(member)
        edits = collect_edits(member, member_target_version)
        write_edits(edits) if mode == :execute
        CommandResult.new(
          member_name: member.name,
          phase: phase,
          command: ["internal", phase, member_target_version],
          workdir: member.root,
          status: check_failed?(edits) ? 1 : 0,
          success: !check_failed?(edits),
          stdout: edit_summary(member: member, target_version: member_target_version, edits: edits),
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

      def collect_edits(member, member_target_version)
        version_edits = with_dev_errors do
          Kettle::Dev::VersionBump.new(
            root: member.root,
            current_version: member.version,
            target_version: member_target_version
          ).edits
        end
        version_edits + gemspec_dependency_edits(member)
      end

      def gemspec_dependency_edits(member)
        source = File.read(member.gemspec_path)
        parse_result = with_dev_errors { Kettle::Dev::VersionBump.parse_source(source, member.gemspec_path) }

        Kettle::Dev::VersionBump.each_node(parse_result.value).filter_map do |node|
          dependency_edit_for(member, source, node)
        end
      end

      def dependency_edit_for(member, source, node)
        return unless node.is_a?(Prism::CallNode) && DEPENDENCY_METHODS.include?(node.name)

        args = node.arguments&.arguments || []
        name_node, requirement_node = args
        return unless name_node.is_a?(Prism::StringNode) && dependency_member_names.include?(name_node.unescaped)
        return unless requirement_node
        dependency_target_version = dependency_target_versions[name_node.unescaped]
        return unless dependency_target_version

        if same_version_dependency_requirement?(node, requirement_node)
          return if dependency_target_version == target_version_for(member)

          raise Error, "dynamic family dependency #{name_node.unescaped.inspect} in #{member.gemspec_path} uses #{call_receiver_name(node)}.version, but target version is #{dependency_target_version}"
        end
        raise Error, "unsupported dynamic family dependency #{name_node.unescaped.inspect} in #{member.gemspec_path}" unless requirement_node.is_a?(Prism::StringNode)

        current = requirement_node.unescaped
        exact_prefix = "= "
        return unless current.start_with?(exact_prefix)
        return if current == "#{exact_prefix}#{dependency_target_version}"

        replacement = Kettle::Dev::VersionBump.quote_like(requirement_node.location.slice, "#{exact_prefix}#{dependency_target_version}")
        Kettle::Dev::VersionBump.file_edit(member.gemspec_path, source, requirement_node.location.start_offset, requirement_node.location.end_offset, replacement)
      end

      def same_version_dependency_requirement?(dependency_call_node, requirement_node)
        return false unless requirement_node.is_a?(Prism::InterpolatedStringNode)

        literal_prefix, embedded_version = requirement_node.parts
        return false unless literal_prefix.is_a?(Prism::StringNode) && literal_prefix.unescaped == "= "
        return false unless embedded_version.is_a?(Prism::EmbeddedStatementsNode)

        statements = embedded_version.statements&.body || []
        return false unless statements.length == 1

        version_call = statements.first
        version_call.is_a?(Prism::CallNode) &&
          version_call.name == :version &&
          call_receiver_name(version_call) == call_receiver_name(dependency_call_node)
      end

      def call_receiver_name(node)
        receiver = node.receiver
        return unless receiver
        return receiver.name.to_s if receiver.respond_to?(:name)

        receiver.location.slice
      end

      def target_version_for(member)
        member_target_versions.fetch(member.name)
      end

      def resolve_target_version(member)
        return explicit_target_version unless Kettle::Dev::VersionBump::BUMP_TYPES.include?(target_version)

        with_dev_errors { Kettle::Dev::VersionBump.resolve_target_version(target_version, member.version) }
      end

      def write_edits(edits)
        Kettle::Dev::VersionBump.write_edits(edits)
      end

      def edit_summary(member:, target_version:, edits:)
        lines = ["#{member.version} -> #{target_version}"]
        return [*lines, "no version changes needed"].join("\n") if edits.empty?

        verb = (mode == :execute) ? "updated" : "would update"
        lines.concat(edits.map { |edit| "#{verb} #{edit.fetch(:path)}" }.uniq)
        lines.join("\n")
      end

      def with_dev_errors
        yield
      rescue Kettle::Dev::Error => error
        raise Error, error.message
      end
    end
  end
end
