# frozen_string_literal: true

require "rbconfig"

module Kettle
  module Family
    # Reconciles RubyGems publications with GitHub Release metadata without
    # creating tags or publishing gems. The child executable performs the
    # authoritative prerequisite checks before an optional GitHub API call.
    class ReleaseReconciler
      CHECK_PHASE = "reconcile_github_release_check"
      CREATE_PHASE = "reconcile_github_release"

      def initialize(config:, members:, execute: false, runner: nil)
        @config = config
        @members = members
        @execute = execute
        @runner = runner || CommandRunner.new(execute: true)
      end

      def results
        release_states = release_state_by_member
        members.flat_map do |member|
          reconcile_member(member: member, release_state: release_states[member.name])
        end
      end

      private

      attr_reader :config, :members, :execute, :runner

      def release_state_by_member
        ReleaseStateCheck.new(config: config, members: members).results.each_with_object({}) do |result, memo|
          memo[result.member_name] = result
        end
      end

      def reconcile_member(member:, release_state:)
        return [state_failure(member: member, release_state: release_state)] unless release_state&.ok?

        state = release_state.state || {}
        version = published_version(state)
        return [informational_result(member: member, message: "RubyGems release version is unknown; no reconciliation attempted")] unless version
        return [informational_result(member: member, message: "GitHub release already matches v#{version}")] if github_release_matches?(state, version)

        check = runner.call(member: member, phase: CHECK_PHASE, command: gh_release_command("--check", "--release-version", version, "--events"))
        return [check] unless check.ok?
        return [check] unless execute

        [check, runner.call(member: member, phase: CREATE_PHASE, command: gh_release_command("--release-version", version, "--events"))]
      end

      def published_version(state)
        version = state.fetch("latest_released", nil).to_s.delete_prefix("v")
        return nil if version.empty? || version == "unknown"

        version
      end

      def github_release_matches?(state, version)
        state.fetch("github_latest_release", nil).to_s.delete_prefix("v") == version
      end

      def gh_release_command(*args)
        [RbConfig.ruby, kettle_gh_release_path, *args]
      end

      def kettle_gh_release_path
        specification = Gem.loaded_specs["kettle-dev"] || Gem::Specification.find_by_name("kettle-dev")
        File.join(specification.full_gem_path, "exe", "kettle-gh-release")
      end

      def informational_result(member:, message:)
        CommandResult.new(
          member_name: member.name,
          phase: CHECK_PHASE,
          command: ["internal", CHECK_PHASE],
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

      def state_failure(member:, release_state:)
        CommandResult.new(
          member_name: member.name,
          phase: CHECK_PHASE,
          command: ["internal", CHECK_PHASE],
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
