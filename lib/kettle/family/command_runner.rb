# frozen_string_literal: true

require "open3"
require "pty"

module Kettle
  module Family
    class CommandRunner
      def initialize(execute: false, gem_signing_password: nil)
        @execute = execute
        @gem_signing_password = gem_signing_password
      end

      def call(member:, phase:, command:, env: {}, interactive: false)
        argv = command_argv(member: member, command: command)
        return skipped_result(member: member, phase: phase, argv: argv) unless execute

        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        stdout, stderr, status = if interactive
          run_interactive(env: env, argv: argv, chdir: member.root)
        else
          Open3.capture3(env, *argv, chdir: member.root)
        end
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

      attr_reader :execute, :gem_signing_password

      def run_interactive(env:, argv:, chdir:)
        stdout = +""
        status = nil
        PTY.spawn(env, *argv, chdir: chdir) do |output, input, pid|
          begin
            loop do
              readers = [output]
              readers << $stdin if $stdin.tty?
              ready = IO.select(readers)
              ready.first.each do |reader|
                if reader.equal?(output)
                  chunk = output.readpartial(1024)
                  stdout << chunk
                  $stdout.print(chunk)
                  input.write("#{gem_signing_password}\n") if gem_signing_password && signing_password_prompt?(chunk)
                else
                  input.write($stdin.readpartial(1024))
                end
              end
            end
          rescue Errno::EIO
            # PTY raises EIO when the child process exits after closing the slave.
          end
          _, status = Process.wait2(pid)
        end
        [stdout, "", status]
      end

      def signing_password_prompt?(chunk)
        chunk.match?(/pass(?:\s|-)?phrase|PEM password|private key password/i)
      end

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
