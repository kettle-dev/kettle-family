# frozen_string_literal: true

module Kettle
  module Family
    class ReleaseStateResult
      attr_reader :member_name, :phase, :command, :workdir, :status, :success, :stdout, :stderr, :elapsed_seconds, :skipped, :reason, :state, :branch

      def initialize(member_name:, command:, workdir:, status:, success:, stdout:, stderr:, elapsed_seconds:, state:, reason: nil, branch: nil)
        @member_name = member_name
        @phase = "release_state"
        @command = command
        @workdir = workdir
        @status = status
        @success = success
        @stdout = stdout
        @stderr = stderr
        @elapsed_seconds = elapsed_seconds
        @skipped = false
        @reason = reason
        @state = state
        @branch = branch
      end

      def ok?
        success
      end

      def to_h
        {
          "member" => member_name,
          "phase" => phase,
          "command" => command,
          "workdir" => workdir,
          "status" => status,
          "success" => success,
          "stdout" => stdout.to_s.lines.last(20).map(&:chomp).join("\n"),
          "stderr" => stderr.to_s.lines.last(20).map(&:chomp).join("\n"),
          "elapsed_seconds" => elapsed_seconds,
          "skipped" => skipped,
          "reason" => reason,
          "branch" => branch,
          "release_state" => state
        }
      end
    end
  end
end
