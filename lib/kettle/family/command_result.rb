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
      :output_streamed,
      :log_path,
      :resume_step,
      :resume_command,
      # Machine-readable findings, complete and unsummarized. See #diagnostics.
      # Appended last because this Struct is positional: specs construct it with
      # positional arguments, so inserting a member mid-list would silently shift
      # every value after it.
      :diagnostics
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
          "output_streamed" => output_streamed?,
          "log_path" => log_path,
          "resume_step" => resume_step,
          "resume_command" => resume_command,
          "diagnostics" => diagnostics
        }
      end

      # Structured findings for machine consumers, complete and unsummarized.
      #
      # `stdout` is a human-facing summary and is deliberately truncated to its
      # last 20 lines by #summarize, so it cannot carry a full finding set. A
      # consumer that parsed the truncated `stdout` to decide what to act on
      # would silently act on an incomplete set. That is not hypothetical:
      # PublishedVersionCheck reported 28 unpublished lockfile pins for one
      # member, and the JSON report carried only the last 20, losing 8 gems.
      #
      # The text report is unaffected — it prints `stdout` in full — which is why
      # this only bites JSON consumers.
      #
      # Each entry is a Hash whose shape is defined by the producing check, plus
      # a "message" string matching the human-readable line it summarizes. Always
      # an Array, never nil, so consumers need no guard.
      #
      # Read through `self[:diagnostics]` rather than `super`: the block passed to
      # `Struct.new` is class_eval'd onto the generated class, so this method
      # REPLACES the generated accessor and has no superclass method to call.
      # `Struct#[]` reads the slot directly and cannot recurse into this method.
      #
      # @return [Array<Hash>]
      def diagnostics
        Array(self[:diagnostics])
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
