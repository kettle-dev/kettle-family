# frozen_string_literal: true

require "fileutils"
require "json"
require "stringio"
require "tmpdir"

RSpec.describe Kettle::Family::ReleaseStateEventTape do
  it "writes per-member NDJSON and optionally streams the same events" do
    Dir.mktmpdir("kettle-family-state-events") do |root|
      stream = StringIO.new
      tape = described_class.new(root: root, stream: stream, clock: -> { 2.5 }, wall_clock: -> { "2026-08-03T20:00:00Z" })

      tape.call("member" => "alpha", "action" => "member_start", "status" => "running")
      tape.call("member" => "alpha", "action" => "member_complete", "status" => "ok")
      tape.call("member" => "beta", "action" => "member_start", "status" => "running")

      alpha_path = File.join(tape.directory, "alpha.ndjson")
      beta_path = File.join(tape.directory, "beta.ndjson")
      alpha_events = File.readlines(alpha_path, chomp: true).map { |line| JSON.parse(line) }
      beta_events = File.readlines(beta_path, chomp: true).map { |line| JSON.parse(line) }

      expect(alpha_events.map { |event| event.fetch("sequence") }).to eq([1, 2])
      expect(alpha_events).to all(include("event_version" => 1, "type" => "release_state", "timestamp" => "2026-08-03T20:00:00Z"))
      expect(File.readlines(alpha_path).map { |line| line.scan('"elapsed_seconds"').length }).to eq([1, 1])
      expect(stream.string.lines.map { |line| JSON.parse(line) }).to eq(alpha_events + beta_events)
    end
  end
end
