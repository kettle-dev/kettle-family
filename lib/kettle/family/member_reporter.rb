# frozen_string_literal: true

require_relative "workflow_progress"

module Kettle
  module Family
    # Per-member progress for a workflow command: a live WorkflowProgress pane
    # (when an IO is supplied) plus NDJSON events on the family event tape
    # (member_start, command_step, member_complete). Thread-safe, so parallel
    # workers can share one instance. Both outputs are optional.
    class MemberReporter
      def self.build(command:, members:, io:, tape:, execute:, jobs: 1)
        return nil if !execute || (io.nil? && tape.nil?)

        new(command: command, members: members, io: io, tape: tape, jobs: jobs)
      end

      def initialize(command:, members:, io: nil, tape: nil, jobs: 1)
        @command = command
        @members = members
        @tape = tape
        @completed = []
        @failed = []
        @mutex = Mutex.new
        @progress = io && WorkflowProgress.new(io: io, label: command, total: members.size, jobs: jobs, members: members)
        @progress&.start
      end

      def start_member(member, steps:)
        @progress&.start_member(member, total: steps, status: "starting")
        emit("member_start", member, status: "started", total: steps)
      end

      def step_started(member, phase)
        @progress&.update(member, status: "#{phase} started")
        emit("command_step", member, phase: phase, status: "started")
      end

      def step_finished(member, phase, ok:, elapsed_seconds: nil)
        @progress&.advance(member, status: "#{phase} #{ok ? "ok" : "failed"}", success: ok)
        emit("command_step", member, phase: phase, status: ok ? "ok" : "failed", elapsed_seconds: elapsed_seconds)
      end

      def finish_member(member, success:)
        @mutex.synchronize { (success ? @completed : @failed) << member.name }
        @progress&.finish_member(member, success: success, status: success ? "complete" : "failed")
        emit("member_complete", member, status: success ? "ok" : "failed")
      end

      # Report a batched run (one command covering every member) as a single
      # step per member: all members start, then each finishes with the outcome
      # of its own results once the batch returns.
      def around_batch(phase)
        @members.each do |member|
          start_member(member, steps: 1)
          step_started(member, phase)
        end
        results = yield
        @members.each do |member|
          own = results.select { |result| result.member_name == member.name }
          ok = own.all?(&:ok?)
          step_finished(member, phase, ok: ok, elapsed_seconds: own.sum { |result| result.elapsed_seconds.to_f })
          finish_member(member, success: ok)
        end
        results
      ensure
        finish
      end

      def finish
        return unless @progress

        @progress.finish
        done, failed = @mutex.synchronize { [@completed.dup, @failed.dup] }
        unstarted = @members.map(&:name) - done - failed
        @progress.summary("#{@command} summary: completed: #{done.join(", ")}; failed: #{failed.join(", ").then { |s| s.empty? ? "-" : s }}; unstarted: #{unstarted.join(", ")}")
      end

      private

      def emit(type, member, **attributes)
        @tape&.call({"type" => type, "command" => @command, "member" => member.name}.merge(attributes.transform_keys(&:to_s)))
      end
    end
  end
end
