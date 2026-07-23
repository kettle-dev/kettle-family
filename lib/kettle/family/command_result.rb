# frozen_string_literal: true

module Kettle
  module Family
    CommandResult = Struct.new(
      :member_name,
      :phase,
      :command,
      :workdir,
      :status,
      :success,
      :stdout,
      :stderr,
      :elapsed_seconds,
      :skipped,
      :reason,
      :branch,
      :output_streamed
    ) do
      def to_h
        {
          "member" => member_name,
          "branch" => branch,
          "phase" => phase,
          "command" => command,
          "workdir" => workdir,
          "status" => status,
          "success" => success,
          "stdout" => summarize(stdout),
          "stderr" => summarize(stderr),
          "elapsed_seconds" => elapsed_seconds,
          "skipped" => skipped,
          "reason" => reason,
          "output_streamed" => output_streamed?
        }
      end

      def ok?
        success || skipped
      end

      def output_streamed?
        !!output_streamed
      end

      private

      def summarize(output)
        return "" if output.nil? || output.empty?

        lines = output.lines.map(&:chomp)
        lines.last(20).join("\n")
      end
    end
  end
end
