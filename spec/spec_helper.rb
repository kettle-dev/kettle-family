# frozen_string_literal: true

# Config for development dependencies of this library
# i.e., not configured by this library
#
# SimpleCov & related config (must run BEFORE any other requires)
# NOTE: Gemfiles for non-coverage appraisals may not have kettle-soup-cover.
#       The rescue LoadError handles that scenario.
begin
  require "kettle-soup-cover"
  if Kettle::Soup::Cover::DO_COV
    require "simplecov"
    require "kettle/soup/cover/config"
    SimpleCov.start
  end
rescue LoadError => error
  # check the error message and re-raise when unexpected
  raise error unless error.message.include?("kettle")
end

# External RSpec & related config
require "kettle/test/rspec"
# `kettle/test/rspec` installs harness helpers documented in spec/README.md.

require "kettle/family"

SENSITIVE_ENV_KEYS = %w[
  BUNDLE_GITHUB__COM
  GEM_HOST_API_KEY
  GH_TOKEN
  GITHUB_API_TOKEN
  GITHUB_OAUTH_TOKEN
  GITHUB_TOKEN
  GITLAB_API_PRIVATE_TOKEN
  GITLAB_PRIVATE_TOKEN
  GITLAB_TOKEN
  KETTLE_RELEASE_1PASSWORD_ACCOUNT
  KETTLE_RELEASE_1PASSWORD_CLI
  KETTLE_RELEASE_1PASSWORD_GEM_SIGNING_PASSPHRASE_FIELD
  KETTLE_RELEASE_1PASSWORD_GEM_SIGNING_PASSPHRASE_REFERENCE
  KETTLE_RELEASE_1PASSWORD_ITEM
  KETTLE_RELEASE_1PASSWORD_RUBYGEMS_OTP_FIELD
  KETTLE_RELEASE_1PASSWORD_RUBYGEMS_OTP_REFERENCE
  KETTLE_RELEASE_GEM_SIGNING_PASSPHRASE
  KETTLE_RELEASE_GEM_SIGNING_PASSPHRASE_SOURCE
  KETTLE_RELEASE_SECRETS_PROVIDER
  OP_CONNECT_TOKEN
  RUBYGEMS_API_KEY
].freeze

RSpec.configure do |config|
  config.before do
    hide_env(*SENSITIVE_ENV_KEYS)
    stub_env_hash_accessors
  end

  config.before(:each, :prism) do
    require "prism"
  rescue LoadError
    skip "Prism is unavailable on this Ruby engine"
  end

  # Enable flags like --only-failures and --next-failure
  config.example_status_persistence_file_path = ".rspec_status"

  # Disable RSpec exposing methods globally on `Module` and `main`
  config.disable_monkey_patching!

  config.expect_with :rspec do |c|
    c.syntax = :expect
  end
end
