# frozen_string_literal: true

RSpec.describe Kettle::Family::Secrets, :real_release_secrets do
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

  it "suppresses nested kettle-release notifier alerts for family-owned OTP lookups" do
    provider = described_class::OnePassword.new(
      "item" => "Rubygems",
      "rubygems_otp_field" => "one-time password"
    )
    allow(Open3).to receive(:capture3)
      .with("op", "item", "get", "Rubygems", "--otp")
      .and_return(["123456\n", "", status(success: true)])

    expect { expect(provider.rubygems_otp).to eq("123456") }.not_to output.to_stderr
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

  it "serializes member secret requests through the family broker" do
    provider = instance_double(Kettle::Family::Secrets::Provider, rubygems_otp: "123456")
    broker = described_class::Broker.new(provider: provider, root: Dir.mktmpdir("kettle-family-broker-spec"))
    broker.start

    socket = UNIXSocket.new(broker.path)
    socket.write(JSON.generate("operation" => "rubygems_otp"))
    socket.write("\n")
    response = JSON.parse(socket.gets)

    expect(response).to eq("ok" => true, "value" => "123456")
    expect(provider).to have_received(:rubygems_otp).once
  ensure
    socket&.close
    broker&.close
  end

  def broker_request(broker, operation)
    socket = UNIXSocket.new(broker.path)
    socket.write("#{JSON.generate("operation" => operation)}\n")
    JSON.parse(socket.gets)
  ensure
    socket&.close
  end

  it "fails requests that were already queued when approval failed, without re-prompting" do
    gate = Queue.new
    calls = 0
    provider = instance_double(Kettle::Family::Secrets::Provider)
    allow(provider).to receive(:rubygems_otp) do
      calls += 1
      gate.pop # simulate the prompt waiting for the user
      raise Kettle::Family::Secrets::AuthorizationError, "RubyGems OTP lookup failed: access prompt dismissed"
    end
    broker = described_class::Broker.new(provider: provider, root: Dir.mktmpdir("kettle-family-broker-spec")).start

    threads = Array.new(3) do
      Thread.new { broker_request(broker, "rubygems_otp") } # rubocop:disable ThreadSafety/NewThread -- concurrent clients are the point of this spec
    end
    sleep 0.3 # all three are connected; one is in the provider, two are queued
    gate << :dismissed
    responses = threads.map(&:value)

    expect(calls).to eq(1)
    expect(responses.map { |response| response["ok"] }).to eq([false, false, false])
    expect(responses.map { |response| response["error"] }).to all(include("approve the access prompt"))
  ensure
    broker&.close
  end

  it "prompts again for a request that arrives after an approval failure" do
    provider = instance_double(Kettle::Family::Secrets::Provider)
    allow(provider).to receive(:rubygems_otp).and_invoke(
      -> { raise Kettle::Family::Secrets::AuthorizationError, "access prompt dismissed" },
      -> { "654321" }
    )
    broker = described_class::Broker.new(provider: provider, root: Dir.mktmpdir("kettle-family-broker-spec")).start

    expect(broker_request(broker, "rubygems_otp")["ok"]).to be(false)
    expect(broker_request(broker, "rubygems_otp")).to eq("ok" => true, "value" => "654321")
  ensure
    broker&.close
  end

  it "caches the static signing passphrase but never the OTP" do
    provider = instance_double(Kettle::Family::Secrets::Provider)
    allow(provider).to receive(:gem_signing_passphrase).and_return("pass")
    allow(provider).to receive(:rubygems_otp).and_return("111111", "222222")
    broker = described_class::Broker.new(provider: provider, root: Dir.mktmpdir("kettle-family-broker-spec")).start

    2.times { expect(broker_request(broker, "gem_signing_passphrase")["value"]).to eq("pass") }
    values = 2.times.map { broker_request(broker, "rubygems_otp")["value"] }

    expect(provider).to have_received(:gem_signing_passphrase).once
    expect(values).to eq(%w[111111 222222])
  ensure
    broker&.close
  end

  describe "adapter-centric behavior" do
    let(:root) { Dir.mktmpdir("kettle-family-broker-spec") }
    let(:prompter) { instance_double(Kettle::Family::Secrets::TerminalPrompter) }

    it "classifies 1Password approval failures but not other failures" do
      provider = described_class::OnePassword.new("item" => "Rubygems")
      status = instance_double(Process::Status, success?: false, exitstatus: 1)
      allow(Open3).to receive(:capture3).with("op", "item", "get", "Rubygems", "--otp")
        .and_return(["", "error initializing client: authorization prompt dismissed", status],
          ["", "item not found", status])

      expect { provider.rubygems_otp }.to raise_error(described_class::AuthorizationError)
      expect { provider.rubygems_otp }.to raise_error(Kettle::Family::Error) { |error| expect(error).not_to be_a(described_class::AuthorizationError) }
    end

    it "runs configured commands without a shell and treats a missing command as unsupported" do
      provider = described_class::Command.new("rubygems_otp_command" => "echo 424242")

      expect(provider.supports?(:rubygems_otp)).to be(true)
      expect(provider.supports?(:gem_signing_passphrase)).to be(false)
      expect(provider.rubygems_otp).to eq("424242")
      expect(provider.gem_signing_passphrase).to be_nil
      expect(provider.keepalive_required?).to be(false)
    end

    it "raises a plain error when a configured command fails" do
      provider = described_class::Command.new("rubygems_otp_command" => "false")

      expect { provider.rubygems_otp }.to raise_error(Kettle::Family::Error, /Command rubygems otp lookup failed/)
    end

    describe "Bitwarden and rbw presets" do
      def stub_capture(argv, stdout: "", stderr: "", success: true)
        status = instance_double(Process::Status, success?: success, exitstatus: success ? 0 : 1)
        allow(Open3).to receive(:capture3).with(*argv).and_return([stdout, stderr, status])
      end

      it "reads the OTP with bw get totp and the passphrase from a custom field" do
        provider = described_class::Bitwarden.new("item" => "Rubygems")
        stub_capture(%w[bw get totp Rubygems], stdout: "123456\n")
        stub_capture(%w[bw get item Rubygems], stdout: JSON.generate("fields" => [{"name" => "GEM-SIGN-PASSPHRASE", "value" => "s3cret"}]))

        expect(provider.rubygems_otp).to eq("123456")
        expect(provider.gem_signing_passphrase).to eq("s3cret")
      end

      it "reads the passphrase from another item's password when configured" do
        provider = described_class::Bitwarden.new("gem_signing_passphrase_item" => "gem-signing")
        stub_capture(%w[bw get password gem-signing], stdout: "pw\n")

        expect(provider.gem_signing_passphrase).to eq("pw")
      end

      it "reports a locked vault as an approval failure so the family can prompt" do
        provider = described_class::Bitwarden.new({})
        stub_capture(%w[bw get totp Rubygems], stderr: "Vault is locked.", success: false)

        expect { provider.rubygems_otp }.to raise_error(described_class::AuthorizationError, /locked/)
      end

      it "reports other failures as plain errors and a missing field clearly" do
        provider = described_class::Bitwarden.new({})
        stub_capture(%w[bw get totp Rubygems], stderr: "Not found.", success: false)
        stub_capture(%w[bw get item Rubygems], stdout: JSON.generate("fields" => []))

        expect { provider.rubygems_otp }.to raise_error(Kettle::Family::Error, /Not found/)
        expect { provider.gem_signing_passphrase }.to raise_error(Kettle::Family::Error, /gem signing passphrase lookup failed: returned no value/)
      end

      it "declares what it supports" do
        expect(described_class::Bitwarden.new("item" => "").supports?(:rubygems_otp)).to be(false)
        expect(described_class::Bitwarden.new({}).supports?(:gem_signing_passphrase)).to be(true)
      end

      it "builds rbw commands from item and field" do
        provider = described_class::Rbw.new("item" => "My Item")
        stub_capture(["rbw", "code", "My Item"], stdout: "654321\n")
        stub_capture(["rbw", "get", "My Item", "--field", "GEM-SIGN-PASSPHRASE"], stdout: "pp\n")

        expect(provider.rubygems_otp).to eq("654321")
        expect(provider.gem_signing_passphrase).to eq("pp")
      end

      it "is available through the registry under bitwarden, bw, vaultwarden and rbw" do
        %w[bitwarden bw vaultwarden rbw].each do |name|
          config = instance_double(Kettle::Family::Config, release_secrets: {"provider" => name})
          expect(described_class::Factory.build(config: config)).to be_a(described_class::CliAdapter)
        end
      end
    end

    it "resolves providers through the registry, including third-party adapters" do
      adapter = Class.new(Kettle::Family::Secrets::Provider)
      described_class::Registry.register("my-vault") { |_config| adapter.new }
      config = instance_double(Kettle::Family::Config, release_secrets: {"provider" => "my-vault"})

      expect(described_class::Factory.build(config: config)).to be_a(adapter)
      cli = instance_double(Kettle::Family::Config, release_secrets: {"provider" => "command", "rubygems_otp_command" => "echo 1"})
      expect(described_class::Factory.build(config: cli)).to be_a(described_class::Command)
      unknown = instance_double(Kettle::Family::Config, release_secrets: {"provider" => "nope"})
      expect { described_class::Factory.build(config: unknown) }.to raise_error(Kettle::Family::Error, /available: interactive, .*command/)
    end

    it "asks the user for an operation the adapter does not support, and caches the passphrase" do
      provider = described_class::Command.new("rubygems_otp_command" => "echo 424242")
      allow(prompter).to receive(:ask).and_return("typed-pass")
      broker = described_class::Broker.new(provider: provider, root: root, prompter: prompter).start

      2.times { expect(broker_request(broker, "gem_signing_passphrase")).to eq("ok" => true, "value" => "typed-pass") }
      expect(broker_request(broker, "rubygems_otp")).to eq("ok" => true, "value" => "424242")
      expect(prompter).to have_received(:ask).once.with(operation: "gem_signing_passphrase", reason: /does not support/)
    ensure
      broker&.close
    end

    it "falls back to asking the user when access was not approved" do
      provider = instance_double(Kettle::Family::Secrets::Provider)
      allow(provider).to receive(:rubygems_otp).and_raise(Kettle::Family::Secrets::AuthorizationError, "prompt dismissed")
      allow(prompter).to receive(:ask).and_return("999999")
      broker = described_class::Broker.new(provider: provider, root: root, prompter: prompter).start

      expect(broker_request(broker, "rubygems_otp")).to eq("ok" => true, "value" => "999999")
    ensure
      broker&.close
    end

    it "does not prompt for the explicit interactive provider (child keeps its own behavior)" do
      provider = Kettle::Family::Secrets::Provider.new
      allow(prompter).to receive(:ask)
      broker = described_class::Broker.new(provider: provider, root: root, prompter: prompter).start

      expect(broker_request(broker, "rubygems_otp")).to eq("ok" => true, "value" => "")
      expect(prompter).not_to have_received(:ask)
    ensure
      broker&.close
    end

    it "only builds a terminal prompter when stdin is a terminal" do
      expect(described_class::TerminalPrompter.for_terminal(input: StringIO.new)).to be_nil
    end
  end

  it "uses a compact socket path for deep release roots" do
    provider = instance_double(Kettle::Family::Secrets::Provider)

    Dir.mktmpdir("kettle-family-broker-spec") do |sandbox|
      root = File.join(sandbox, "a" * 80)
      broker = described_class::Broker.new(provider: provider, root: root)

      expect(broker.path.bytesize).to be <= described_class::Broker::UNIX_SOCKET_PATH_MAX
      expect(broker.path).to start_with(Dir.tmpdir)
      expect(File.basename(broker.path)).to start_with("s-")
    ensure
      broker&.close
    end
  end

  it "returns a structured error for unsupported broker operations" do
    provider = instance_double(Kettle::Family::Secrets::Provider)
    root = File.join(Dir.pwd, "tmp", "broker-unsupported")
    broker = described_class::Broker.new(provider: provider, root: root)
    broker.start

    socket = UNIXSocket.new(broker.path)
    socket.puts(JSON.generate("operation" => "delete_everything"))
    response = JSON.parse(socket.gets)

    expect(response.fetch("ok")).to be(false)
    expect(response.fetch("error")).to include("unsupported release secrets broker operation")
  ensure
    socket&.close
    broker&.close
    FileUtils.rm_rf(root) if root
  end

  it "returns a structured error when the secrets provider fails" do
    provider = instance_double(Kettle::Family::Secrets::Provider)
    allow(provider).to receive(:rubygems_otp).and_raise(Kettle::Family::Error, "provider unavailable")
    root = File.join(Dir.pwd, "tmp", "broker-provider")
    broker = described_class::Broker.new(provider: provider, root: root)
    broker.start

    socket = UNIXSocket.new(broker.path)
    socket.puts(JSON.generate("operation" => "rubygems_otp"))
    response = JSON.parse(socket.gets)

    expect(response).to eq("ok" => false, "error" => "provider unavailable")
  ensure
    socket&.close
    broker&.close
    FileUtils.rm_rf(root) if root
  end

  it "uses a private system temp directory when the repository root is too deep" do
    provider = instance_double(Kettle::Family::Secrets::Provider)
    root = File.join(File::SEPARATOR, "r" * described_class::Broker::UNIX_SOCKET_PATH_MAX)
    broker = described_class::Broker.new(provider: provider, root: root)

    expect(broker.path.bytesize).to be <= described_class::Broker::UNIX_SOCKET_PATH_MAX
    expect(broker.path).to start_with(Dir.tmpdir)
  ensure
    broker&.close
  end

  it "can close before the broker has started" do
    provider = instance_double(Kettle::Family::Secrets::Provider)

    Dir.mktmpdir("kettle-family-broker-spec") do |root|
      broker = described_class::Broker.new(provider: provider, root: root)

      expect { broker.close }.not_to raise_error
      expect(File.exist?(broker.path)).to be(false)
    end
  end

  def status(success:, exitstatus: success ? 0 : 1)
    instance_double(Process::Status, success?: success, exitstatus: exitstatus)
  end
end
