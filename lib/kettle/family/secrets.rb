# frozen_string_literal: true

require "io/console"
require "json"
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

      # Shared engine for adapters that shell out to a vault CLI. A subclass says
      # *what* to run (argv_for), how its tool words "access not approved"
      # (error_class_for) and how to name itself in messages (label); this class
      # does the running, the error reporting and the supports?/authorize! plumbing.
      # Every built-in (1Password, Bitwarden, rbw, generic command) goes through
      # it, so each one exercises the same config and error handling.
      class CliAdapter < Provider
        def initialize(config)
          super()
          @config = config || {}
        end

        def supports?(operation)
          !argv_for(operation.to_sym).nil?
        end

        # Eager preflight: loading the signing passphrase proves access (and is
        # what the workflow stores for signing). Nil when it is unsupported.
        def authorize!
          supports?(:gem_signing_passphrase) ? gem_signing_passphrase : nil
        end

        # Each call runs the CLI; there is no session to keep alive.
        def keepalive_required?
          false
        end

        def keepalive!(elapsed: nil)
          true
        end

        def gem_signing_passphrase
          fetch(:gem_signing_passphrase)
        end

        def rubygems_otp
          fetch(:rubygems_otp)
        end

        private

        attr_reader :config

        # Array of argv, or nil when this adapter cannot supply the operation.
        def argv_for(_operation)
          nil
        end

        def purpose_for(operation)
          operation.to_s.tr("_", " ")
        end

        def label
          self.class.name.to_s.split("::").last
        end

        # Subclasses map their tool's "locked / not signed in / prompt dismissed"
        # wording to AuthorizationError so the family can fall back to asking.
        def error_class_for(_details)
          Error
        end

        def postprocess(_operation, stdout)
          stdout
        end

        def fetch(operation)
          argv = argv_for(operation)
          return nil if argv.nil?

          stdout, stderr, status = Open3.capture3(*argv)
          value = postprocess(operation, stdout.to_s.strip).to_s.strip
          return value if status.success? && !value.empty?

          details = stderr.to_s.strip
          details = (status.success? ? "returned no value" : "#{argv.first} exited #{status.exitstatus}") if details.empty?
          raise error_class_for(details), "#{label} #{purpose_for(operation)} lookup failed: #{details}"
        rescue Errno::ENOENT
          raise Error, "#{label} CLI executable `#{argv&.first}` was not found"
        end

        def setting(key)
          config.fetch(key, "").to_s.strip
        end

        def required_setting(key)
          value = setting(key)
          raise Error, "#{label} release secrets require release.secrets.#{key}" if value.empty?

          value
        end

        def account_args
          account = setting("account")
          account.empty? ? [] : ["--account", account]
        end
      end

      # Generic adapter: one configured command per secret, no shell. Works with
      # any CLI that prints the secret on stdout (pass, a script, ...). An
      # operation without a configured command is unsupported, and the family
      # prompts the user for it instead.
      #
      #   release:
      #     secrets:
      #       provider: command
      #       gem_signing_passphrase_command: pass show rubygems/signing
      #       rubygems_otp_command: pass otp rubygems
      class Command < CliAdapter
        NAMES = %w[command cli].freeze

        def self.configured?(name)
          NAMES.include?(name.to_s.downcase)
        end

        private

        def argv_for(operation)
          command = setting("#{operation}_command")
          command.empty? ? nil : Shellwords.split(command)
        end

        def label
          "Command"
        end
      end

      # 1Password CLI (`op`). Approval failures (dismissed prompt, locked or
      # unreachable app) are recognised so the family can fall back to asking.
      class OnePassword < CliAdapter
        PROVIDER_NAMES = %w[1password onepassword op].freeze
        DEFAULTS = {
          "item" => "Rubygems",
          "gem_signing_passphrase_field" => "GEM-SIGN-PASSPHRASE",
          "rubygems_otp_field" => "one-time password"
        }.freeze
        AUTHORIZATION_FAILURE = /authoriz|dismissed|desktop app|connection reset|not signed in|session expired/i

        def self.configured?(name)
          PROVIDER_NAMES.include?(name.to_s.downcase)
        end

        def initialize(config)
          super(DEFAULTS.merge(config || {}))
        end

        private

        def label
          "1Password"
        end

        def cli
          setting("cli").empty? ? "op" : setting("cli")
        end

        def argv_for(operation)
          case operation
          when :gem_signing_passphrase
            reference = setting("gem_signing_passphrase_reference")
            return [cli, "read", reference, *account_args] unless reference.empty?

            [cli, "item", "get", required_setting("item"), "--fields",
              "label=#{required_setting("gem_signing_passphrase_field")}", "--reveal", *account_args]
          when :rubygems_otp
            reference = setting("rubygems_otp_reference")
            return [cli, "read", reference, *account_args] unless reference.empty?

            [cli, "item", "get", required_setting("item"), "--otp", *account_args]
          end
        end

        def purpose_for(operation)
          if operation == :gem_signing_passphrase
            setting("gem_signing_passphrase_reference").empty? ? "gem signing passphrase field" : "secret reference"
          else
            setting("rubygems_otp_reference").empty? ? "RubyGems OTP" : "secret reference"
          end
        end

        def error_class_for(details)
          details.match?(AUTHORIZATION_FAILURE) ? AuthorizationError : Error
        end
      end

      # Bitwarden-compatible CLIs (Bitwarden `bw`, Vaultwarden via `bw`).
      # Unlock first and export the session: `export BW_SESSION=$(bw unlock --raw)`.
      #
      #   release:
      #     secrets:
      #       provider: bitwarden
      #       item: Rubygems                              # item holding the TOTP
      #       gem_signing_passphrase_field: GEM-SIGN-PASSPHRASE  # custom field on that item
      #       # or: gem_signing_passphrase_item: gem-signing  (its password)
      #       # cli: bw
      class Bitwarden < CliAdapter
        NAMES = %w[bitwarden bw vaultwarden].freeze
        DEFAULTS = {
          "item" => "Rubygems",
          "gem_signing_passphrase_field" => "GEM-SIGN-PASSPHRASE"
        }.freeze
        LOCKED = /locked|not logged in|session|unauthenticated|BW_SESSION/i

        def self.configured?(name)
          NAMES.include?(name.to_s.downcase)
        end

        def initialize(config)
          super(DEFAULTS.merge(config || {}))
        end

        private

        def label
          "Bitwarden"
        end

        def cli
          setting("cli").empty? ? "bw" : setting("cli")
        end

        def argv_for(operation)
          item = setting("item")
          case operation
          when :rubygems_otp
            [cli, "get", "totp", item] unless item.empty?
          when :gem_signing_passphrase
            password_item = setting("gem_signing_passphrase_item")
            return [cli, "get", "password", password_item] unless password_item.empty?

            [cli, "get", "item", item] unless item.empty? || setting("gem_signing_passphrase_field").empty?
          end
        end

        def postprocess(operation, stdout)
          return stdout unless operation == :gem_signing_passphrase && setting("gem_signing_passphrase_item").empty?

          field = setting("gem_signing_passphrase_field")
          found = Array(JSON.parse(stdout)["fields"]).find { |entry| entry["name"] == field }
          found ? found["value"].to_s : ""
        rescue JSON::ParserError
          ""
        end

        def error_class_for(details)
          details.match?(LOCKED) ? AuthorizationError : Error
        end
      end

      # rbw (unofficial Bitwarden CLI with an agent).
      #
      #   provider: rbw
      #   item: Rubygems
      #   gem_signing_passphrase_field: GEM-SIGN-PASSPHRASE
      class Rbw < CliAdapter
        NAMES = %w[rbw].freeze
        DEFAULTS = {"item" => "Rubygems", "gem_signing_passphrase_field" => "GEM-SIGN-PASSPHRASE"}.freeze

        def self.configured?(name)
          NAMES.include?(name.to_s.downcase)
        end

        def initialize(config)
          super(DEFAULTS.merge(config || {}))
        end

        private

        def label
          "rbw"
        end

        def argv_for(operation)
          item = setting("item")
          return nil if item.empty?

          case operation
          when :rubygems_otp
            ["rbw", "code", item]
          when :gem_signing_passphrase
            field = setting("gem_signing_passphrase_field")
            ["rbw", "get", item, "--field", field] unless field.empty?
          end
        end

        def error_class_for(details)
          details.match?(/locked|not logged in|agent|pinentry/i) ? AuthorizationError : Error
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
      Registry.register(*Bitwarden::NAMES) { |config| Bitwarden.new(config) }
      Registry.register(*Rbw::NAMES) { |config| Rbw.new(config) }

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
