# frozen_string_literal: true

RSpec.describe Kettle::Family do
  it "has a version number" do
    expect(Kettle::Family::VERSION).not_to be nil
  end

  it "exposes the generated namespace" do
    expect(described_class::Error).to be < StandardError
  end
end
