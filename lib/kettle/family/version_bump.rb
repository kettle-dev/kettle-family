# frozen_string_literal: true

module Kettle
  module Family
    class VersionBump
      BUMP_TYPES = %w[major minor patch pre].freeze
      DEPENDENCY_METHODS = %i[add_dependency add_runtime_dependency].freeze

      def initialize(members:, target_version:, from_version: nil, mode: :dry_run)
        @members = members
        @target_version = target_version.to_s
        @explicit_target_version = validate_version(target_version) unless BUMP_TYPES.include?(@target_version)
        @from_version = validate_version(from_version) if from_version
        @mode = mode
        @member_names = members.map(&:name)
        @member_target_versions = members.each_with_object({}) do |member, memo|
          memo[member.name] = resolve_target_version(member)
        end
      end

      def results
        members.map { |member| result_for(member) }
      end

      private

      attr_reader :members, :target_version, :explicit_target_version, :from_version, :mode, :member_names, :member_target_versions

      def validate_version(version)
        Gem::Version.new(version).to_s
      rescue ArgumentError => error
        raise Error, "invalid version #{version.inspect}: #{error.message}"
      end

      def result_for(member)
        raise Error, "#{member.name} is #{member.version}, not --from #{from_version}" if from_version && member.version != from_version

        member_target_version = target_version_for(member)
        edits = collect_edits(member, member_target_version)
        write_edits(edits) if mode == :execute
        CommandResult.new(
          member_name: member.name,
          phase: "bump-version",
          command: ["internal", "bump-version", member_target_version],
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

      def collect_edits(member, member_target_version)
        edits = []
        edits << version_file_edit(member, member_target_version) if member.version_file
        edits.concat(gemspec_dependency_edits(member))
        edits.compact
      end

      def version_file_edit(member, member_target_version)
        source = File.read(member.version_file)
        node = version_string_node(source, member.version_file)
        current = node.unescaped
        return nil if current == member_target_version

        replacement = quote_like(node.location.slice, member_target_version)
        file_edit(member.version_file, source, node.location.start_offset, node.location.end_offset, replacement)
      end

      def version_string_node(source, path)
        parse_result = parse_source(source, path)

        constant = each_node(parse_result.value).find do |node|
          node.is_a?(Prism::ConstantWriteNode) && node.name == :VERSION && node.value.is_a?(Prism::StringNode)
        end || raise(Error, "could not find string VERSION constant in #{path}")
        constant.value
      end

      def gemspec_dependency_edits(member)
        source = File.read(member.gemspec_path)
        parse_result = parse_source(source, member.gemspec_path)

        each_node(parse_result.value).filter_map do |node|
          dependency_edit_for(member.gemspec_path, source, node)
        end
      end

      def parse_source(source, path)
        require_prism
        parse_result = Prism.parse(source)
        raise Error, "could not parse #{path}" unless parse_result.success?

        parse_result
      end

      def require_prism
        return if defined?(Prism)

        require "prism"
      rescue LoadError => error
        raise Error, "bump-version requires Prism; install the prism gem or run on a Ruby engine that provides it (#{error.message})"
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
        dependency_target_version = member_target_versions.fetch(name_node.unescaped)
        exact_prefix = "= "
        raise Error, "ambiguous family dependency #{name_node.unescaped.inspect} requirement #{current.inspect} in #{path}" unless current.start_with?(exact_prefix)
        return if current == "#{exact_prefix}#{dependency_target_version}"

        replacement = quote_like(requirement_node.location.slice, "#{exact_prefix}#{dependency_target_version}")
        file_edit(path, source, requirement_node.location.start_offset, requirement_node.location.end_offset, replacement)
      end

      def target_version_for(member)
        member_target_versions.fetch(member.name)
      end

      def resolve_target_version(member)
        return explicit_target_version unless BUMP_TYPES.include?(target_version)

        bumped_version(target_version, member.version)
      end

      def bumped_version(type, current_version)
        return bumped_prerelease_version(current_version) if type == "pre"

        version = Gem::Version.new(current_version)
        segments = version.segments
        unless segments.all? { |segment| segment.is_a?(Integer) }
          raise Error, "cannot #{type}-bump non-numeric version #{current_version.inspect}"
        end

        major, minor, patch = (segments + [0, 0, 0])[0, 3]
        case type
        when "major"
          "#{major + 1}.0.0"
        when "minor"
          "#{major}.#{minor + 1}.0"
        when "patch"
          "#{major}.#{minor}.#{patch + 1}"
        end
      end

      def bumped_prerelease_version(current_version)
        version = Gem::Version.new(current_version)
        segments = version.segments
        prerelease_index = segments.index { |segment| !segment.is_a?(Integer) }
        raise Error, "cannot pre-bump version without prerelease segment #{current_version.inspect}" unless prerelease_index

        release_core = segments[0...prerelease_index].join(".")
        prerelease_suffix = prerelease_suffix_for(current_version, release_core)
        "#{release_core}.#{prerelease_suffix.next}"
      end

      def prerelease_suffix_for(current_version, release_core)
        prefix = "#{release_core}."
        return string_tail(current_version, prefix.length) if current_version.start_with?(prefix)

        canonical_version = Gem::Version.new(current_version).to_s
        return string_tail(canonical_version, prefix.length) if canonical_version.start_with?(prefix)

        raise Error, "cannot find prerelease segment in version #{current_version.inspect}"
      end

      def string_tail(value, offset)
        value[offset, value.length - offset]
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
