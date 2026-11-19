# frozen_string_literal: true

# RebaseCheck syncs every member checkout against its upstream (git fetch +
# pull --rebase per member) — ambient state and network access specs must
# never touch, exactly like the BundlerVersionCheck guard. Stub the check's
# seam to no results (the all-synced path) globally so gating and workflow
# wiring stay hermetic; specs exercising the check itself or its workflow
# wiring opt out with :real_rebase_check and stub Rebase / the seam
# explicitly.
RSpec.shared_context "with stubbed rebase check" do
  before do |example|
    next if example.metadata[:real_rebase_check]

    allow(Kettle::Family::RebaseCheck).to receive(:call).and_return([])
  end
end
