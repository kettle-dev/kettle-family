# frozen_string_literal: true

require "open3"

module Kettle
  module Family
    class CommandRunner
      def initialize(execute: false, accept: true, gem_signing_password: nil)
        @execute = execute
        @accept = accept
        @gem_signing_password = gem_signing_password
      end

      def call(member:, phase:, command:, env: {}, interactive: false)
        argv = command_argv(member: member, command: command, env: env)
        process_env = process_env(member: member, env: env)
        return skipped_result(member: member, phase: phase, argv: argv) unless execute

        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        stdout, stderr, status = with_unbundled_environment do
          if interactive
            run_interactive(env: process_env, argv: argv, chdir: member.root)
          else
            Open3.capture3(process_env, *argv, chdir: member.root)
          end
        end
        stdout = normalize_output(stdout)
        stderr = normalize_output(stderr)
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

      attr_reader :execute, :accept, :gem_signing_password

      def run_interactive(env:, argv:, chdir:)
        return run_interactive_pty(env: env, argv: argv, chdir: chdir) if pty_available?

        run_interactive_open3(env: env, argv: argv, chdir: chdir)
      end

      def run_interactive_pty(env:, argv:, chdir:)
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
                  handle_interactive_prompt(input, chunk)
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

      def run_interactive_open3(env:, argv:, chdir:)
        captured_stdout = +""
        captured_stderr = +""
        status = nil
        Open3.popen3(env, *argv, chdir: chdir) do |input, output, error, wait_thread|
          readers = [output, error]
          readers << $stdin if $stdin.tty?
          until readers.empty?
            ready = IO.select(readers)
            ready.first.each do |reader|
              if reader.equal?($stdin)
                input.write($stdin.readpartial(1024))
              else
                read_interactive_stream(reader, output, input, captured_stdout, captured_stderr, readers)
              end
            end
          end
          status = wait_thread.value
        end
        [captured_stdout, captured_stderr, status]
      end

      def read_interactive_stream(reader, output, input, captured_stdout, captured_stderr, readers)
        chunk = reader.readpartial(1024)
        if reader.equal?(output)
          captured_stdout << chunk
          $stdout.print(chunk)
        else
          captured_stderr << chunk
          $stderr.print(chunk)
        end
        handle_interactive_prompt(input, chunk)
      rescue EOFError
        readers.delete(reader)
      end

      def pty_available?
        return false unless RUBY_ENGINE == "ruby"

        require "pty"
        true
      rescue LoadError
        false
      end

      def write_signing_password(input, chunk)
        return unless gem_signing_password && signing_password_prompt?(chunk)

        input.write("#{gem_signing_password}\n")
        input.flush
      end

      def handle_interactive_prompt(input, chunk)
        return if otp_prompt?(chunk)

        if accept_confirmation_prompt?(chunk)
          write_accept_response(input) if accept
          return
        end

        write_signing_password(input, chunk)
      end

      def write_accept_response(input)
        input.write("y\n")
        input.flush
      end

      def accept_confirmation_prompt?(chunk)
        chunk.match?(/\[[Yy]\/[Nn]\]\s*:?/)
      end

      def otp_prompt?(chunk)
        chunk.match?(/(?:multi-factor authentication|OTP code|one-time password|\bCode:\s*)/i)
      end

      def signing_password_prompt?(chunk)
        chunk.match?(/(?:enter\s+)?(?:PEM\s+)?pass(?:\s|-)?phrase\s*(?:for\s+[^:]+)?[:?]\s*\z/i) ||
          chunk.match?(/(?:PEM|private key) password\s*[:?]\s*\z/i)
      end

      def normalize_output(output)
        output.to_s.encode("UTF-8", invalid: :replace, undef: :replace, replace: "")
      end

      def with_unbundled_environment
        if defined?(Bundler)
          Bundler.with_unbundled_env { yield }
        else
          yield
        end
      end

      def command_argv(member:, command:, env: {})
        argv = normalize_command(command)
        return argv unless mise_configured?(member)

        injected_env = env.map { |key, value| "#{key}=#{value}" }
        mise_argv = ["mise", "exec", "-C", member.root, "--"]
        return [*mise_argv, *argv] if injected_env.empty?

        [*mise_argv, "env", *injected_env, *argv]
      end

      def process_env(member:, env:)
        return env unless mise_configured?(member)

        {}
      end

      def mise_configured?(member)
        %w[mise.toml .mise.toml .tool-versions].any? do |path|
          File.file?(File.join(member.root, path))
        end
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
