# frozen_string_literal: true

module Kettle
  module Family
    # Uninstalls exactly what `install` installs: each selected member's current
    # source version, plus the cached .gem files.
    #
    # This is the deterministic inverse of `install`, and it exists because the
    # other two cleanups cannot see this class of pollution:
    #
    # - +UnreleasedGemCleanup+ (`clean-unreleased`) removes installed versions
    #   newer than the latest release, but it derives candidates per member from
    #   release state and can miss versions it judges released.
    # - +BlockerCleanup+ (`clean-blockers`) removes what members' lockfiles pin,
    #   so an installed-but-unpinned gem is invisible to it. Observed live:
    #   commonmarker-merge 7.1.10 survived a blocker cleanup (no release
    #   lockfile pinned it), then broke gem activation family-wide with its
    #   dangling exact pin on markdown-merge = 7.1.10 once the rest of the
    #   series was removed.
    #
    # Candidates are the members `install` would act on -- the selected members
    # plus any configured install local_dependencies -- restricted to those whose
    # source version is unreleased (a member already at its released version has
    # nothing to remove; uninstalling it would only churn the bundles that
    # resolve it). Release state comes from the same ReleaseStateCheck
    # +UnreleasedGemCleanup+ uses.
    #
    # The uninstall itself is the shared GemUninstallSupport batch: one
    # invocation, a documented --ignore-dependencies retry when an out-of-batch
    # dependent aborts it, cache removal, and post-uninstall re-enumeration.
    #
    # Note for the family running it: when this command is executed from an
    # installed kettle-family, the batch includes kettle-family itself. The
    # uninstall runs in a subprocess, so self-removal mid-run is safe; the
    # executable falls back to the latest released install afterwards.
    class CleanInstalled
      PHASE = "clean_installed"
      RELEASED_MESSAGE = "source version is released; nothing to uninstall"
      NOT_INSTALLED_MESSAGE = "source version is not installed"
      UNKNOWN_VERSION_MESSAGE = "source version is unknown; nothing to uninstall"
      UNKNOWN_RELEASED_MESSAGE = "latest released version is unknown; no cleanup attempted"

      include GemUninstallSupport
      include MemberLoader

      def initialize(config:, members:, execute: false, runner: nil)
        @config = config
        @members = members
        @execute = execute
        @runner = runner || CommandRunner.new(execute: execute)
      end

      # @return [Array<CommandResult>]
      def results
        findings = member_findings
        removable = findings.filter_map { |finding| finding[:candidate] }.uniq
        annotated = findings.map do |finding|
          candidate = finding[:candidate]
          own = (candidate && removable.include?(candidate)) ? [candidate] : []
          finding.merge(own: own)
        end
        informational = annotated.filter_map { |finding| informational_for(finding) }
        return informational if removable.empty?

        informational + batched_cleanup_results(annotated.select { |finding| finding[:own].any? }, removable)
      end

      private

      attr_reader :config, :members, :execute, :runner

      def uninstall_phase
        PHASE
      end

      # The members `install` would act on: selected members plus configured
      # install local_dependencies, deduplicated by name.
      def candidate_members
        local = config.install_local_dependencies.map { |path| member_from_path(path) }
        seen = {}
        (local + members).each_with_object([]) do |member, memo|
          next if seen.key?(member.name)

          seen[member.name] = true
          memo << member
        end
      end

      def release_state_by_member
        ReleaseStateCheck.new(config: config, members: candidate_members).results.each_with_object({}) do |result, memo|
          memo[result.member_name] = result
        end
      end

      # One member's candidate: its source version, when that version is
      # unreleased and installed. [name, Gem::Version] or nil, plus the reason
      # there is nothing to do.
      def member_findings
        states = release_state_by_member
        candidate_members.map do |member|
          state = states[member.name]
          candidate, message = candidate_for(member, state)
          {member: member, candidate: candidate, message: message, state: state}
        end
      end

      def candidate_for(member, state)
        return [nil, nil] unless state&.ok?

        latest = latest_released_version(state.state)
        return [nil, nil] unless latest

        source = parse_gem_version(member.version.to_s)
        return [nil, UNKNOWN_VERSION_MESSAGE] unless source
        return [nil, RELEASED_MESSAGE] unless source > latest
        return [[member.name, source], nil] if installed_versions(member.name).include?(source)

        [nil, NOT_INSTALLED_MESSAGE]
      end

      def latest_released_version(state)
        value = state.fetch("latest_released", nil).to_s
        return nil if value.empty? || value == "unknown"

        Gem::Version.new(value.delete_prefix("v"))
      rescue ArgumentError
        nil
      end

      # Per-member outcomes that are not part of the batch: unreadable release
      # state (a failure naming its member), or nothing to do (informational).
      def informational_for(finding)
        member = finding.fetch(:member)
        state = finding[:state]
        return release_state_failure(member: member, release_state: state) unless state&.ok?

        message = finding[:message]
        return nil if message.nil? && finding[:own].any?
        return informational_result(member: member, message: UNKNOWN_RELEASED_MESSAGE) if message.nil?

        informational_result(member: member, message: message)
      end

      # Runs the batch once, then reports that one outcome against every member
      # whose gem was in it, mirroring UnreleasedGemCleanup: the command and
      # exit state are shared, but each member reports only its own gem so a
      # failure stays attributable.
      def batched_cleanup_results(contributors, removable)
        host = contributors.first.fetch(:member)
        command = batched_uninstall_command(removable)
        outcome = if execute
          verified_uninstall_outcome(candidates: removable, host: host, command: command)
        else
          dry_run_uninstall_outcome(command: command)
        end

        contributors.map do |finding|
          member_result(finding.fetch(:member), outcome, finding.fetch(:own))
        end
      end

      def member_result(member, outcome, own_candidates)
        own = describe_gem_versions(own_candidates)
        reason = if outcome.ok? || own_candidates.empty?
          outcome.reason
        else
          "batched gem uninstall including #{own} failed"
        end
        outcome.dup.tap do |copy|
          copy.member_name = member.name
          copy.workdir = member.root
          copy.stdout = outcome.skipped ? "would uninstall #{own}" : outcome.stdout
          copy.reason = reason
        end
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
