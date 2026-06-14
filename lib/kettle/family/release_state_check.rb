# frozen_string_literal: true

require "json"
require "open3"
require "rbconfig"

module Kettle
  module Family
    class ReleaseStateCheck
      RELEASE_STATE_SCRIPT = <<~RUBY
        require "json"
        require "kettle/dev"
        cli = Kettle::Dev::ChangelogCLI.new(strict: false, root: Dir.pwd)
        puts JSON.pretty_generate(cli.release_state)
      RUBY

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
        command = release_state_command
        stdout, stderr, status = Open3.capture3(*command, chdir: member.root)
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
        success = status.success?
        state = success ? JSON.parse(stdout) : {}
        result(member: member, command: command, stdout: stdout, stderr: stderr, status: status.exitstatus, elapsed: elapsed, success: success, state: state)
      rescue JSON::ParserError => error
        result(member: member, command: command || release_state_command, stdout: stdout, stderr: stderr, status: 1, elapsed: elapsed || 0.0, success: false, state: {}, reason: "invalid release-state JSON: #{error.message}")
      end

      def release_state_command
        [RbConfig.ruby, "-e", RELEASE_STATE_SCRIPT]
      end

      def result(member:, command:, stdout:, stderr:, status:, elapsed:, success:, state:, reason: nil)
        ReleaseStateResult.new(
          member_name: member.name,
          command: command,
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
