# frozen_string_literal: true

require "bundler"
require "kettle/dev/bundler_pinning"

module Kettle
  module Family
    # Family-level preflight: bundle-mutating commands run on the latest
    # stable Bundler, or stop before any member is touched.
    #
    # Why this gate exists: Bundler updates used to happen as a side effect
    # of commands that were not about Bundler (a bare `--bundler` in a
    # configured normalize_lockfiles_command), which drifted BUNDLED WITH
    # pins and could pull a prerelease (the 4.1.0.betaN infection vector).
    # Bundler updates are owned by ONE command — update-bundler (bupb) — and
    # the other bundle-mutating commands verify the family is current before
    # touching a member, so drift surfaces as a named preflight failure with
    # the remedy instead of a mid-run Bundler error.
    #
    # "Latest stable" means the newest non-prerelease version the registry
    # serves, minus Kettle::Dev::BundlerPinning::HELD_VERSIONS (known-bad
    # stables). Fails open when the registry cannot be consulted: an offline
    # run is never blocked by network conditions.
    class BundlerVersionCheck
      PHASE = "bundler_version_check"

      # Commands gated by the preflight. bupb / update-bundler are
      # deliberately absent: they are the remedy the diagnostics point at,
      # and gating them would deadlock the fix.
      GATED_COMMANDS = %w[bup template].freeze

      def self.gated?(command)
        GATED_COMMANDS.include?(command.to_s)
      end

      def self.call(config:, members:)
        new(config: config, members: members).call
      end

      def initialize(config:, members:)
        @config = config
        @members = members
      end

      def call
        found = diagnostics
        CommandResult.new(
          member_name: config.family_name,
          phase: PHASE,
          command: ["internal", PHASE],
          workdir: config.root,
          status: found.empty? ? 0 : 1,
          success: found.empty?,
          stdout: found.map { |diagnostic| diagnostic.fetch("message") }.join("\n"),
          stderr: "",
          elapsed_seconds: 0.0,
          skipped: false,
          reason: found.empty? ? nil : "Bundler drifted from the latest stable",
          diagnostics: found
        )
      end

      private

      attr_reader :config, :members

      def diagnostics
        expected = Kettle::Dev::BundlerPinning.published_stable
        return [] unless expected

        installed_diagnostics(expected) + lockfile_diagnostics(expected)
      end

      def installed_diagnostics(expected)
        installed = Kettle::Dev::BundlerPinning.installed_stable
        return [missing_installed_diagnostic(expected)] unless installed
        return [] if installed == expected

        [installed_drift_diagnostic(installed, expected)]
      end

      def missing_installed_diagnostic(expected)
        {
          "kind" => "bundler_not_installed",
          "member" => config.family_name,
          "expected" => expected.to_s,
          "actual" => nil,
          "message" => "no stable Bundler is installed; " \
            "run `kettle-family update-bundler --execute` to install #{expected} and re-pin the family"
        }
      end

      def installed_drift_diagnostic(installed, expected)
        held_reason = Kettle::Dev::BundlerPinning.held_reason(installed)
        {
          "kind" => "bundler_installed_drift",
          "member" => config.family_name,
          "expected" => expected.to_s,
          "actual" => installed.to_s,
          "held" => !held_reason.nil?,
          "message" => installed_drift_message(installed, expected, held_reason)
        }
      end

      def installed_drift_message(installed, expected, held_reason)
        if held_reason
          "installed stable Bundler #{installed} is a known-bad held version (#{held_reason}); " \
            "run `kettle-family update-bundler --execute` to move the family to #{expected}"
        elsif installed < expected
          "installed stable Bundler #{installed} lags the registry's latest stable #{expected}; " \
            "run `kettle-family update-bundler --execute`"
        else
          "installed stable Bundler #{installed} is newer than the registry's latest stable #{expected}; " \
            "if #{installed} is known-bad, register it in Kettle::Dev::BundlerPinning::HELD_VERSIONS"
        end
      end

      def lockfile_diagnostics(expected)
        members.map { |member| lockfile_diagnostic(member, expected) }.compact
      end

      def lockfile_diagnostic(member, expected)
        pinned = bundled_with(member)
        return nil unless pinned
        return nil if pinned == expected

        {
          "kind" => "bundler_lockfile_drift",
          "member" => member.name,
          "lockfile" => File.join(member.root, "Gemfile.lock"),
          "expected" => expected.to_s,
          "actual" => pinned.to_s,
          "message" => lockfile_drift_message(member, pinned, expected)
        }
      end

      def lockfile_drift_message(member, pinned, expected)
        prerelease = pinned.prerelease? ? " (a prerelease — the reinfection vector)" : ""
        "#{member.name} pins Bundler #{pinned}#{prerelease} in BUNDLED WITH, " \
          "but the latest stable is #{expected}; run `kettle-family update-bundler --execute`"
      end

      # Bundler's own lockfile parser owns the BUNDLED WITH trailer. A
      # lockfile without one (ancient), or one Bundler cannot parse, is not
      # gated here — readiness and Bundler itself report those louder.
      def bundled_with(member)
        lockfile = File.join(member.root, "Gemfile.lock")
        return nil unless File.file?(lockfile)

        Bundler::LockfileParser.new(Bundler.read_file(lockfile)).bundler_version
      rescue Bundler::BundlerError, ArgumentError
        nil
      end
    end
  end
end
