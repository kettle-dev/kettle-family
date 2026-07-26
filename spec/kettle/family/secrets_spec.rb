# frozen_string_literal: true

RSpec.describe Kettle::Family::Secrets do
  it "builds an interactive provider when no release secrets are configured" do
    config = instance_double(Kettle::Family::Config, release_secrets: {})

    provider = described_class::Factory.build(config: config)

    expect(provider.gem_signing_passphrase).to be_nil
    expect(provider.rubygems_otp).to be_nil
  end

  it "builds a 1Password provider from config" do
    config = instance_double(
      Kettle::Family::Config,
      release_secrets: {
        "provider" => "1password",
        "item" => "Rubygems",
        "gem_signing_passphrase_field" => "GEM-SIGN-PASSPHRASE"
      }
    )
    allow(Open3).to receive(:capture3)
      .with("op", "item", "get", "Rubygems", "--fields", "label=GEM-SIGN-PASSPHRASE", "--reveal")
      .and_return(["secret\n", "", status(success: true)])

    provider = described_class::Factory.build(config: config)

    expect(provider.gem_signing_passphrase).to eq("secret")
  end

  it "fetches RubyGems OTP values close to prompt time" do
    provider = described_class::OnePassword.new(
      "item" => "Rubygems",
      "rubygems_otp_field" => "one-time password"
    )
    allow(Open3).to receive(:capture3)
      .with("op", "item", "get", "Rubygems", "--otp")
      .and_return(["123456\n", "", status(success: true)])

    expect(provider.rubygems_otp).to eq("123456")
  end

  it "supports explicit 1Password secret references" do
    provider = described_class::OnePassword.new(
      "account" => "work",
      "gem_signing_passphrase_reference" => "op://Private/Rubygems/GEM-SIGN-PASSPHRASE"
    )
    allow(Open3).to receive(:capture3)
      .with("op", "read", "op://Private/Rubygems/GEM-SIGN-PASSPHRASE", "--account", "work")
      .and_return(["secret\n", "", status(success: true)])

    expect(provider.gem_signing_passphrase).to eq("secret")
  end

  it "raises a redacted error when 1Password lookup fails" do
    provider = described_class::OnePassword.new(
      "item" => "Rubygems",
      "gem_signing_passphrase_field" => "GEM-SIGN-PASSPHRASE"
    )
    allow(Open3).to receive(:capture3)
      .and_return(["", "item not found\n", status(success: false, exitstatus: 1)])

    expect { provider.gem_signing_passphrase }
      .to raise_error(Kettle::Family::Error, /1Password gem signing passphrase field lookup failed: item not found/)
  end

  def status(success:, exitstatus: success ? 0 : 1)
    instance_double(Process::Status, success?: success, exitstatus: exitstatus)
  end
end
