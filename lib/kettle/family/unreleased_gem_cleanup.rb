# frozen_string_literal: true

module Kettle
  module Family
    class UnreleasedGemCleanup
      PHASE = "clean_unreleased"

      def initialize(config:, members:, execute: false, runner: nil)
        @config = config
        @members = members
        @execute = execute
        @runner = runner || CommandRunner.new(execute: execute)
      end

      def results
        release_states = release_state_by_member
        members.flat_map do |member|
          cleanup_results_for(member: member, release_state: release_states[member.name])
        end
      end

      private

      attr_reader :config, :members, :execute, :runner

      def release_state_by_member
        ReleaseStateCheck.new(config: config, members: members).results.each_with_object({}) do |result, memo|
          memo[result.member_name] = result
        end
      end

      def cleanup_results_for(member:, release_state:)
        return [release_state_failure(member: member, release_state: release_state)] unless release_state&.ok?

        latest_released = latest_released_version(release_state.state)
        return [informational_result(member: member, message: "latest released version is unknown; no cleanup attempted")] unless latest_released

        candidates = installed_versions(member.name).select { |version| version > latest_released }
        return [informational_result(member: member, message: "no unreleased installed versions found")] if candidates.empty?

        candidates.map { |version| cleanup_result(member: member, version: version) }
      end

      def latest_released_version(state)
        value = state.fetch("latest_released", nil).to_s
        return nil if value.empty? || value == "unknown"

        Gem::Version.new(value.delete_prefix("v"))
      rescue ArgumentError
        nil
      end

      def installed_versions(name)
        Gem::Specification.find_all_by_name(name).map(&:version).uniq.sort
      end

      def cleanup_result(member:, version:)
        command = ["gem", "uninstall", member.name, "--version", version.to_s, "--executables", "--all"]
        return runner.call(member: member, phase: PHASE, command: command) if execute

        CommandResult.new(
          member_name: member.name,
          phase: PHASE,
          command: command,
          workdir: member.root,
          status: nil,
          success: true,
          stdout: "would uninstall #{member.name} #{version}",
          stderr: "",
          elapsed_seconds: 0.0,
          skipped: true,
          reason: "dry-run; pass --execute to run"
        )
      end

      def informational_result(member:, message:)
        CommandResult.new(
          member_name: member.name,
          phase: PHASE,
          command: ["internal", PHASE],
          workdir: member.root,
          status: 0,
          success: true,
          stdout: message,
          stderr: "",
          elapsed_seconds: 0.0,
          skipped: false,
          reason: nil
        )
      end

      def release_state_failure(member:, release_state:)
        CommandResult.new(
          member_name: member.name,
          phase: PHASE,
          command: ["internal", PHASE],
          workdir: member.root,
          status: release_state&.status || 1,
          success: false,
          stdout: "",
          stderr: release_state&.stderr.to_s,
          elapsed_seconds: 0.0,
          skipped: false,
          reason: "release state unavailable"
        )
      end
    end
  end
end
