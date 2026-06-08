# frozen_string_literal: true

require "open3"

module Kettle
  module Family
    class CommandRunner
      def initialize(execute: false)
        @execute = execute
      end

      def call(member:, phase:, command:, env: {})
        argv = command_argv(member: member, command: command)
        return skipped_result(member: member, phase: phase, argv: argv) unless execute

        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        stdout, stderr, status = Open3.capture3(env, *argv, chdir: member.root)
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
        CommandResult.new(
          member_name: member.name,
          phase: phase,
          command: argv,
          workdir: member.root,
          status: status.exitstatus,
          success: status.success?,
          stdout: stdout,
          stderr: stderr,
          elapsed_seconds: elapsed.round(3),
          skipped: false,
          reason: status.success? ? nil : "command failed"
        )
      end

      private

      attr_reader :execute

      def command_argv(member:, command:)
        argv = normalize_command(command)
        return argv unless File.file?(File.join(member.root, "mise.toml"))

        ["mise", "exec", "-C", member.root, "--", *argv]
      end

      def normalize_command(command)
        case command
        when Array
          command.map(&:to_s)
        when String
          ["sh", "-lc", command]
        else
          raise Error, "command must be a String or Array"
        end
      end

      def skipped_result(member:, phase:, argv:)
        CommandResult.new(
          member_name: member.name,
          phase: phase,
          command: argv,
          workdir: member.root,
          status: nil,
          success: true,
          stdout: "",
          stderr: "",
          elapsed_seconds: 0.0,
          skipped: true,
          reason: "dry-run; pass --execute to run"
        )
      end
    end
  end
end
