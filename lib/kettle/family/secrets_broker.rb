# frozen_string_literal: true

require "fileutils"
require "json"
require "rbconfig"
require "securerandom"
require "socket"
require "tmpdir"

module Kettle
  module Family
    module Secrets
      # Serves release secret requests from member kettle-release processes.
      # The family owns the configured provider and serializes all requests so
      # one release session is shared across sequential and parallel waves.
      class Broker
        OPERATIONS = %w[gem_signing_passphrase rubygems_otp].freeze
        UNIX_SOCKET_PATH_MAX = RbConfig::CONFIG["host_os"].include?("darwin") ? 103 : 107

        attr_reader :path

        def initialize(provider:, root:, prompter: nil)
          @provider = provider
          @prompter = prompter
          directory = File.join(root, "tmp", "kettle-family")
          basename = "secrets-#{SecureRandom.hex(8)}.sock"
          @path = File.join(directory, basename)

          if @path.bytesize > UNIX_SOCKET_PATH_MAX
            directory = File.join(root, "tmp", "kf")
            @path = File.join(directory, "s-#{SecureRandom.hex(8)}")
          end

          if @path.bytesize > UNIX_SOCKET_PATH_MAX
            @socket_directory = Dir.mktmpdir("kf-", Dir.tmpdir)
            directory = @socket_directory
            @path = File.join(directory, "s-#{SecureRandom.hex(8)}")
          end

          if @path.bytesize > UNIX_SOCKET_PATH_MAX
            FileUtils.rm_rf(@socket_directory)
            @socket_directory = nil
            raise Error,
              "release secrets broker socket path is too long (#{@path.bytesize} bytes; Unix sockets allow #{UNIX_SOCKET_PATH_MAX})"
          end

          FileUtils.mkdir_p(directory, mode: 0o700)
          @mutex = Mutex.new
          @closed = false
          @cached = {}
          @authorization_failure = nil
        end

        def start
          @server = UNIXServer.new(@path)
          File.chmod(0o600, @path)
          @thread = Thread.new { serve } # rubocop:disable ThreadSafety/NewThread -- Broker owns one listener for the family release session.
          self
        rescue
          close
          raise
        end

        def close
          @closed = true
          @server&.close
          @thread&.join(1)
        ensure
          @thread&.kill if @thread&.alive?
          FileUtils.rm_f(@path)
          FileUtils.rm_rf(@socket_directory) if @socket_directory
        end

        private

        attr_reader :provider

        def serve
          loop do
            break if @closed

            client = @server.accept
            Thread.new(client) { |connection| handle(connection) } # rubocop:disable ThreadSafety/NewThread -- Each socket request is isolated from the listener.
          end
        rescue IOError, Errno::EBADF
          return if @closed

          raise
        end

        # Requests are serialized. Each failed approval prompt can take about a
        # minute to time out, so without this every queued member would raise
        # its own prompt in turn and fail one by one. A request that was already
        # waiting when approval failed fails immediately with the same message;
        # requests arriving afterwards may prompt again (the user may be back).
        # The signing passphrase is static, so it is cached after one lookup.
        # The OTP is a short-lived TOTP and is always fetched fresh.
        def resolve(operation, requested_at:)
          @mutex.synchronize do
            return @cached.fetch(operation) if @cached.key?(operation)

            failure = @authorization_failure
            raise Error, failure.fetch(:message) if failure && requested_at <= failure.fetch(:at)

            value = lookup(operation)
            @cached[operation] = value if operation == "gem_signing_passphrase"
            value
          end
        end

        # Adapter first; the user is asked only where the adapter cannot help:
        # it does not support the operation, returned nothing, or access was not
        # approved. Without a terminal to ask on, those cases keep their
        # original behavior (blank value, or the adapter's error).
        def lookup(operation)
          unless Secrets.supports?(provider, operation)
            return prompt_user(operation, "this secrets provider does not support #{operation.tr("_", " ")}") ||
                +""
          end

          provider.public_send(operation)
        rescue AuthorizationError => error
          message = "#{error.message} (approve the access prompt, then resume the release)"
          typed = prompt_user(operation, error.message)
          return typed if typed

          @authorization_failure = {at: Process.clock_gettime(Process::CLOCK_MONOTONIC), message: message}
          raise Error, message
        end

        def prompt_user(operation, reason)
          return nil unless @prompter && !Secrets.interactive?(provider)

          value = @prompter.ask(operation: operation, reason: reason)
          value.to_s.empty? ? nil : value
        end

        def handle(connection)
          request = JSON.parse(connection.gets.to_s)
          operation = request.fetch("operation")
          raise Error, "unsupported release secrets broker operation #{operation.inspect}" unless OPERATIONS.include?(operation)

          value = resolve(operation, requested_at: Process.clock_gettime(Process::CLOCK_MONOTONIC))
          connection.write(JSON.generate("ok" => true, "value" => value.to_s))
          connection.write("\n")
        rescue => error
          connection.write(JSON.generate("ok" => false, "error" => error.message))
          connection.write("\n")
        ensure
          connection&.close
        end
      end
    end
  end
end
