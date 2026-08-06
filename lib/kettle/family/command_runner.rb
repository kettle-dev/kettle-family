# frozen_string_literal: true

require "open3"
require "io/console"
require "fileutils"

module Kettle
  module Family
    class CommandRunner
      SENSITIVE_ENV_KEYS = [
        "KETTLE_RELEASE_GEM_SIGNING_PASSPHRASE"
      ].freeze

      class OtpCoordinator
        def initialize(input: $stdin, output: $stdout, queue_total: nil, secrets_provider: nil, event_handler: nil)
          @input = input
          @output = output
          @secrets_provider = secrets_provider
          @event_handler = event_handler
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
              render_queue_status_locked(member_name: member_name)
              return wait_for_response(generation)
            end

            @prompting = true
            @queue_closed = false
            @queued_count = 1
            @generation += 1
            generation = @generation
            start_prompt_locked(member_name: member_name)
          end

          response = read_response(chunk: chunk, member_name: member_name)
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

        attr_reader :secrets_provider, :event_handler

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
          unless emit_event(
            member_name: member_name,
            action: "mfa_requested",
            label: "RubyGems MFA",
            status: "requested",
            mark: ">"
          )
            @output.puts
            @output.puts("[#{member_name}] RubyGems MFA requested.")
          end
          render_queue_status_locked(member_name: member_name)
          return if event_handler

          @output.puts("Queued prompts at entry will share this code; later prompts will ask again.")
        end

        def render_queue_status_locked(member_name:)
          suffix = @queue_total ? " / #{@queue_total}" : ""
          return if emit_event(
            member_name: member_name,
            action: "otp_queue",
            label: "RubyGems MFA prompts",
            status: "queued",
            mark: ">",
            queued: @queued_count,
            total: @queue_total
          )

          @output.puts("RubyGems MFA prompts queued: #{@queued_count}#{suffix}")
          @output.flush if @output.respond_to?(:flush)
        end

        def read_response(chunk:, member_name:)
          manual_prompt = false
          provided = read_provider_response(member_name: member_name)
          unless provided.empty?
            emit_event(
              member_name: member_name,
              action: "prompt_response",
              label: "RubyGems MFA code",
              source: secret_provider_source,
              status: "ok",
              mark: "."
            ) || @output.puts("RubyGems MFA code loaded from configured secrets provider.")
            return provided
          end

          manual_prompt = true
          prompt_label = otp_prompt_label(chunk)
          prompted_by_event_handler = emit_event(
            member_name: member_name,
            action: "manual_prompt",
            label: prompt_label,
            status: "requested",
            mark: ">"
          )
          @output.print("#{prompt_label} ") unless prompted_by_event_handler
          @output.flush if @output.respond_to?(:flush)
          response = if @input.respond_to?(:noecho) && @input.tty?
            @input.noecho(&:gets)&.chomp.to_s
          else
            @input.gets&.chomp.to_s
          end
          emit_event(
            member_name: member_name,
            action: "prompt_response",
            label: "RubyGems MFA code",
            status: response.empty? ? "failed" : "ok",
            mark: response.empty? ? "F" : "."
          )
          response
        ensure
          @output.puts if manual_prompt && !event_handler && @output.respond_to?(:puts)
        end

        def otp_prompt_label(chunk)
          chunk.to_s.lines.last&.strip.to_s.empty? ? "Code:" : chunk.to_s.lines.last.strip
        end

        def read_provider_response(member_name:)
          return "" unless secrets_provider

          @output.print("\a") if @output.respond_to?(:print)
          emit_event(
            member_name: member_name,
            action: "prompt_request",
            label: "👀 🔒 watch for authorization prompt",
            source: secret_provider_source,
            status: "started",
            mark: ">"
          )
          secrets_provider.rubygems_otp.to_s
        rescue Error => error
          raise unless @input.respond_to?(:tty?) && @input.tty?

          emit_event(
            member_name: member_name,
            action: "prompt_response",
            label: "RubyGems MFA code",
            source: secret_provider_source,
            status: "failed",
            mark: "F"
          )
          @output.puts("#{error.message}; falling back to manual OTP entry.")
          ""
        end

        def emit_event(member_name:, action:, label:, status:, mark:, **payload)
          return false unless event_handler

          event_handler.call(
            member_name,
            {
              "event_version" => 1,
              "type" => "secret_provider",
              "action" => action,
              "label" => label,
              "status" => status,
              "mark" => mark
            }.merge(payload.transform_keys(&:to_s))
          )
          true
        end

        def secret_provider_source
          return "" unless secrets_provider
          return "1Password" if secrets_provider.is_a?(Secrets::OnePassword)

          secrets_provider.class.name.to_s.split("::").last.to_s
        end
      end

      FailureStatus = Struct.new(:exitstatus) do
        def success?
          false
        end
      end
      private_constant :FailureStatus

      def initialize(execute: false, accept: true, gem_signing_password: nil, otp_coordinator: nil)
        @execute = execute
        @accept = accept
        @gem_signing_password = gem_signing_password
        @otp_coordinator = otp_coordinator
      end

      def call(member:, phase:, command:, env: {}, interactive: false, stdout_line_handler: nil, log_path: nil, passthrough_output: true)
        argv = command_argv(member: member, command: command, env: env)
        process_env = process_env(member: member, env: env)
        spawn_options = process_options
        return skipped_result(member: member, phase: phase, argv: argv) unless execute

        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        stdout, stderr, status = with_transcript(log_path, argv: argv, chdir: member.root) do |log_io|
          if interactive
            run_interactive(
              env: process_env,
              argv: argv,
              chdir: member.root,
              member_name: member.name,
              process_options: spawn_options,
              stdout_line_handler: stdout_line_handler,
              log_io: log_io,
              passthrough_output: passthrough_output
            )
          elsif stdout_line_handler
            run_streaming(env: process_env, argv: argv, chdir: member.root, process_options: spawn_options, stdout_line_handler: stdout_line_handler, log_io: log_io)
          else
            result = Open3.capture3(process_env, *argv, chdir: member.root, **spawn_options)
            transcript_write(log_io, result[0])
            transcript_write(log_io, result[1])
            result
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
          reason: status.success? ? nil : "command failed",
          output_streamed: interactive || !!stdout_line_handler,
          log_path: log_path
        )
      end

      private

      attr_reader :execute, :accept, :gem_signing_password, :otp_coordinator

      def run_streaming(env:, argv:, chdir:, process_options:, stdout_line_handler:, log_io: nil)
        captured_stdout = +""
        captured_stderr = +""
        stdout_line_buffer = +""
        status = nil
        Open3.popen3(env, *argv, chdir: chdir, **process_options) do |_input, output, error, wait_thread|
          readers = [output, error]
          until readers.empty?
            ready = IO.select(readers)
            ready.first.each do |reader|
              chunk = reader.readpartial(1024)
              if reader.equal?(output)
                captured_stdout << chunk
                transcript_write(log_io, chunk)
                stdout_line_buffer = stream_stdout_lines(stdout_line_buffer, chunk, stdout_line_handler)
              else
                captured_stderr << chunk
                transcript_write(log_io, chunk)
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

      def run_interactive(env:, argv:, chdir:, member_name:, process_options:, stdout_line_handler:, log_io: nil, passthrough_output: true)
        if pty_available?
          return run_interactive_pty(
            env: env,
            argv: argv,
            chdir: chdir,
            member_name: member_name,
            process_options: process_options,
            stdout_line_handler: stdout_line_handler,
            log_io: log_io,
            passthrough_output: passthrough_output
          )
        end

        run_interactive_open3(
          env: env,
          argv: argv,
          chdir: chdir,
          member_name: member_name,
          process_options: process_options,
          stdout_line_handler: stdout_line_handler,
          log_io: log_io,
          passthrough_output: passthrough_output
        )
      end

      def run_interactive_pty(env:, argv:, chdir:, member_name:, process_options:, stdout_line_handler:, log_io: nil, passthrough_output: true)
        stdout = +""
        stderr = +""
        stdout_line_buffer = +""
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
                  transcript_write(log_io, chunk)
                  stdout_line_buffer = print_interactive_stdout(stdout_line_buffer, chunk, stdout_line_handler, passthrough_output: passthrough_output)
                  handle_interactive_prompt(input, chunk, member_name: member_name)
                else
                  chunk = $stdin.readpartial(1024)
                  input.write(chunk)
                end
              end
            end
          rescue Errno::EIO
            # PTY raises EIO when the child process exits after closing the slave.
          rescue Error => error
            stderr << "#{error.message}\n"
            transcript_write(log_io, "#{error.message}\n")
            terminate_process(pid)
          end
          flush_interactive_stdout(stdout_line_buffer, stdout_line_handler, passthrough_output: passthrough_output)
          _, status = Process.wait2(pid)
          status = failure_status if !stderr.empty? && status.success?
        end
        [stdout, stderr, status]
      end

      def run_interactive_open3(env:, argv:, chdir:, member_name:, process_options:, stdout_line_handler:, log_io: nil, passthrough_output: true)
        captured_stdout = +""
        captured_stderr = +""
        stdout_line_buffer = +""
        status = nil
        Open3.popen3(env, *argv, chdir: chdir, **process_options) do |input, output, error, wait_thread|
          readers = [output, error]
          readers << $stdin if $stdin.tty? && !otp_coordinator
          begin
            until readers.empty?
              ready = IO.select(readers)
              ready.first.each do |reader|
                if reader.equal?($stdin)
                  input.write($stdin.readpartial(1024))
                else
                  stdout_line_buffer = read_interactive_stream(
                    reader,
                    output,
                    input,
                    captured_stdout,
                    captured_stderr,
                    readers,
                    member_name: member_name,
                    stdout_line_buffer: stdout_line_buffer,
                    stdout_line_handler: stdout_line_handler,
                    log_io: log_io,
                    passthrough_output: passthrough_output
                  )
                end
              end
            end
          rescue Error => error
            captured_stderr << "#{error.message}\n"
            transcript_write(log_io, "#{error.message}\n")
            terminate_process(wait_thread.pid)
            status = failure_status
          else
            status = wait_thread.value
          end
          flush_interactive_stdout(stdout_line_buffer, stdout_line_handler, passthrough_output: passthrough_output)
        end
        [captured_stdout, captured_stderr, status]
      end

      def read_interactive_stream(
        reader,
        output,
        input,
        captured_stdout,
        captured_stderr,
        readers,
        member_name:,
        stdout_line_buffer:,
        stdout_line_handler:,
        log_io: nil,
        passthrough_output: true
      )
        chunk = reader.readpartial(1024)
        if reader.equal?(output)
          captured_stdout << chunk
          transcript_write(log_io, chunk)
          stdout_line_buffer = print_interactive_stdout(stdout_line_buffer, chunk, stdout_line_handler, passthrough_output: passthrough_output)
        else
          captured_stderr << chunk
          transcript_write(log_io, chunk)
          $stderr.print(chunk) if passthrough_output
        end
        handle_interactive_prompt(input, chunk, member_name: member_name)
        stdout_line_buffer
      rescue EOFError
        readers.delete(reader)
        stdout_line_buffer
      end

      def with_transcript(log_path, argv:, chdir:)
        return yield(nil) if log_path.to_s.empty?

        FileUtils.mkdir_p(File.dirname(log_path))
        File.open(log_path, "wb") do |log_io|
          log_io.sync = true
          log_io.puts("$ #{argv.join(" ")}")
          log_io.puts("workdir: #{chdir}")
          log_io.puts
          yield(log_io)
        end
      end

      def transcript_write(log_io, chunk)
        return if log_io.nil? || chunk.to_s.empty?

        log_io.write(chunk)
      end

      def print_interactive_stdout(buffer, chunk, stdout_line_handler, passthrough_output: true)
        return print_interactive_chunk(chunk, passthrough_output: passthrough_output) unless stdout_line_handler

        pending = buffer + chunk
        lines = pending.lines
        remainder = pending.end_with?("\n") ? +"" : lines.pop.to_s
        lines.each { |line| print_interactive_line(line, stdout_line_handler, passthrough_output: passthrough_output) }
        return +"" if remainder.empty?
        unless possible_event_line?(remainder)
          $stdout.print(remainder) if passthrough_output
          return +""
        end

        remainder
      end

      def flush_interactive_stdout(buffer, stdout_line_handler, passthrough_output: true)
        return if buffer.empty?

        print_interactive_line(buffer, stdout_line_handler, passthrough_output: passthrough_output)
      end

      def print_interactive_chunk(chunk, passthrough_output: true)
        $stdout.print(chunk) if passthrough_output
        +""
      end

      def print_interactive_line(line, stdout_line_handler, passthrough_output: true)
        consumed = possible_event_line?(line) && stdout_line_handler.call(line.chomp)
        $stdout.print(line) if !consumed && passthrough_output
      end

      def possible_event_line?(line)
        line.to_s.lstrip.start_with?("{")
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

      def failure_status
        FailureStatus.new(1)
      end

      def terminate_process(pid)
        Process.kill("TERM", pid)
      rescue Errno::ESRCH, Errno::EPERM
        nil
      end

      def command_argv(member:, command:, env: {})
        argv = normalize_command(command)
        return argv unless mise_configured?(member)

        command_env = nonsensitive_env(env)
        unset_env, set_env = command_env.partition { |_key, value| value.nil? }
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
        # Bundler's unbundled environment intentionally omits activation
        # variables, but it may also omit PATH. When `unsetenv_others` is used
        # for mise-managed members, dropping PATH makes nested commands such
        # as `bundle` unresolvable inside kettle-jem.
        base_env["PATH"] = if base_env.key?("PATH")
          executable_path(base_env["PATH"])
        else
          ENV["PATH"]
        end
        return base_env.merge(env) unless mise_configured?(member)

        base_env.merge(sensitive_env(env))
      end

      def nonsensitive_env(env)
        env.reject { |key, _value| sensitive_env_key?(key) }
      end

      def sensitive_env(env)
        env.select { |key, value| sensitive_env_key?(key) && !value.nil? }
      end

      def sensitive_env_key?(key)
        SENSITIVE_ENV_KEYS.include?(key.to_s)
      end

      def executable_path(path)
        paths = [Gem.bindir, File.dirname(RbConfig.ruby), path, ENV["PATH"]]
        paths.compact.map(&:to_s).flat_map { |value| value.split(File::PATH_SEPARATOR) }.reject(&:empty?).uniq.join(File::PATH_SEPARATOR)
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
