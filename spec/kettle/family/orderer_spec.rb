# frozen_string_literal: true

RSpec.describe Kettle::Family::Orderer do
  def member(name, dependencies: [])
    Kettle::Family::Member.new(:name => name, :root => name, :gemspec_path => "#{name}.gemspec", :version => "1.0.0", :dependencies => dependencies)
  end

  it "uses fixed order hints before remaining members" do
    ordered = described_class.new(
      :members => [member("alpha"), member("beta"), member("gamma")],
      :mode => "fixed",
      :hints => ["gamma", "alpha"]
    ).ordered

    expect(ordered.map(&:name)).to eq(["gamma", "alpha", "beta"])
  end

  it "rejects unknown fixed order hints" do
    orderer = described_class.new(:members => [member("alpha")], :mode => "fixed", :hints => ["missing"])

    expect { orderer.ordered }.to raise_error(Kettle::Family::Error, /unknown members: missing/)
  end

  it "rejects unknown order modes" do
    orderer = described_class.new(:members => [member("alpha")], :mode => "random")

    expect { orderer.ordered }.to raise_error(Kettle::Family::Error, /unknown order mode/)
  end

  it "reports dependency cycles" do
    orderer = described_class.new(:members => [member("alpha", :dependencies => ["beta"]), member("beta", :dependencies => ["alpha"])])

    expect { orderer.ordered }.to raise_error(Kettle::Family::Error, /dependency cycle detected/)
  end
end
