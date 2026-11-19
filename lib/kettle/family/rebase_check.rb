# frozen_string_literal: true

require "open3"
require "kettle/dev"

require_relative "member_reporter"

module Kettle
  module Family
    # Family-level preflight: member checkouts are synced to their upstream
    # (git pull --rebase --autostash, via kettle-dev's Rebase) before a
    # bundle- or history-mutating command touches them.
    #
    # Why this gate exists: template / gha-sha-pins / bup / bump assume each
    # member checkout is at the tip of its upstream branch. When it isn't,
    # the command produces divergent commits, stale lockfiles, or dies
    # mid-run on a rebase conflict. Surfacing that here — one result per
    # member, live member_start / command_step / member_complete events on
    # the family event tape — turns a mid-run git error into a named
    # preflight phase.
    #
    # Semantics:
    #   * One CommandResult per member (phase "rebase_check"). Members whose
    #     sync failed are excluded from the gated command by the caller; the
    #     rest continue.
    #   * A monorepo (members sharing a git root) is synced once per root;
    #     each member still gets its own result and events.
    #   * Skipped when nested inside an outer kettle command that already
    #     synced (KETTLE_REBASE_NESTED set, e.g. by kettle-family's own
    #     member-command env, or a kettle-release parent).
    #   * Fail-open: no upstream or an unreachable one yields an ok result
    #     marked skipped — offline work and local-only branches are never
    #     blocked.
    #   * Plan (non-execute) runs never reach this check; the workflow gates
    #     it on execute.
    class RebaseCheck
      PHASE = "rebase_check"

      # Gated commands. Release is deliberately absent: branch-stack release
      # flows sync their target lanes themselves. bupb / update-bundler are
      # absent: they are the remedy for stale bundles, and gating them could
      # deadlock the fix. sync / pull / up are absent: they ARE sync commands.
      GATED_COMMANDS = %w[bump bup template gha-sha-pins].freeze

      NESTED_ENV = "KETTLE_REBASE_NESTED"
      FALSEY_ENV = %w[false 0 no off].freeze

      def self.gated?(command)
        GATED_COMMANDS.include?(command.to_s)
      end

      def self.nested?(env = ENV)
        value = env[NESTED_ENV]
        return false if value.nil?

        !FALSEY_ENV.include?(value.to_s.strip.downcase)
      end

      def self.call(config:, members:, event_tape: nil)
        new(config: config, members: members, event_tape: event_tape).call
      end

      def initialize(config:, members:, event_tape: nil)
        @config = config
        @members = members
        @event_tape = event_tape
      end

      def call
        return [] if self.class.nested?

        reporter = MemberReporter.build(command: PHASE, members: members, io: nil, tape: event_tape, execute: true)
        sync_by_root = {}
        members.map do |member|
          reporter&.start_member(member, steps: 1)
          reporter&.step_started(member, PHASE)
          started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          sync = sync_by_root[member.root] ||= rebase_for(member.root)
          result = member_result(member, sync, Process.clock_gettime(Process::CLOCK_MONOTONIC) - started)
          reporter&.step_finished(member, PHASE, ok: result.ok?, elapsed_seconds: result.elapsed_seconds)
          reporter&.finish_member(member, success: result.ok?)
          result
        end
      ensure
        reporter&.finish
      end

      private

      attr_reader :config, :members, :event_tape

      def member_result(member, sync, elapsed)
        case sync.status
        when :ok, :updated
          member_command_result(member, sync, success: true, elapsed: elapsed)
        when :skipped_no_upstream, :skipped_unreachable, :skipped_nested
          member_command_result(member, sync, success: true, elapsed: elapsed, skipped: true)
        when :conflict
          member_command_result(member, sync, success: false, elapsed: elapsed, diagnostics: [{
            "type" => "rebase_conflict",
            "member" => member.name,
            "message" => sync.message,
            "conflicts" => sync.conflicts
          }])
        else
          member_command_result(member, sync, success: false, elapsed: elapsed, diagnostics: [{
            "type" => "rebase_error",
            "member" => member.name,
            "message" => sync.message
          }])
        end
      end

      def member_command_result(member, sync, success:, elapsed:, skipped: false, diagnostics: [])
        CommandResult.new(
          member_name: member.name,
          phase: PHASE,
          command: ["internal", PHASE],
          workdir: member.root,
          status: success ? 0 : 1,
          success: success,
          stdout: sync.message.to_s,
          stderr: "",
          elapsed_seconds: elapsed,
          skipped: skipped,
          reason: success ? nil : "checkout not synced to upstream",
          diagnostics: diagnostics
        )
      end

      def rebase_for(root)
        return Kettle::Dev::Rebase.call(root: root) if defined?(Kettle::Dev::Rebase)

        shell_out_fallback(root)
      end

      # kettle-family's kettle-dev floor predates the Rebase module; until the
      # floor rises past the introducing release, fall back to the executable
      # the same release ships.
      def shell_out_fallback(root)
        stdout, _stderr, status = Open3.capture3("kettle-rebase", root)
        FallbackResult.new(ok: status.success?, message: stdout.to_s.strip)
      rescue SystemCallError => error
        FallbackResult.new(ok: false, message: "kettle-rebase unavailable (upgrade kettle-dev) and not on PATH: #{error.message}")
      end

      # Minimal duck-type stand-in for Kettle::Dev::Rebase::Result when only
      # the executable is available.
      class FallbackResult
        attr_reader :message

        def initialize(ok:, message:)
          @ok = ok
          @message = message
        end

        def ok?
          @ok
        end

        def status
          ok? ? :ok : :error
        end

        def conflicts
          []
        end
      end
    end
  end
end
