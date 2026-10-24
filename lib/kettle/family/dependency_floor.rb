# frozen_string_literal: true

require "kettle/deps/floor"

module Kettle
  module Family
    # Adapts family release versions and workflow results to the shared
    # kettle-deps-floor updater. Parsing, floor eligibility, and AST edits live
    # in the generic gem; this class supplies family context only.
    class DependencyFloor
      def self.gemspec_dependency_names(member)
        return [] unless member.gemspec_path && File.file?(member.gemspec_path)

        Kettle::Deps::Floor::Updater.dependency_names(
          project_root: member.root,
          sources: [File.basename(member.gemspec_path)]
        )
      rescue Kettle::Deps::Floor::Error => error
        raise Error, error.message
      end

      def initialize(released_members:, dependent_members:, mode: :dry_run)
        @released_members = released_members
        @dependent_members = dependent_members
        @mode = mode
        @released_versions = released_members.to_h { |member| [member.name, member.version.to_s] }
      end

      def results
        dependent_members.filter_map { |member| result_for(member) }
      end

      private

      attr_reader :released_members, :dependent_members, :mode, :released_versions

      def result_for(member)
        return unless member.gemspec_path && File.file?(member.gemspec_path)

        updater = Kettle::Deps::Floor::Updater.new(
          project_root: member.root,
          sources: [File.basename(member.gemspec_path)],
          target_versions: released_versions,
          registry_updates: false,
          write: mode == :execute
        )
        changes = updater.run.fetch(:planned_changes)
        return if changes.empty?

        CommandResult.new(
          member_name: member.name,
          phase: "dependency_floor",
          command: ["internal", "dependency-floor", released_versions.keys.join(",")],
          workdir: member.root,
          status: 0,
          success: true,
          stdout: edit_summary(member: member, changes: changes),
          stderr: "",
          elapsed_seconds: 0.0,
          skipped: mode != :execute,
          reason: (mode == :execute) ? nil : "dry-run; pass --execute to write"
        )
      rescue Kettle::Deps::Floor::Error => error
        raise Error, error.message
      end

      def edit_summary(member:, changes:)
        verb = (mode == :execute) ? "updated" : "would update"
        paths = changes.map { |change| change.fetch(:relative_path) }.uniq
        ["#{verb} #{changes.length} family dependency floor(s) for #{member.name}", *paths.map { |path| "#{verb} #{path}" }].join("\n")
      end
    end
  end
end
