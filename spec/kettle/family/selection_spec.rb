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

  it "selects members by release-state token" do
    members = [member("alpha"), member("beta"), member("gamma")]
    results = [
      release_state("alpha", "unreleased_entries" => true, "prepared_release_pending" => false, "pending_release" => true),
      release_state("beta", "unreleased_entries" => false, "prepared_release_pending" => true, "pending_release" => true),
      release_state("gamma", "unreleased_entries" => false, "prepared_release_pending" => false, "pending_release" => false)
    ]

    selected = described_class.new(members: members, release_state_results: results).apply(only: "pending")

    expect(selected.map(&:name)).to eq(%w[alpha beta])
  end

  it "selects members by bump release-state token" do
    members = [member("alpha"), member("beta"), member("gamma")]
    results = [
      release_state("alpha", "unreleased_entries" => true, "bump_release_pending" => true),
      release_state("beta", "unreleased_entries" => true, "bump_release_pending" => false),
      release_state("gamma", "unreleased_entries" => false, "bump_release_pending" => false)
    ]

    selected = described_class.new(members: members, release_state_results: results).apply(only: "bump")

    expect(selected.map(&:name)).to eq(["alpha"])
  end

  it "ANDs multiple release-state tokens" do
    members = [member("alpha"), member("beta"), member("gamma")]
    results = [
      release_state("alpha", "unreleased_entries" => true, "prepared_release_pending" => false, "pending_release" => true),
      release_state("beta", "unreleased_entries" => false, "prepared_release_pending" => true, "pending_release" => true),
      release_state("gamma", "unreleased_entries" => true, "prepared_release_pending" => true, "pending_release" => true)
    ]

    selected = described_class.new(members: members, release_state_results: results).apply(only: "pending,prepared")

    expect(selected.map(&:name)).to eq(%w[beta gamma])
  end

  it "rejects mixing release-state tokens with member names" do
    selection = described_class.new(members: [member("alpha")], release_state_results: [])

    expect { selection.apply(only: "pending,alpha") }.to raise_error(Kettle::Family::Error, /cannot be combined with member names: alpha/)
  end

  it "excludes comma-separated members from the family order" do
    selected = described_class.new(members: [member("alpha"), member("beta"), member("gamma")]).apply(exclude: "beta, gamma")

    expect(selected.map(&:name)).to eq(["alpha"])
  end

  it "rejects unknown only selections" do
    selection = described_class.new(members: [member("alpha")])

    expect { selection.apply(only: "missing,beta") }.to raise_error(Kettle::Family::Error, /unknown member\(s\): missing, beta/)
  end

  it "rejects empty only selections" do
    selection = described_class.new(members: [member("alpha")])

    expect { selection.apply(only: ",") }.to raise_error(Kettle::Family::Error, /--only requires at least one member/)
  end

  it "rejects unknown exclude selections" do
    selection = described_class.new(members: [member("alpha")])

    expect { selection.apply(exclude: "missing,beta") }.to raise_error(Kettle::Family::Error, /unknown member\(s\): missing, beta/)
  end

  it "rejects empty exclude selections" do
    selection = described_class.new(members: [member("alpha")])

    expect { selection.apply(exclude: ",") }.to raise_error(Kettle::Family::Error, /--exclude requires at least one member/)
  end

  it "rejects unknown start-at selections" do
    selection = described_class.new(members: [member("alpha")])

    expect { selection.apply(start_at: "missing") }.to raise_error(Kettle::Family::Error, /unknown member/)
  end

  it "rejects empty selections" do
    selection = described_class.new(members: [])

    expect { selection.apply }.to raise_error(Kettle::Family::Error, /selection is empty/)
  end

  def release_state(member_name, state)
    Kettle::Family::ReleaseStateResult.new(
      member_name: member_name,
      command: %w[kettle-changelog --release-state --json],
      workdir: member_name,
      status: 0,
      success: true,
      stdout: "",
      stderr: "",
      elapsed_seconds: 0.0,
      state: state
    )
  end
end
