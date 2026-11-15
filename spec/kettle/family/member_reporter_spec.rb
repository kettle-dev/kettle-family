# frozen_string_literal: true

RSpec.describe Kettle::Family::MemberReporter do
  let(:members) { %w[alpha beta gamma].map { |name| Kettle::Family::Member.new(name, "/tmp/#{name}", nil, nil, nil, [], [], nil, [], []) } }
  let(:events) { [] }

  def result(name, success)
    Kettle::Family::CommandResult.new(member_name: name, phase: "p", command: [], workdir: "/tmp", status: success ? 0 : 1, success: success, stdout: "", stderr: "", elapsed_seconds: 0.0, skipped: false, reason: nil)
  end

  def complete_status(name)
    events.find { |event| event["member"] == name && event["type"] == "member_complete" }&.fetch("status")
  end

  describe "#around_batch" do
    it "reports members a failed batch never reached as skipped" do
      reporter = described_class.new(command: "bump", members: members, tape: ->(event) { events << event })

      reporter.around_batch("bump") { [result("alpha", true), result("beta", false)] }

      expect([complete_status("alpha"), complete_status("beta"), complete_status("gamma")]).to eq(%w[ok failed skipped])
      expect(events.select { |event| event["member"] == "gamma" && event["type"] == "command_step" }.map { |event| event["status"] }).to eq(%w[started skipped])
    end

    it "reports members with no results as ok when the batch succeeded" do
      reporter = described_class.new(command: "clean-installed", members: members, tape: ->(event) { events << event })

      reporter.around_batch("clean-installed") { [result("alpha", true)] }

      expect(members.map { |member| complete_status(member.name) }).to eq(%w[ok ok ok])
    end
  end

  describe "#test_progress" do
    it "tapes the event with the member and command" do
      reporter = described_class.new(command: "test", members: members, tape: ->(event) { events << event })

      reporter.test_progress(members.first, {"type" => "test_progress", "kind" => "failure", "examples" => 3, "failures" => 1, "location" => "./spec/a_spec.rb:1"})

      expect(events).to contain_exactly(include("type" => "test_progress", "member" => "alpha", "command" => "test", "kind" => "failure"))
    end
  end
end
