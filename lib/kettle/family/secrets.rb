# frozen_string_literal: true

require "io/console"
require "shellwords"

begin
  require "kettle/dev"
rescue LoadError
  require "open3"
end

module Kettle
  module Family
    # Reopened (same superclass as family.rb) because this file loads first and
    # defines error subclasses at load time.
    class Error < StandardError; end

    module Secrets
      # Adapter contract (see Registry): an adapter is any object that responds
      # to gem_signing_passphrase and rubygems_otp, returning a String, or nil
      # when it has no value (the family then falls back to prompting the
      # user). It may define supports?(operation) to declare gaps up front,
      # authorize! for an eager preflight check, and should raise
      # AuthorizationError when the user has not approved access (so queued
      # requests fail fast) and Error for any other failure.
      OPERATIONS = %i[gem_signing_passphrase rubygems_otp].freeze

      class AuthorizationError < Error; end

      class UnsupportedOperation < Error; end

      def self.supports?(provider, operation)
        return provider.supports?(operation.to_sym) if provider.respond_to?(:supports?)

        true
      end

      # The default Provider returns no secrets: every secret is prompted for.
      def self.interactive?(provider)
        provider.instance_of?(Provider)
      end

      if defined?(Kettle::Dev::ReleaseSecrets)
        Kettle::Dev.const_set(:Error, Class.new(StandardError)) unless Kettle::Dev.const_defined?(:Error, false)
        Provider = Kettle::Dev::ReleaseSecrets::Provider

        class OnePassword < Kettle::Dev::ReleaseSecrets::OnePassword
          def self.configured?(name)
            Kettle::Dev::ReleaseSecrets::OnePassword.configured?(name)
          end

          def authorize!
            with_release_secret_alert_suppressed { gem_signing_passphrase }
          rescue => error
            raise Secrets.classify_onepassword_error(error)
          end

          def gem_signing_passphrase
            super
          rescue => error
            raise Secrets.classify_onepassword_error(error)
          end

          def rubygems_otp
            with_release_secret_alert_suppressed { super }
          rescue => error
            raise Secrets.classify_onepassword_error(error)
          end

          private

          def with_release_secret_alert_suppressed
            previous = ENV.fetch("KETTLE_RELEASE_SECRET_ALERT", nil)
            ENV["KETTLE_RELEASE_SECRET_ALERT"] = "false"
            yield
          ensure
            previous.nil? ? ENV.delete("KETTLE_RELEASE_SECRET_ALERT") : ENV["KETTLE_RELEASE_SECRET_ALERT"] = previous
          end
        end
      else
        class Provider
          def authorize!
            nil
          end

          def gem_signing_passphrase
            nil
          end

          def rubygems_otp
            nil
          end
        end

        class OnePassword < Provider
          PROVIDER_NAMES = %w[1password onepassword op].freeze
          DEFAULTS = {
            "item" => "Rubygems",
            "gem_signing_passphrase_field" => "GEM-SIGN-PASSPHRASE",
            "rubygems_otp_field" => "one-time password"
          }.freeze

          def self.configured?(name)
            PROVIDER_NAMES.include?(name.to_s.downcase)
          end

          def initialize(config)
            @config = DEFAULTS.merge(config || {})
          end

          def gem_signing_passphrase
            reference = string_config("gem_signing_passphrase_reference")
            return read_reference(reference) unless reference.empty?

            item_field("gem_signing_passphrase_field")
          end

          def authorize!
            gem_signing_passphrase
          end

          def rubygems_otp
            reference = string_config("rubygems_otp_reference")
            return read_reference(reference) unless reference.empty?

            item = required_config("item")
            argv = ["op", "item", "get", item, "--otp"]
            account = string_config("account")
            argv.concat(["--account", account]) unless account.empty?
            run_op(argv, purpose: "RubyGems OTP")
          end

          private

          attr_reader :config

          def item_field(field_key)
            item = required_config("item")
            field = required_config(field_key)
            argv = ["op", "item", "get", item, "--fields", "label=#{field}", "--reveal"]
            account = string_config("account")
            argv.concat(["--account", account]) unless account.empty?
            run_op(argv, purpose: field_key.tr("_", " "))
          end

          def read_reference(reference)
            argv = ["op", "read", reference]
            account = string_config("account")
            argv.concat(["--account", account]) unless account.empty?
            run_op(argv, purpose: "secret reference")
          end

          def run_op(argv, purpose:)
            stdout, stderr, status = Open3.capture3(*argv)
            return stdout.to_s.strip if status.success? && !stdout.to_s.strip.empty?

            details = stderr.to_s.strip
            details = "op exited #{status.exitstatus}" if details.empty?
            raise Secrets.classify_onepassword_error(Error.new("1Password #{purpose} lookup failed: #{details}"))
          rescue Errno::ENOENT
            raise Error, "1Password CLI executable `op` was not found"
          end

          def required_config(key)
            value = string_config(key)
            raise Error, "1Password release secrets require release.secrets.#{key}" if value.empty?

            value
          end

          def string_config(key)
            config.fetch(key, "").to_s
          end
        end
      end

      # Asks the user at the family terminal, without echo. Used by the broker
      # when an adapter cannot supply a secret. Only constructed when stdin is
      # a terminal, so unattended runs are never left waiting on input.
      class TerminalPrompter
        LABELS = {
          "gem_signing_passphrase" => "Gem signing passphrase",
          "rubygems_otp" => "RubyGems MFA code"
        }.freeze

        def initialize(input: $stdin, output: $stderr)
          @input = input
          @output = output
        end

        def self.for_terminal(input: $stdin, output: $stderr)
          new(input: input, output: output) if input.respond_to?(:tty?) && input.tty?
        end

        def ask(operation:, reason: nil)
          @output.puts("#{reason}; enter it manually.") if reason
          @output.print("#{LABELS.fetch(operation, operation)}: ")
          @output.flush
          value = if @input.respond_to?(:noecho)
            @input.noecho(&:gets)
          else
            @input.gets
          end
          @output.puts
          value.to_s.chomp
        end
      end

      # 1Password wording that means "access not approved" (dismissed or timed
      # out prompt, locked or unreachable app) rather than a bad lookup. Kept
      # here, with the adapter, so nothing else depends on op's messages.
      ONEPASSWORD_AUTHORIZATION_FAILURE = /authoriz|dismissed|desktop app|connection reset|not signed in|session expired/i

      def self.classify_onepassword_error(error)
        return error if error.is_a?(AuthorizationError)

        klass = error.message.match?(ONEPASSWORD_AUTHORIZATION_FAILURE) ? AuthorizationError : Error
        klass.new(error.message)
      end

      # Generic adapter: runs one configured command per secret, with no shell.
      # Works with any CLI that prints the secret on stdout, e.g. Bitwarden
      # (`bw get password <item>`, `bw get totp <item>`), rbw (`rbw code <item>`),
      # pass, or a script. An operation without a configured command is simply
      # unsupported, and the family prompts the user for it instead.
      #
      #   release:
      #     secrets:
      #       provider: command
      #       gem_signing_passphrase_command: bw get password rubygems-signing
      #       rubygems_otp_command: bw get totp rubygems
      class Command < Provider
        NAMES = %w[command cli].freeze

        def self.configured?(name)
          NAMES.include?(name.to_s.downcase)
        end

        def initialize(config)
          super()
          @config = config || {}
        end

        def supports?(operation)
          !command_for(operation).empty?
        end

        def authorize!
          nil
        end

        # No session to keep alive: every call runs the configured command.
        def keepalive_required?
          false
        end

        def keepalive!(elapsed: nil)
          true
        end

        def gem_signing_passphrase
          run(:gem_signing_passphrase)
        end

        def rubygems_otp
          run(:rubygems_otp)
        end

        private

        def command_for(operation)
          @config.fetch("#{operation}_command", "").to_s.strip
        end

        def run(operation)
          command = command_for(operation)
          return nil if command.empty?

          stdout, stderr, status = Open3.capture3(*Shellwords.split(command))
          value = stdout.to_s.strip
          return value if status.success? && !value.empty?

          details = stderr.to_s.strip
          details = "exited #{status.exitstatus}" if details.empty?
          raise Error, "#{operation.to_s.tr("_", " ")} command failed: #{details}"
        rescue Errno::ENOENT
          raise Error, "#{operation.to_s.tr("_", " ")} command executable was not found: #{command.split.first}"
        end
      end

      # Adapter registry. Third parties (or future built-ins) register a
      # builder that receives the release.secrets config hash:
      #
      #   Kettle::Family::Secrets::Registry.register("bitwarden") { |config| MyAdapter.new(config) }
      module Registry
        @builders = {}

        class << self
          def register(*names, &builder)
            names.flatten.each { |name| @builders[name.to_s.downcase] = builder }
          end

          def builder_for(name)
            @builders[name.to_s.downcase]
          end

          def names
            @builders.keys.sort
          end
        end
      end

      Registry.register("1password", "onepassword", "op") do |config|
        if defined?(Kettle::Dev::ReleaseSecrets)
          OnePassword.new(Kettle::Dev::ReleaseSecrets::Factory.env_config.merge(config))
        else
          OnePassword.new(config)
        end
      end
      Registry.register(*Command::NAMES) { |config| Command.new(config) }

      class Factory
        def self.build(config:, override_provider: nil)
          secrets_config = config.release_secrets
          provider_name = override_provider.to_s.empty? ? secrets_config.fetch("provider", nil) : override_provider
          return Provider.new if provider_name.to_s.empty? || provider_name.to_s == "interactive"

          builder = Registry.builder_for(provider_name)
          unless builder
            raise Error, "unsupported release secrets provider #{provider_name.inspect} (available: interactive, #{Registry.names.join(", ")})"
          end

          builder.call(secrets_config)
        rescue => error
          if defined?(Kettle::Dev::Error) && error.is_a?(Kettle::Dev::Error)
            raise Error, error.message
          end

          raise
        end
      end
    end
  end
end
