# frozen_string_literal: true

require "fileutils"

module Kettle
  module Family
    # Shared machinery for uninstalling locally installed gem versions.
    #
    # Two commands need this and they must not diverge:
    #
    # - +UnreleasedGemCleanup+ (`clean-unreleased`) derives its own candidates
    #   from family members' release state.
    # - +BlockerCleanup+ (`clean-blockers`) receives candidates from a check's
    #   structured diagnostics, which may name gems in other families.
    #
    # What they share is everything that is hard to get right, so it lives here
    # once:
    #
    # 1. Enumerating what is actually installed, by scanning gem homes rather
    #    than asking RubyGems.
    # 2. Building ONE batched `gem uninstall` invocation rather than one per gem,
    #    and retrying once with `--ignore-dependencies` when the batch aborts on
    #    a dependent that is not part of the batch.
    # 3. Removing the cached .gem as well as the installed specification:
    #    `gem uninstall` leaves cache/<name>-<version>.gem behind, and the next
    #    `bundle install` reinstalls the same unreleased version from that cache
    #    without touching the network -- observed live, four gems uninstalled by
    #    clean-blockers were back after one bundle install. A cleanup that leaves
    #    the cache intact does not hold.
    # 4. Verifying removal afterwards, because `gem uninstall` exits 0 when it
    #    removes nothing.
    #
    # See +UnreleasedGemCleanup+'s class comment for the full reasoning behind
    # each; that comment documents why these are not optional refinements.
    #
    # Every method is private on inclusion: this is internal machinery, and
    # including it must not widen the public API of the commands that use it.
    module GemUninstallSupport
      private

      # Versions installed for +name+ in a gem home, oldest first.
      #
      # Scans the filesystem rather than asking RubyGems, because every RubyGems
      # enumeration API is bundle-scoped: under `bundle exec`,
      # +find_all_by_name+, +stubs_for+ and +Specification.all+ all report only
      # the versions the active bundle resolves. An unreleased version installed
      # in the gem home but not pinned by the lockfile is therefore invisible,
      # which makes cleanup blind in exactly the state it exists to correct.
      # Observed live with kettle-rb: `gem list` showed 0.1.14, 0.1.15 and
      # 0.1.16, while +find_all_by_name+ under `bundle exec` returned only
      # 0.1.15.
      #
      # @param name [String] gem name
      # @return [Array<Gem::Version>] installed versions, sorted ascending
      def installed_versions(name)
        gem_home_specification_dirs.flat_map { |dir| installed_spec_versions_in(dir, name) }.uniq.sort
      end

      # Specification directories that live under a Gem.path root.
      #
      # Only those count as installed gems. A PATH or git source checkout that
      # bundler put on the load path is not in a gem home, so it stays excluded:
      # `gem uninstall` cannot remove one, and a single bogus candidate would
      # abort the whole batch.
      #
      # @return [Array<String>]
      def gem_home_specification_dirs
        Gem::Specification.dirs.select do |dir|
          path = dir.to_s
          !path.empty? && Gem.path.any? { |root| path.start_with?("#{root}#{File::SEPARATOR}") }
        end
      end

      # Versions recorded by `.gemspec` files for +name+ in one directory.
      #
      # Specifications are stored as `name-VERSION.gemspec`, or
      # `name-VERSION-PLATFORM.gemspec` for a native gem. The version is the part
      # before the first hyphen, which matches Gem::Specification#version and so
      # excludes the platform. A filename whose version part does not parse is
      # skipped rather than guessed at, so a similarly named gem (name-extra)
      # cannot become a candidate.
      #
      # @return [Array<Gem::Version>]
      def installed_spec_versions_in(dir, name)
        prefix = "#{name}-"
        Dir.glob(File.join(dir, "#{prefix}*.gemspec")).filter_map do |file|
          version_text = File.basename(file, ".gemspec").delete_prefix(prefix).split("-", 2).first.to_s
          version = parse_gem_version(version_text)
          version unless version.nil?
        end
      end

      # @return [Gem::Version, nil] nil when +text+ is not a parseable version
      def parse_gem_version(text)
        Gem::Version.new(text)
      rescue ArgumentError, TypeError
        nil
      end

      # The one batched uninstall invocation for a set of candidates.
      #
      # Versions are given as `name:version` arguments rather than `--version`,
      # which RubyGems rejects alongside multiple gems. `--all` is deliberately
      # not passed: with gem arguments present it is redundant, and with no
      # arguments it means `uninstall_all`, which removes every gem in the gem
      # home. Omitting it makes an empty argument list a plain usage error instead
      # of a wipe.
      #
      # @param candidates [Array<Array(String, Gem::Version, String)>] name/version pairs
      # @return [Array<String>] argv for the single invocation
      def batched_uninstall_command(candidates)
        ["gem", "uninstall", *candidates.map { |name, version| "#{name}:#{version}" }, "--executables"]
      end

      # Runs the batch, then re-enumerates to prove removal actually happened.
      #
      # `gem uninstall` exits 0 and prints "Gem 'name' is not installed" when it
      # removes nothing, so the exit status alone cannot distinguish a completed
      # cleanup from one that found the wrong gem home and silently did nothing.
      # Reporting ok in that case is the same failure mode as the enumeration bug
      # this support exists to prevent: a success verdict over work that never
      # happened. Any surviving version turns the outcome into a failure naming it.
      #
      # @param candidates [Array<Array(String, Gem::Version)>] what was requested
      # @param host [Member] member whose root provides a working directory
      # @param command [Array<String>] argv from #batched_uninstall_command
      # @return [CommandResult]
      def verified_uninstall_outcome(candidates:, host:, command:)
        outcome = runner.call(member: host, phase: uninstall_phase, command: command)
        outcome = retry_uninstall_ignoring_dependencies(candidates: candidates, host: host, outcome: outcome)
        return outcome unless outcome.success && !outcome.skipped

        remove_cached_gem_files(candidates)

        remaining = candidates.select { |name, version| installed_versions(name).include?(version) }
        surviving_cache = candidates.flat_map { |name, version| surviving_cache_files(name, version) }
        return outcome if remaining.empty? && surviving_cache.empty?

        survivors = describe_gem_versions(remaining)
        survivors = "#{survivors}, cached .gem left: #{surviving_cache.join(", ")}" unless surviving_cache.empty?
        CommandResult.new(
          member_name: nil,
          phase: uninstall_phase,
          command: command,
          workdir: host.root,
          status: outcome.status,
          success: false,
          stdout: outcome.stdout.to_s,
          stderr: "#{outcome.stderr}still present after gem uninstall: #{survivors}".strip,
          elapsed_seconds: outcome.elapsed_seconds,
          skipped: false,
          reason: "gem uninstall reported success but #{survivors} remains"
        )
      end

      # Cached .gem files for +name+ at +version+ surviving in a gem home,
      # including platform variants (name-version-x86_64-linux.gem).
      #
      # @return [Array<String>]
      def surviving_cache_files(name, version)
        Gem.path.flat_map do |root|
          Dir.glob(File.join(root.to_s, "cache", "#{name}-#{version}{,*}.gem"))
        end
      end

      # Removes the cached .gem files for the candidates. Direct filesystem
      # removal, like #installed_versions: this is local state RubyGems owns
      # only loosely, and there is no `gem` subcommand for pruning one cached
      # version.
      def remove_cached_gem_files(candidates)
        candidates.flat_map { |name, version| surviving_cache_files(name, version) }.each do |path|
          FileUtils.rm_f(path)
        end
      end

      # The dry-run counterpart to #verified_uninstall_outcome: names the command
      # without running it.
      #
      # @return [CommandResult]
      def dry_run_uninstall_outcome(command:)
        CommandResult.new(
          member_name: nil,
          phase: uninstall_phase,
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

      # Retries a failed batch once with `--ignore-dependencies`.
      #
      # `gem uninstall` aborts the whole batch with Gem::DependencyRemovalException
      # when an installed gem OUTSIDE the batch depends on one being removed
      # (dependents inside the batch are handled by RubyGems topologically
      # sorting the requested set). The candidates are unreleased development
      # versions whose dependents are restored by the next `install` run, so the
      # refusal protects nothing the cleanup must preserve -- but the abort may
      # already have removed part of the batch, so the retry re-batches only
      # what is still installed. The escalation is recorded in stderr so the
      # weaker guarantee is visible rather than silent.
      #
      # @return [CommandResult] the retried outcome, or the original when no
      #   retry applies
      def retry_uninstall_ignoring_dependencies(candidates:, host:, outcome:)
        return outcome if outcome.success || outcome.skipped
        return outcome unless outcome.stderr.to_s.include?("Gem::DependencyRemovalException")

        remaining = candidates.select { |name, version| installed_versions(name).include?(version) }
        return outcome if remaining.empty?

        command = batched_uninstall_command(remaining) + ["--ignore-dependencies"]
        retried = runner.call(member: host, phase: uninstall_phase, command: command)
        return retried unless retried.success

        CommandResult.new(
          member_name: nil,
          phase: uninstall_phase,
          command: command,
          workdir: host.root,
          status: retried.status,
          success: true,
          stdout: retried.stdout.to_s,
          stderr: [
            retried.stderr.to_s,
            "initial batch aborted on an out-of-batch dependent (Gem::DependencyRemovalException); retried with --ignore-dependencies"
          ].reject(&:empty?).join("\n"),
          elapsed_seconds: outcome.elapsed_seconds + retried.elapsed_seconds,
          skipped: false,
          reason: retried.reason
        )
      end

      # @return [String] "name version, name version" for reporting
      def describe_gem_versions(candidates)
        candidates.map { |name, version| "#{name} #{version}" }.join(", ")
      end
    end
  end
end
