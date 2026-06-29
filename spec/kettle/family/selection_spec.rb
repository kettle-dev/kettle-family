# frozen_string_literal: true

RSpec.describe Kettle::Family::Selection do
  def member(name)
    Kettle::Family::Member.new(name: name, root: name, gemspec_path: "#{name}.gemspec", version: "1.0.0", dependencies: [])
  end

  it "selects only one member" do
    selected = described_class.new(members: [member("alpha"), member("beta")]).apply(only: "beta")

    expect(selected.map(&:name)).to eq(["beta"])
  end

  it "selects comma-separated members in family order" do
    selected = described_class.new(members: [member("alpha"), member("beta"), member("gamma")]).apply(only: "gamma, alpha")

    expect(selected.map(&:name)).to eq(%w[alpha gamma])
  end

  it "rejects unknown only selections" do
    selection = described_class.new(members: [member("alpha")])

    expect { selection.apply(only: "missing,beta") }.to raise_error(Kettle::Family::Error, /unknown member\(s\): missing, beta/)
  end

  it "rejects empty only selections" do
    selection = described_class.new(members: [member("alpha")])

    expect { selection.apply(only: ",") }.to raise_error(Kettle::Family::Error, /--only requires at least one member/)
  end

  it "rejects unknown start-at selections" do
    selection = described_class.new(members: [member("alpha")])

    expect { selection.apply(start_at: "missing") }.to raise_error(Kettle::Family::Error, /unknown member/)
  end

  it "rejects empty selections" do
    selection = described_class.new(members: [])

    expect { selection.apply }.to raise_error(Kettle::Family::Error, /selection is empty/)
  end
end
