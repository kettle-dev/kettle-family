# frozen_string_literal: true

RSpec.describe Kettle::Family::Selection do
  def member(name)
    Kettle::Family::Member.new(name: name, root: name, gemspec_path: "#{name}.gemspec", version: "1.0.0", dependencies: [])
  end

  # A branch-stack member reports one result per branch, all sharing a member
  # name. Selection must not be decided by whichever branch came last.
  describe "branch-stack members" do
    let(:members) { [member("alpha"), member("beta")] }

    it "selects a stack member when any of its branches matches, not only the last" do
      results = [
        branch_state("alpha", "r1_8-even-v0", "pending_release" => true),
        branch_state("alpha", "r2_1-even-v6", "pending_release" => true),
        branch_state("alpha", "main", "pending_release" => false),
        branch_state("beta", "main", "pending_release" => false)
      ]

      selected = described_class.new(members: members, release_state_results: results).apply(only: "pending")

      expect(selected.map(&:name)).to eq(["alpha"])
    end

    it "ANDs tokens within one branch rather than across a member's branches" do
      results = [
        branch_state("alpha", "r1_8-even-v0", "unreleased_entries" => true, "prepared_release_pending" => false),
        branch_state("alpha", "main", "unreleased_entries" => false, "prepared_release_pending" => true),
        branch_state("beta", "main", "unreleased_entries" => false, "prepared_release_pending" => false)
      ]
      selection = described_class.new(members: members, release_state_results: results)

      expect { selection.apply(only: "unreleased,prepared") }.to raise_error(Kettle::Family::Error, /selection is empty/)
    end

    it "reports a failed branch probe once per member" do
      results = [
        branch_state("alpha", "r1_8-even-v0", { "pending_release" => false }, status: 1, success: false),
        branch_state("alpha", "main", { "pending_release" => false }, status: 1, success: false)
      ]

      expect { described_class.new(members: members, release_state_results: results).apply(only: "pending") }
        .to raise_error(Kettle::Family::Error, /release-state check failed for: alpha\z/)
    end

    it "reports only branches whose own state matches" do
      results = [
        branch_state("alpha", "r1_8-even-v0", "unreleased_entries" => true, "bump_release_pending" => false),
        branch_state("alpha", "r2_1-even-v6", "unreleased_entries" => true, "bump_release_pending" => true),
        branch_state("alpha", "main", "unreleased_entries" => false, "bump_release_pending" => false),
        branch_state("beta", "main", "unreleased_entries" => true, "bump_release_pending" => true)
      ]

      expect(described_class.branches_matching(results, member_name: "alpha", tokens: %w[bump])).to eq(["r2_1-even-v6"])
      expect(described_class.branches_matching(results, member_name: "beta", tokens: %w[bump])).to eq(["main"])
    end

    it "reports no branches when the member has no matching branch state" do
      results = [branch_state("alpha", "main", "bump_release_pending" => false)]

      expect(described_class.branches_matching(results, member_name: "alpha", tokens: %w[bump])).to be_empty
      expect(described_class.branches_matching(results, member_name: "alpha", tokens: %w[not-a-token])).to be_empty
    end
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

  it "selects members by shortened release-state table tokens" do
    members = [member("alpha"), member("beta"), member("gamma")]
    results = [
      release_state("alpha", "unreleased_entries" => true, "prepared_release_pending" => false, "pending_release" => true),
      release_state("beta", "unreleased_entries" => false, "prepared_release_pending" => true, "pending_release" => true),
      release_state("gamma", "unreleased_entries" => true, "prepared_release_pending" => true, "pending_release" => true)
    ]

    selected = described_class.new(members: members, release_state_results: results).apply(only: "pend,prep")

    expect(selected.map(&:name)).to eq(%w[beta gamma])
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

  it "keeps bump selection exact even when a family shares a version" do
    members = [member("alpha"), member("beta"), member("gamma")]
    results = [
      release_state("alpha", "bump_release_pending" => true),
      release_state("beta", "bump_release_pending" => false),
      release_state("gamma", "bump_release_pending" => false)
    ]

    selected = described_class.new(
      members: members,
      release_state_results: results
    ).apply(only: "bump")

    expect(selected.map(&:name)).to eq(["alpha"])
  end

  it "keeps pending selection exact" do
    members = [member("alpha"), member("beta"), member("local")]
    results = [
      release_state("alpha", "pending_release" => true),
      release_state("beta", "pending_release" => false),
      release_state("local", "pending_release" => false)
    ]

    selected = described_class.new(
      members: members,
      release_state_results: results
    ).apply(only: "pending")

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

  it "rejects release-state selection when a state probe failed" do
    failed_result = release_state("alpha", {"pending_release" => true}, {status: 1, success: false})
    selection = described_class.new(members: [member("alpha")], release_state_results: [failed_result])

    expect { selection.apply(only: "pending") }.to raise_error(Kettle::Family::Error, /release-state check failed for: alpha/)
  end

  it "rejects release-state selection when state results were not collected" do
    selection = described_class.new(members: [member("alpha")])

    expect { selection.apply(only: "pending") }
      .to raise_error(Kettle::Family::Error, /require release-state results/)
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

  def release_state(member_name, state, options = {})
    Kettle::Family::ReleaseStateResult.new(
      member_name: member_name,
      command: %w[kettle-changelog --release-state --json],
      workdir: member_name,
      status: options.fetch(:status, 0),
      success: options.fetch(:success, true),
      stdout: "",
      stderr: "",
      elapsed_seconds: 0.0,
      state: state,
      branch: options[:branch]
    )
  end

  def branch_state(member_name, branch, state, options = {})
    release_state(member_name, state, options.merge(branch: branch))
  end
end
