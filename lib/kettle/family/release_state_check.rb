# frozen_string_literal: true

require "json"
require "open3"

module Kettle
  module Family
    class ReleaseStateCheck
      COMMAND = ["bundle", "exec", "kettle-changelog", "--release-state", "--json"].freeze

      def initialize(members:)
        @members = members
      end

      def results
        members.map { |member| check_member(member) }
      end

      private

      attr_reader :members

      def check_member(member)
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        stdout, stderr, status = Open3.capture3(*COMMAND, chdir: member.root)
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
        success = status.success?
        state = success ? JSON.parse(stdout) : {}
        result(member: member, stdout: stdout, stderr: stderr, status: status.exitstatus, elapsed: elapsed, success: success, state: state)
      rescue JSON::ParserError => error
        result(member: member, stdout: stdout, stderr: stderr, status: 1, elapsed: elapsed || 0.0, success: false, state: {}, reason: "invalid release-state JSON: #{error.message}")
      end

      def result(member:, stdout:, stderr:, status:, elapsed:, success:, state:, reason: nil)
        ReleaseStateResult.new(
          member_name: member.name,
          command: COMMAND,
          workdir: member.root,
          status: status,
          success: success,
          stdout: stdout,
          stderr: stderr,
          elapsed_seconds: elapsed,
          state: state,
          reason: reason || (success ? nil : "release state check failed")
        )
      end
    end
  end
end
