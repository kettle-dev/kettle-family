# frozen_string_literal: true

require "rubygems"
require "kettle/dev"

module Kettle
  module Family
    class NomonoBootstrap
      GEM_NAME = "nomono"

      def initialize(latest_version:, mode: :dry_run)
        @latest_version = Gem::Version.new(latest_version.to_s)
        @mode = mode
      end

      attr_reader :latest_version, :mode

      def member_needs_bootstrap?(member)
        !!(gemfile_floor_outdated?(member) || lockfile_version_outdated?(member))
      end

      def bootstrap_member(member)
        edits = gemfile_edits(member)
        write_edits(edits)
        CommandResult.new(
          member.name,
          "template_bootstrap_dependencies",
          ["internal", "nomono-bootstrap", latest_version.to_s],
          member.root,
          0,
          true,
          bootstrap_stdout(member, edits),
          "",
          0.0,
          mode != :execute,
          (mode == :execute) ? nil : "dry run"
        )
      end

      private

      def bootstrap_stdout(member, edits)
        lines = ["updated nomono bootstrap dependency for #{member.name}"]
        lines.concat(edits.map { |edit| "updated #{edit.fetch(:path)}" })
        locked_version = lockfile_nomono_version(member)
        if locked_version && locked_version < latest_version
          lines << "lockfile nomono #{locked_version} is below #{latest_version}"
        end
        "#{lines.join("\n")}\n"
      end

      def write_edits(edits)
        return if mode != :execute || edits.empty?

        Kettle::Dev::VersionBump.write_edits(edits)
      end

      def gemfile_floor_outdated?(member)
        gemfile_edits(member).any?
      end

      def lockfile_version_outdated?(member)
        locked_version = lockfile_nomono_version(member)
        locked_version && locked_version < latest_version
      end

      def lockfile_nomono_version(member)
        lockfile = File.join(member.root, "Gemfile.lock")
        return nil unless File.file?(lockfile)

        File.readlines(lockfile).each do |line|
          match = line.match(/\A {4}nomono \(([^)]+)\)\s*\z/)
          return Gem::Version.new(match[1]) if match
        end
        nil
      end

      def gemfile_edits(member)
        gemfile = File.join(member.root, "Gemfile")
        edits = if File.file?(gemfile)
          source = File.read(gemfile)
          parse_result = Kettle::Dev::VersionBump.parse_source(source, gemfile)
          Kettle::Dev::VersionBump.each_node(parse_result.value).filter_map do |node|
            nomono_floor_edit(gemfile, source, node)
          end
        else
          []
        end

        edits + local_gemfile_edits(member)
      end

      def local_gemfile_edits(member)
        Dir.glob(File.join(member.root, "gemfiles/modular/**/*_local.gemfile")).sort.flat_map do |path|
          source = File.read(path)
          parse_result = Kettle::Dev::VersionBump.parse_source(source, path)
          Kettle::Dev::VersionBump.each_node(parse_result.value).filter_map do |node|
            local_nomono_floor_edit(path, source, node)
          end
        rescue Prism::ParseError
          []
        end
      end

      def local_nomono_floor_edit(path, source, node)
        return unless node.is_a?(Prism::LocalVariableWriteNode)
        return unless node.name == :nomono_activation_requirements
        return unless node.value.is_a?(Prism::ArrayNode)

        floor_node = node.value.elements.find do |element|
          element.is_a?(Prism::StringNode) && element.unescaped.start_with?(">= ")
        end
        return unless floor_node

        current_floor = Gem::Version.new(floor_node.unescaped.sub(/\A>=\s*/, ""))
        return unless current_floor < latest_version

        replacement = Kettle::Dev::VersionBump.quote_like(floor_node.location.slice, ">= #{latest_version}")
        Kettle::Dev::VersionBump.file_edit(
          path,
          source,
          floor_node.location.start_offset,
          floor_node.location.end_offset,
          replacement
        )
      end

      def nomono_floor_edit(path, source, node)
        return unless node.is_a?(Prism::CallNode)
        return unless node.name == :gem

        arguments = node.arguments&.arguments || []
        gem_name_node = arguments.first
        return unless gem_name_node.is_a?(Prism::StringNode)
        return unless gem_name_node.unescaped == GEM_NAME

        floor_node = arguments.drop(1).find do |argument|
          argument.is_a?(Prism::StringNode) && argument.unescaped.start_with?(">= ")
        end
        return unless floor_node

        current_floor = Gem::Version.new(floor_node.unescaped.sub(/\A>=\s*/, ""))
        return unless current_floor < latest_version

        replacement = Kettle::Dev::VersionBump.quote_like(floor_node.location.slice, ">= #{latest_version}")
        Kettle::Dev::VersionBump.file_edit(
          path,
          source,
          floor_node.location.start_offset,
          floor_node.location.end_offset,
          replacement
        )
      end
    end
  end
end
