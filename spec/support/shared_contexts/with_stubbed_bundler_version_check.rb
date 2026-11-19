# frozen_string_literal: true

# BundlerVersionCheck reaches the registry (via Kettle::Dev::BundlerPinning)
# and the local gem home — ambient state specs must never read, exactly like
# the release-secrets guard. Stub the check's seam to a clean result
# globally so gating and check-surface wiring stay hermetic; specs exercising
# the check itself or its workflow wiring opt out with
# :real_bundler_version_check and stub BundlerPinning / the seam explicitly.
RSpec.shared_context "with stubbed bundler version check" do
  before do |example|
    next if example.metadata[:real_bundler_version_check]

    allow(Kettle::Family::BundlerVersionCheck).to receive(:call) do |config:, members:|
      Kettle::Family::CommandResult.new(
        member_name: config.family_name,
        phase: Kettle::Family::BundlerVersionCheck::PHASE,
        command: ["internal", Kettle::Family::BundlerVersionCheck::PHASE],
        workdir: config.root,
        status: 0,
        success: true,
        stdout: "",
        stderr: "",
        elapsed_seconds: 0.0,
        skipped: false,
        reason: nil
      )
    end
  end
end
