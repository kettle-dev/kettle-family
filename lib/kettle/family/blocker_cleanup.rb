# frozen_string_literal: true

require "kettle/dev/lockfile_reset"

module Kettle
  module Family
    # Removes locally installed gem versions that block a command, including gems
    # belonging to OTHER families.
    #
    # Why this exists alongside +UnreleasedGemCleanup+ (`clean-unreleased`): that
    # command derives candidates from family members' release state, so it can
    # only ever remove a member of its own family whose installed version exceeds
    # the latest release. The gems that actually block a release are usually
    # cross-family, and each family is blocked by the other's legitimately
    # installed development versions. Measured live:
    #
    #   kettle-dev        28 pins   ast-crispr 7.1.10, ast-merge, tree_haver, ...
    #   kettle-drift      22 pins   (all structuredmerge gems)
    #   kettle-family     28 pins   (all structuredmerge gems)
    #   kettle-changelog   2 pins   nomono 1.1.7, token-resolver 2.0.13
    #   kettle-jem         3 pins   kettle-test 2.0.24, nomono, token-resolver
    #   smorg-rb           3 pins   (all kettle-dev gems)
    #
    # Neither family's `clean-unreleased` can see the other's offenders, which is
    # what forced the kettle-dev 3.1.9 and kettle-family 1.3.7 releases to be
    # finished manually after `gem push`: the tag, checksum and GitHub Release
    # steps all run through a release-mode dependency update, and that cannot
    # resolve while cross-family unreleased pins are present.
    #
    # The blocker set comes from calling PublishedVersionCheck directly on each
    # selected member and reading its structured diagnostics, NOT from running the
    # blocked command and parsing its report. A dry-run release cannot surface
    # them: workflow.rb:2522-2526 replaces the member result with a synthetic
    # "release readiness requires lockfile normalization" entry before
    # append_release_internal_checks runs, so published_version_check never
    # appears and every diagnostics array is empty. The findings are computed
    # inside release_lockfile_readiness_would_fail? (workflow.rb:5785-5794) and
    # then discarded in favour of a boolean. Running with --execute to obtain them
    # would run the release, which is what we are trying to unblock.
    #
    # PublishedVersionCheck is read-only, so this is safe to run without
    # --execute; only the uninstall itself is gated.
    class BlockerCleanup
      PHASE = "clean_blockers"
      BLOCKER_KIND = "unpublished_lockfile_pin"
      NO_BLOCKERS_MESSAGE = "no unpublished lockfile pins found"
      # A member in local-gem mode resolves its family siblings through PATH
      # remotes, so its lockfile has no GEM-section specs to check. Reporting
      # "no blockers" for it would claim a clean bill of health that was never
      # established, so it is reported separately.
      NOT_INSPECTABLE_MESSAGE = "lockfile has no registry-resolved pins; nothing inspectable"
      NOT_REMOVABLE_PREFIX = "blockers pinned but not installed in a gem home (source checkout, not removable): "

      include GemUninstallSupport

      def initialize(members:, execute: false, runner: nil)
        @members = members
        @execute = execute
        @runner = runner || CommandRunner.new(execute: execute)
      end

      # @return [Array<CommandResult>]
      def results
        findings = members.map { |member| member_blockers(member) }
        removable = removable_candidates(findings)
        annotated = annotate_contributors(findings, removable)
        informational = informational_results(annotated)
        return informational if removable.empty?

        informational + batched_cleanup_results(annotated, removable)
      end

      private

      attr_reader :members, :execute, :runner

      def uninstall_phase
        PHASE
      end

      # One member's blockers, from the check's structured diagnostics.
      #
      # @return [Hash] member, blockers (deduped [name, version, remote]),
      #   inspectable (whether the lockfile had registry pins at all)
      def member_blockers(member)
        lockfile = File.join(member.root, "Gemfile.lock")
        return {member: member, blockers: [], inspectable: false} unless File.file?(lockfile)

        pins = registry_pins(lockfile)
        result = PublishedVersionCheck.call(member: member)
        blockers = result.diagnostics
          .select { |diagnostic| diagnostic["kind"] == BLOCKER_KIND }
          .map { |diagnostic| [diagnostic["gem"], diagnostic["version"], diagnostic["remote"]] }
          .uniq

        {member: member, blockers: blockers, inspectable: !pins.empty?}
      end

      def registry_pins(lockfile)
        Kettle::Dev::LockfileReset.registry_gem_specs_from_source(File.read(lockfile))
      rescue
        []
      end

      # Blockers that are actually installed in a gem home and can therefore be
      # removed, deduplicated across members by [name, version].
      #
      # A blocker that is not installed in a gem home is a PATH or git source
      # checkout: `gem uninstall` cannot remove it, and including one would abort
      # the whole batch. Those are reported rather than attempted.
      #
      # The version is normalized by stripping any platform suffix, because a
      # lockfile pins `nokogiri (1.19.4-x86_64-linux-gnu)` while gem homes store
      # the spec as `nokogiri-1.19.4-x86_64-linux-gnu.gemspec` and
      # #installed_versions records it as 1.19.4.
      def removable_candidates(findings)
        findings.flat_map { |finding| normalized_blockers(finding) }
          .uniq
          .select { |name, version| installed_versions(name).include?(version) }
      end

      # A finding's blockers as [name, Gem::Version] pairs, minus any whose version
      # cannot be parsed. Shared by #removable_candidates and #annotate_contributors
      # so both see identical pairs and cannot drift apart.
      def normalized_blockers(finding)
        finding.fetch(:blockers).filter_map do |name, version, _remote|
          normalized = normalize_version(version)
          [name, normalized] unless normalized.nil?
        end
      end

      # Strips any platform suffix and parses, rejecting blanks.
      #
      # The blank guard matters: `Gem::Version.new("")` returns version "0" rather
      # than raising, so an empty version from a malformed diagnostic would become
      # a bogus `name:0` uninstall argument instead of being skipped.
      #
      # @return [Gem::Version, nil]
      def normalize_version(version)
        text = version.to_s.split("-", 2).first.to_s.strip
        return nil if text.empty?

        parse_gem_version(text)
      end

      # Adds `:own` — the subset of the global removable set this member pinned.
      #
      # Computed once here rather than on demand: three call sites need it
      # (host selection, contributing filter, per-member reporting), and each
      # would otherwise re-run the same normalization and membership test.
      def annotate_contributors(findings, removable)
        findings.map do |finding|
          own = normalized_blockers(finding).select { |candidate| removable.include?(candidate) }.uniq
          finding.merge(own: own)
        end
      end

      # Per-member reporting. Members that contributed removable blockers get the
      # shared batch outcome; the rest get a plain informational result.
      def informational_results(annotated)
        annotated.filter_map do |finding|
          next if finding.fetch(:own).any?

          member = finding.fetch(:member)
          message = if finding.fetch(:blockers).any?
            unremovable_blockers_message(finding)
          elsif finding.fetch(:inspectable)
            NO_BLOCKERS_MESSAGE
          else
            NOT_INSPECTABLE_MESSAGE
          end
          informational_result(member: member, message: message)
        end
      end

      def contributors(annotated)
        annotated.select { |finding| finding.fetch(:own).any? }
      end

      # Names the blockers this member pinned that cannot be removed here, and
      # why, so a cross-family offender is attributable rather than mysterious.
      def unremovable_blockers_message(finding)
        names = finding.fetch(:blockers).map { |name, version, _remote| "#{name} #{version}" }
        "#{NOT_REMOVABLE_PREFIX}#{names.join(", ")}"
      end

      # Runs the batch once, then reports that one outcome against every member
      # that contributed to it. See the class comment for why a single batched
      # invocation is required rather than one per gem.
      def batched_cleanup_results(annotated, removable)
        contributing = contributors(annotated)
        # Defensive: `removable` is derived from findings' own blockers, so a
        # non-empty set always has at least one contributor. Guarded anyway
        # because a nil host would raise NoMethodError inside the uninstall.
        host = contributing.first&.fetch(:member)
        return [] if host.nil?

        command = batched_uninstall_command(removable)
        # gem uninstall does not depend on the working directory, so the first
        # contributing member provides a real directory to execute in.
        outcome = if execute
          verified_uninstall_outcome(candidates: removable, host: host, command: command)
        else
          dry_run_uninstall_outcome(command: command)
        end

        contributing.map { |finding| member_result(finding, outcome) }
      end

      # One member's view of the shared batch outcome, naming the gems that member
      # pinned so a failure is attributable rather than mysterious.
      #
      # The member's own contribution comes from the annotated finding:
      # PublishedVersionCheck hits the registry, so re-invoking it during
      # reporting would add a network round-trip per member.
      def member_result(finding, outcome)
        member = finding.fetch(:member)
        own = finding.fetch(:own)
        own_reason = describe_gem_versions(own)
        reason = if outcome.ok? || own.empty?
          outcome.reason
        else
          "batched gem uninstall including #{own_reason} failed"
        end
        outcome.dup.tap do |copy|
          copy.member_name = member.name
          copy.workdir = member.root
          copy.stdout = outcome.skipped ? "would uninstall #{own_reason}" : outcome.stdout
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
    end
  end
end
