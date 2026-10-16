# frozen_string_literal: true

# Shared context to no-op release secrets provider construction per-example.
# - Included globally from spec_helper.
# - Kettle::Family::Secrets::Provider aliases kettle-dev's deliberate no-op
#   base provider, so returning it from Factory.build guarantees nothing in a
#   spec run can reach a real secrets provider (no 1Password authorization
#   prompts, no broker network calls).
# - Skips mocking when example metadata includes :real_release_secrets.
RSpec.shared_context "with mocked release secrets" do
  before do |example|
    # Allow opting out for specs that need the real implementation
    next if example.metadata[:real_release_secrets]

    allow(Kettle::Family::Secrets::Factory).to receive(:build) do |*_args, **_kwargs|
      Kettle::Family::Secrets::Provider.new
    end
  end
end
