# frozen_string_literal: true

module Kettle
  module Family
    class ChangelogCheck
      def self.call(member:)
        new(member: member).call
      end

      def initialize(member:)
        @member = member
      end

      def call
        diagnostics = []
        changelog = File.join(member.root, "CHANGELOG.md")
        diagnostics << "missing CHANGELOG.md" unless File.file?(changelog)
        diagnostics << "CHANGELOG.md missing Unreleased section" if File.file?(changelog) && !File.read(changelog).include?("## [Unreleased]")
        result(diagnostics)
      end

      private

      attr_reader :member

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
