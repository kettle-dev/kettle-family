# frozen_string_literal: true

begin
  require "kettle/dev/release_secrets"
rescue LoadError
  require "open3"
end

module Kettle
  module Family
    module Secrets
      if defined?(Kettle::Dev::ReleaseSecrets)
        Kettle::Dev.const_set(:Error, Class.new(StandardError)) unless Kettle::Dev.const_defined?(:Error, false)
        Provider = Kettle::Dev::ReleaseSecrets::Provider

        class OnePassword < Kettle::Dev::ReleaseSecrets::OnePassword
          def self.configured?(name)
            Kettle::Dev::ReleaseSecrets::OnePassword.configured?(name)
          end

          def authorize!
            gem_signing_passphrase
          rescue => error
            raise Error, error.message
          end

          def gem_signing_passphrase
            super
          rescue => error
            raise Error, error.message
          end

          def rubygems_otp
            super
          rescue => error
            raise Error, error.message
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
            raise Error, "1Password #{purpose} lookup failed: #{details}"
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

      class Factory
        def self.build(config:, override_provider: nil)
          if defined?(Kettle::Dev::ReleaseSecrets)
            secrets_config = config.release_secrets
            provider_name = override_provider.to_s.empty? ? secrets_config.fetch("provider", nil) : override_provider
            return Provider.new if provider_name.to_s.empty? || provider_name.to_s == "interactive"
            return OnePassword.new(Kettle::Dev::ReleaseSecrets::Factory.env_config.merge(secrets_config)) if OnePassword.configured?(provider_name)

            raise Error, "unsupported release secrets provider #{provider_name.inspect}"
          end

          secrets_config = config.release_secrets
          provider_name = override_provider.to_s.empty? ? secrets_config.fetch("provider", nil) : override_provider
          return Provider.new if provider_name.to_s.empty? || provider_name.to_s == "interactive"
          return OnePassword.new(secrets_config) if OnePassword.configured?(provider_name)

          raise Error, "unsupported release secrets provider #{provider_name.inspect}"
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
