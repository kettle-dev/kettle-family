# frozen_string_literal: true

module Kettle
  module Family
    # Removes locally installed gem versions that no registry has published.
    #
    # Why this exists: bundler resolves against the local gem dir and picks the
    # highest version satisfying a constraint, so a locally built unreleased
    # version always wins over the published one. Floor constraints are `>=`, so
    # there is no ceiling that stops it, and every `bundle install` or
    # `bundle lock` re-pins the offender. Detection cannot fix resolution — the
    # offenders have to be removed. Left in place they produce lockfiles that no
    # isolated environment can resolve, which surfaces much later as an opaque
    # bundler error ("locked to kettle-jem (7.1.29) ... can no longer be
    # found").
    #
    # All candidates across the whole family are removed in ONE `gem uninstall`
    # invocation rather than one invocation per gem. That is not merely fewer
    # processes: RubyGems' `uninstall_specific` builds a Gem::DependencyList from
    # every requested gem and removes them via
    # `strongly_connected_components.flatten.reverse`, a topological sort of the
    # whole set that removes dependents before their dependencies. A per-gem
    # invocation sees only one gem and cannot sort, so it raises
    # Gem::DependencyRemovalException ("Uninstallation aborted due to dependent
    # gem(s)") whenever another installed gem still depends on it. Family
    # members are heavily interdependent, so per-gem removal fails on the
    # foundations: observed live, removing tree_haver first failed because
    # ast-merge still required it, and four iterative passes still left two gems
    # installed. One batched invocation removed both.
    #
    # The single run is still reported per member. Report keys results by member
    # name for commands in MEMBER_RESULT_COMMANDS, and treats a member with no
    # result as pending, which fails the whole summary. So attributing the batch
    # to one synthetic family-level name left every member pending and reported
    # `outcome: failure` with `failed: none`. Each contributing member instead
    # receives the shared outcome of the one run.
    #
    # `--all` is deliberately not passed. With gem arguments present it is
    # redundant (RubyGems routes to `uninstall_specific` either way), and with no
    # arguments it means `uninstall_all`, which removes every gem in the gem
    # home. Omitting it makes an empty argument list a plain usage error instead
    # of a wipe. `--version` cannot be used either, because RubyGems rejects it
    # alongside multiple gems; versions are given as `name:version` arguments,
    # the form its own error message prescribes.
    class UnreleasedGemCleanup
      PHASE = "clean_unreleased"
      UNKNOWN_RELEASED_MESSAGE = "latest released version is unknown; no cleanup attempted"

      def initialize(config:, members:, execute: false, runner: nil)
        @config = config
        @members = members
        @execute = execute
        @runner = runner || CommandRunner.new(execute: execute)
      end

      def results
        release_states = release_state_by_member
        # Resolved once per member: candidates and the member's non-uninstall
        # diagnostics both derive from the same release state and installed spec
        # scan, so pairing them in one pass keeps installed specs enumerated a
        # single time and avoids re-reading release_states per member.
        planned = members.map do |member|
          release_state = release_states[member.name]
          candidates = unreleased_candidates(member: member, release_state: release_state)
          {
            member: member,
            candidates: candidates,
            diagnostics: member_diagnostics(member: member, release_state: release_state, candidates: candidates)
          }
        end
        diagnostics = planned.flat_map { |entry| entry.fetch(:diagnostics) }
        contributors = planned.reject { |entry| entry.fetch(:candidates).empty? }
        return diagnostics if contributors.empty?

        diagnostics + batched_cleanup_results(contributors)
      end

      private

      attr_reader :config, :members, :execute, :runner

      def release_state_by_member
        ReleaseStateCheck.new(config: config, members: members).results.each_with_object({}) do |result, memo|
          memo[result.member_name] = result
        end
      end

      # Per-member outcomes that are not an uninstall: a release state that could
      # not be read, a version that cannot be compared, or nothing to do. These
      # stay per member so a failure names the member it came from. Members that
      # do have candidates are reported by the batch result instead.
      def member_diagnostics(member:, release_state:, candidates:)
        return [release_state_failure(member: member, release_state: release_state)] unless release_state&.ok?

        latest_released = latest_released_version(release_state.state)
        return [informational_result(member: member, message: UNKNOWN_RELEASED_MESSAGE)] unless latest_released
        return [] unless candidates.empty?

        [informational_result(member: member, message: "no unreleased installed versions found")]
      end

      # Installed versions newer than anything published, as [name, version] pairs.
      #
      # Only genuinely installed gems count. Under `bundle exec`, bundler adds
      # PATH and git sources to the load path, so a source checkout can appear as
      # a spec — e.g. tree_haver 7.1.10 resolving to gems/tree_haver rather than a
      # gem home. That is not an installed gem and `gem uninstall` cannot remove
      # it, so treating it as a candidate would report work that can never
      # succeed, and once batched one such candidate would abort the whole
      # removal. installed_versions therefore scans only specification
      # directories under a Gem.path root, which excludes source checkouts by
      # construction.
      def unreleased_candidates(member:, release_state:)
        return [] unless release_state&.ok?

        latest_released = latest_released_version(release_state.state)
        return [] unless latest_released

        name = member.name
        installed_versions(name).filter_map do |version|
          [name, version] if version > latest_released
        end
      end

      def latest_released_version(state)
        value = state.fetch("latest_released", nil).to_s
        return nil if value.empty? || value == "unknown"

        Gem::Version.new(value.delete_prefix("v"))
      rescue ArgumentError
        nil
      end

      # Versions present in a gem home, oldest first.
      #
      # This scans the filesystem rather than asking RubyGems, because every
      # RubyGems enumeration API is bundle-scoped: under `bundle exec`,
      # find_all_by_name, stubs_for and Specification.all all report only the
      # versions the active bundle resolves. An unreleased version installed in
      # the gem home but not pinned by the lockfile is therefore invisible, which
      # makes cleanup blind in exactly the state it exists to correct — once the
      # lockfile re-resolves to released versions, the offenders it should remove
      # stop being enumerated and the run reports "no unreleased installed
      # versions found" with outcome success while leaving them installed.
      # Observed live with kettle-rb: `gem list` showed 0.1.14, 0.1.15 and
      # 0.1.16, while find_all_by_name under bundle exec returned only 0.1.15.
      def installed_versions(name)
        gem_home_specification_dirs.flat_map { |dir| installed_spec_versions_in(dir, name) }.uniq.sort
      end

      # Only specification directories under a Gem.path root are scanned. A PATH
      # or git source checkout that bundler put on the load path is not in a gem
      # home, so it stays excluded: `gem uninstall` cannot remove one, and one
      # bogus candidate would abort the whole batch.
      def gem_home_specification_dirs
        Gem::Specification.dirs.select do |dir|
          path = dir.to_s
          !path.empty? && Gem.path.any? { |root| path.start_with?("#{root}#{File::SEPARATOR}") }
        end
      end

      # Specifications are stored as `name-VERSION.gemspec`, or
      # `name-VERSION-PLATFORM.gemspec` for a native gem. The version is the part
      # before the first hyphen, which matches Gem::Specification#version and so
      # excludes the platform exactly as the previous implementation did. A
      # filename whose version part does not parse is skipped rather than guessed
      # at, so a similarly named gem (name-extra) cannot become a candidate.
      def installed_spec_versions_in(dir, name)
        prefix = "#{name}-"
        Dir.glob(File.join(dir, "#{prefix}*.gemspec")).filter_map do |file|
          version_text = File.basename(file, ".gemspec").delete_prefix(prefix).split("-", 2).first.to_s
          version = parse_version(version_text)
          version unless version.nil?
        end
      end

      def parse_version(text)
        Gem::Version.new(text)
      rescue ArgumentError, TypeError
        nil
      end

      # Runs the batch once, then reports that one outcome against every member
      # whose gems were in it. See the class comment for why per-member results
      # are required even though only one command runs.
      def batched_cleanup_results(contributors)
        candidates = contributors.flat_map { |entry| entry.fetch(:candidates) }
        # Versions are given as `name:version` arguments rather than `--version`,
        # which RubyGems rejects alongside multiple gems. See the class comment
        # for why `--all` is omitted.
        command = ["gem", "uninstall", *candidates.map { |name, version| "#{name}:#{version}" }, "--executables"]
        # gem uninstall does not depend on the working directory, so the first
        # contributing member provides a real directory to execute in.
        host = contributors.first.fetch(:member)
        outcome = execute ? runner.call(member: host, phase: PHASE, command: command) : dry_run_outcome(command)

        contributors.map do |entry|
          member_result(entry.fetch(:member), outcome, entry.fetch(:candidates))
        end
      end

      def dry_run_outcome(command)
        CommandResult.new(
          member_name: nil,
          phase: PHASE,
          command: command,
          workdir: nil,
          status: nil,
          success: true,
          stdout: nil,
          stderr: "",
          elapsed_seconds: 0.0,
          skipped: true,
          reason: "dry-run; pass --execute to run"
        )
      end

      # One member's view of the shared batch outcome. The command and exit state
      # are common to the whole batch, but each member reports only its own gems,
      # so the per-member report stays readable and a failure names every gem
      # that member contributed.
      def member_result(member, outcome, own_candidates)
        own = describe(own_candidates)
        outcome_reason = outcome.reason
        # Equivalent to `ok? ? reason : (own.empty? ? reason : batch message)`,
        # with outcome.reason read once instead of twice.
        reason = if outcome.ok? || own_candidates.empty?
          outcome_reason
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

      def describe(candidates)
        candidates.map { |name, version| "#{name} #{version}" }.join(", ")
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
