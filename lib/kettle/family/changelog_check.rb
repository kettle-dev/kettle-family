# frozen_string_literal: true

module Kettle
  module Family
    class ChangelogCheck
      def self.call(member:, config: nil)
        new(member: member, config: config).call
      end

      def initialize(member:, config: nil)
        @member = member
        @config = config
      end

      def call
        diagnostics = []
        changelog = changelog_path
        diagnostics << "missing #{relative_changelog_path}" unless File.file?(changelog)
        diagnostics << "#{relative_changelog_path} missing Unreleased section" if File.file?(changelog) && !File.read(changelog).include?("## [Unreleased]")
        result(diagnostics)
      end

      private

      attr_reader :member, :config

      def changelog_path
        config ? config.changelog_full_path(member) : File.join(member.root, "CHANGELOG.md")
      end

      def relative_changelog_path
        return "CHANGELOG.md" unless config

        base = config.shared_changelog? ? config.root : member.root
        changelog_path.delete_prefix("#{base}/")
      end

      def result(diagnostics)
        CommandResult.new(
          member_name: member.name,
          phase: "release_changelog",
          command: ["internal", "changelog"],
          workdir: member.root,
          status: diagnostics.empty? ? 0 : 1,
          success: diagnostics.empty?,
          stdout: diagnostics.join("\n"),
          stderr: "",
          elapsed_seconds: 0.0,
          skipped: false,
          reason: diagnostics.empty? ? nil : "changelog check failed"
        )
      end
    end
  end
end
