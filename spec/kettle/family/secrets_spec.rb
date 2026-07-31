# frozen_string_literal: true

RSpec.describe Kettle::Family::Secrets do
  it "builds an interactive provider when no release secrets are configured" do
    config = instance_double(Kettle::Family::Config, release_secrets: {})

    provider = described_class::Factory.build(config: config)

    expect(provider.gem_signing_passphrase).to be_nil
    expect(provider.rubygems_otp).to be_nil
  end

  it "builds an interactive provider when explicitly overridden" do
    config = instance_double(
      Kettle::Family::Config,
      release_secrets: {
        "provider" => "1password",
        "item" => "Rubygems"
      }
    )

    provider = described_class::Factory.build(config: config, override_provider: "interactive")

    expect(provider).to be_a(described_class::Provider)
    expect(provider).not_to be_a(described_class::OnePassword)
  end

  it "recognizes supported 1Password provider names" do
    expect(described_class::OnePassword.configured?("1password")).to be(true)
    expect(described_class::OnePassword.configured?("onepassword")).to be(true)
    expect(described_class::OnePassword.configured?("op")).to be(true)
    expect(described_class::OnePassword.configured?("vault")).to be(false)
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

  it "authorizes 1Password by loading the signing passphrase early" do
    provider = described_class::OnePassword.new(
      "item" => "Rubygems",
      "gem_signing_passphrase_field" => "GEM-SIGN-PASSPHRASE"
    )
    allow(Open3).to receive(:capture3)
      .with("op", "item", "get", "Rubygems", "--fields", "label=GEM-SIGN-PASSPHRASE", "--reveal")
      .and_return(["secret\n", "", status(success: true)])

    expect(provider.authorize!).to eq("secret")
  end

  it "does not print a nested release notifier alert during family preflight authorization" do
    provider = described_class::OnePassword.new(
      "item" => "Rubygems",
      "gem_signing_passphrase_field" => "GEM-SIGN-PASSPHRASE"
    )
    stub_env("KETTLE_RELEASE_SECRET_BELL" => "false")
    allow(Open3).to receive(:capture3)
      .with("op", "item", "get", "Rubygems", "--fields", "label=GEM-SIGN-PASSPHRASE", "--reveal")
      .and_return(["secret\n", "", status(success: true)])

    expect { provider.authorize! }.not_to output.to_stderr
  end

  it "keeps notifier alerts for prompt-time OTP lookups" do
    provider = described_class::OnePassword.new(
      "item" => "Rubygems",
      "rubygems_otp_field" => "one-time password"
    )
    allow(Kettle::Dev::ReleaseNotifier).to receive(:alert)
    allow(Open3).to receive(:capture3)
      .with("op", "item", "get", "Rubygems", "--otp")
      .and_return(["123456\n", "", status(success: true)])

    expect(provider.rubygems_otp).to eq("123456")
    expect(Kettle::Dev::ReleaseNotifier).to have_received(:alert)
      .with("1Password RubyGems OTP lookup starting; watch for authorization prompt.")
  end

  it "merges kettle-release secret environment defaults with family config" do
    config = instance_double(
      Kettle::Family::Config,
      release_secrets: {
        "provider" => "op",
        "item" => "Rubygems"
      }
    )
    stub_env(
      "KETTLE_RELEASE_1PASSWORD_ACCOUNT" => "work",
      "KETTLE_RELEASE_1PASSWORD_GEM_SIGNING_PASSPHRASE_FIELD" => "GEM-SIGN-PASSPHRASE"
    )
    allow(Open3).to receive(:capture3)
      .with("op", "item", "get", "Rubygems", "--fields", "label=GEM-SIGN-PASSPHRASE", "--reveal", "--account", "work")
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

  it "supports explicit 1Password OTP references" do
    provider = described_class::OnePassword.new(
      "rubygems_otp_reference" => "op://Private/Rubygems/one-time password"
    )
    allow(Open3).to receive(:capture3)
      .with("op", "read", "op://Private/Rubygems/one-time password")
      .and_return(["654321\n", "", status(success: true)])

    expect(provider.rubygems_otp).to eq("654321")
  end

  it "raises an error for unsupported providers" do
    config = instance_double(Kettle::Family::Config, release_secrets: {"provider" => "vault"})

    expect { described_class::Factory.build(config: config) }
      .to raise_error(Kettle::Family::Error, /unsupported release secrets provider "vault"/)
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

  it "raises a family error when OTP lookup fails" do
    provider = described_class::OnePassword.new("item" => "Rubygems")
    allow(Open3).to receive(:capture3)
      .and_return(["", "not signed in\n", status(success: false, exitstatus: 1)])

    expect { provider.rubygems_otp }
      .to raise_error(Kettle::Family::Error, /1Password RubyGems OTP lookup failed: not signed in/)
  end

  def status(success:, exitstatus: success ? 0 : 1)
    instance_double(Process::Status, success?: success, exitstatus: exitstatus)
  end
end
