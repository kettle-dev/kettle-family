# frozen_string_literal: true

require "open3"
require "io/console"

module Kettle
  module Family
    class CommandRunner
      class OtpCoordinator
        def initialize(input: $stdin, output: $stdout, queue_total: nil)
          @input = input
          @output = output
          @mutex = Mutex.new
          @condition = ConditionVariable.new
          @prompting = false
          @queue_closed = false
          @generation = 0
          @completed_generation = nil
          @response = nil
          @queued_count = 0
          @queue_total = queue_total
        end

        def queue_total=(value)
          @mutex.synchronize do
            @queue_total = value
          end
        end

        def request(member_name:, chunk:)
          generation = nil
          @mutex.synchronize do
            @condition.wait(@mutex) while @prompting && @queue_closed

            if @prompting
              generation = @generation
              @queued_count += 1
              render_queue_status_locked
              return wait_for_response(generation)
            end

            @prompting = true
            @queue_closed = false
            @queued_count = 1
            @generation += 1
            generation = @generation
            start_prompt_locked(member_name: member_name)
          end

          response = read_response(chunk: chunk)
          close_queue
          @mutex.synchronize do
            @response = response
            @completed_generation = generation
            @prompting = false
            @queue_closed = false
            @condition.broadcast
            response
          end
        end

        private

        def wait_for_response(generation)
          @condition.wait(@mutex) while @prompting
          return @response if @completed_generation == generation

          ""
        end

        def close_queue
          @mutex.synchronize do
            @queue_closed = true
          end
        end

        def start_prompt_locked(member_name:)
          @output.puts
          @output.puts("[#{member_name}] RubyGems MFA requested.")
          render_queue_status_locked
          @output.puts("Queued prompts at entry will share this code; later prompts will ask again.")
        end

        def render_queue_status_locked
          suffix = @queue_total ? " / #{@queue_total}" : ""
          @output.puts("RubyGems MFA prompts queued: #{@queued_count}#{suffix}")
          @output.flush if @output.respond_to?(:flush)
        end

        def read_response(chunk:)
          @output.print("#{otp_prompt_label(chunk)} ")
          @output.flush if @output.respond_to?(:flush)
          if @input.respond_to?(:noecho) && @input.tty?
            @input.noecho(&:gets)&.chomp.to_s
          else
            @input.gets&.chomp.to_s
          end
        ensure
          @output.puts if @output.respond_to?(:puts)
        end

        def otp_prompt_label(chunk)
          chunk.to_s.lines.last&.strip.to_s.empty? ? "Code:" : chunk.to_s.lines.last.strip
        end
      end

      def initialize(execute: false, accept: true, gem_signing_password: nil, otp_coordinator: nil)
        @execute = execute
        @accept = accept
        @gem_signing_password = gem_signing_password
        @otp_coordinator = otp_coordinator
      end

      def call(member:, phase:, command:, env: {}, interactive: false, stdout_line_handler: nil)
        argv = command_argv(member: member, command: command, env: env)
        process_env = process_env(member: member, env: env)
        spawn_options = process_options
        return skipped_result(member: member, phase: phase, argv: argv) unless execute

        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        stdout, stderr, status = if interactive
          run_interactive(env: process_env, argv: argv, chdir: member.root, member_name: member.name, process_options: spawn_options)
        elsif stdout_line_handler
          run_streaming(env: process_env, argv: argv, chdir: member.root, process_options: spawn_options, stdout_line_handler: stdout_line_handler)
        else
          Open3.capture3(process_env, *argv, chdir: member.root, **spawn_options)
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

      attr_reader :execute, :accept, :gem_signing_password, :otp_coordinator

      def run_streaming(env:, argv:, chdir:, process_options:, stdout_line_handler:)
        captured_stdout = +""
        captured_stderr = +""
        stdout_line_buffer = +""
        status = nil
        Open3.popen3(env, *argv, chdir: chdir, **process_options) do |_input, output, error, wait_thread|
          readers = [output, error]
          until readers.empty?
            ready = IO.select(readers)
            ready.first.each do |reader|
              if reader.equal?(output)
                chunk = reader.readpartial(1024)
                captured_stdout << chunk
                stdout_line_buffer = stream_stdout_lines(stdout_line_buffer, chunk, stdout_line_handler)
              else
                captured_stderr << reader.readpartial(1024)
              end
            rescue EOFError
              readers.delete(reader)
            end
          end
          stdout_line_handler.call(stdout_line_buffer) unless stdout_line_buffer.empty?
          status = wait_thread.value
        end
        [captured_stdout, captured_stderr, status]
      end

      def stream_stdout_lines(buffer, chunk, handler)
        pending = buffer + chunk
        lines = pending.lines
        remainder = pending.end_with?("\n") ? +"" : lines.pop.to_s
        lines.each { |line| handler.call(line.chomp) }
        remainder
      end

      def run_interactive(env:, argv:, chdir:, member_name:, process_options:)
        return run_interactive_pty(env: env, argv: argv, chdir: chdir, member_name: member_name, process_options: process_options) if pty_available?

        run_interactive_open3(env: env, argv: argv, chdir: chdir, member_name: member_name, process_options: process_options)
      end

      def run_interactive_pty(env:, argv:, chdir:, member_name:, process_options:)
        stdout = +""
        status = nil
        PTY.spawn(env, *argv, chdir: chdir, **process_options) do |output, input, pid|
          begin
            loop do
              readers = [output]
              readers << $stdin if $stdin.tty? && !otp_coordinator
              ready = IO.select(readers)
              ready.first.each do |reader|
                if reader.equal?(output)
                  chunk = output.readpartial(1024)
                  stdout << chunk
                  $stdout.print(chunk)
                  handle_interactive_prompt(input, chunk, member_name: member_name)
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

      def run_interactive_open3(env:, argv:, chdir:, member_name:, process_options:)
        captured_stdout = +""
        captured_stderr = +""
        status = nil
        Open3.popen3(env, *argv, chdir: chdir, **process_options) do |input, output, error, wait_thread|
          readers = [output, error]
          readers << $stdin if $stdin.tty? && !otp_coordinator
          until readers.empty?
            ready = IO.select(readers)
            ready.first.each do |reader|
              if reader.equal?($stdin)
                input.write($stdin.readpartial(1024))
              else
                read_interactive_stream(reader, output, input, captured_stdout, captured_stderr, readers, member_name: member_name)
              end
            end
          end
          status = wait_thread.value
        end
        [captured_stdout, captured_stderr, status]
      end

      def read_interactive_stream(reader, output, input, captured_stdout, captured_stderr, readers, member_name:)
        chunk = reader.readpartial(1024)
        if reader.equal?(output)
          captured_stdout << chunk
          $stdout.print(chunk)
        else
          captured_stderr << chunk
          $stderr.print(chunk)
        end
        handle_interactive_prompt(input, chunk, member_name: member_name)
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

      def handle_interactive_prompt(input, chunk, member_name: nil)
        if otp_prompt?(chunk)
          write_otp_response(input, chunk, member_name: member_name) if otp_coordinator && otp_response_prompt?(chunk)
          return
        end

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

      def write_otp_response(input, chunk, member_name:)
        response = otp_coordinator.request(member_name: member_name || "release", chunk: chunk)
        return if response.to_s.empty?

        input.write("#{response}\n")
        input.flush
      end

      def accept_confirmation_prompt?(chunk)
        chunk.match?(/\[[Yy]\/[Nn]\]\s*:?/)
      end

      def otp_prompt?(chunk)
        chunk.match?(/(?:multi-factor authentication|OTP code|one-time password|\bCode:\s*)/i)
      end

      def otp_response_prompt?(chunk)
        chunk.match?(/(?:OTP code|one-time password|\bCode:\s*)/i)
      end

      def signing_password_prompt?(chunk)
        chunk.match?(/(?:enter\s+)?(?:PEM\s+)?pass(?:\s|-)?phrase\s*(?:for\s+[^:]+)?[:?]\s*\z/i) ||
          chunk.match?(/(?:PEM|private key) password\s*[:?]\s*\z/i)
      end

      def normalize_output(output)
        output.to_s.encode("UTF-8", invalid: :replace, undef: :replace, replace: "")
      end

      def command_argv(member:, command:, env: {})
        argv = normalize_command(command)
        return argv unless mise_configured?(member)

        unset_env, set_env = env.partition { |_key, value| value.nil? }
        injected_env = [
          *unset_env.flat_map { |key, _value| ["-u", key.to_s] },
          *set_env.map { |key, value| "#{key}=#{value}" }
        ]
        mise_argv = ["mise", "exec", "-C", member.root, "--"]
        return [*mise_argv, *argv] if injected_env.empty?

        [*mise_argv, "env", *injected_env, *argv]
      end

      def process_env(member:, env:)
        base_env = unbundled_process_env
        return base_env.merge(env) unless mise_configured?(member)

        base_env
      end

      def unbundled_process_env
        return Bundler.original_env if defined?(Bundler) && Bundler.respond_to?(:original_env)
        return Bundler.unbundled_env if defined?(Bundler) && Bundler.respond_to?(:unbundled_env)

        {}
      end

      def process_options
        return {unsetenv_others: true} if defined?(Bundler)

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
