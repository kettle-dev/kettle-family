# frozen_string_literal: true

require "fileutils"
require "json"
require "securerandom"
require "socket"

module Kettle
  module Family
    module Secrets
      # Serves release secret requests from member kettle-release processes.
      # The family owns the configured provider and serializes all requests so
      # one release session is shared across sequential and parallel waves.
      class Broker
        OPERATIONS = %w[gem_signing_passphrase rubygems_otp].freeze
        UNIX_SOCKET_PATH_MAX = 108

        attr_reader :path

        def initialize(provider:, root:)
          @provider = provider
          directory = File.join(root, "tmp", "kettle-family")
          basename = "secrets-#{SecureRandom.hex(8)}.sock"
          @path = File.join(directory, basename)

          if @path.bytesize > UNIX_SOCKET_PATH_MAX
            directory = File.join(root, "tmp", "kf")
            @path = File.join(directory, "s-#{SecureRandom.hex(8)}")
          end

          if @path.bytesize > UNIX_SOCKET_PATH_MAX
            raise Error,
              "release secrets broker socket path is too long (#{@path.bytesize} bytes; Unix sockets allow #{UNIX_SOCKET_PATH_MAX})"
          end

          FileUtils.mkdir_p(directory, mode: 0o700)
          @mutex = Mutex.new
          @closed = false
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

        def handle(connection)
          request = JSON.parse(connection.gets.to_s)
          operation = request.fetch("operation")
          raise Error, "unsupported release secrets broker operation #{operation.inspect}" unless OPERATIONS.include?(operation)

          value = @mutex.synchronize { provider.public_send(operation) }
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
