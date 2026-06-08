# frozen_string_literal: true

require "json"

module Kettle
  module Family
    class Report
      attr_reader :family_name, :order_mode, :members, :selected_members, :config_path, :command, :results

      def initialize(family_name:, order_mode:, members:, selected_members:, config_path:, command: nil, results: [])
        @family_name = family_name
        @order_mode = order_mode
        @members = members
        @selected_members = selected_members
        @config_path = config_path
        @command = command
        @results = results
      end

      def to_h
        {
          "family" => family_name,
          "config_path" => config_path,
          "order_mode" => order_mode,
          "members" => members.map(&:to_h),
          "selected_members" => selected_members.map(&:name),
          "command" => command,
          "results" => results.map(&:to_h),
          "resume_hint" => resume_hint
        }
      end

      def to_json(*args)
        JSON.pretty_generate(to_h, *args)
      end

      def to_text
        lines = ["family: #{family_name}"]
        lines << "config: #{config_path || "none"}"
        lines << "order: #{order_mode}"
        lines << "command: #{command}" if command
        lines << "members:"
        selected_names = selected_members.map(&:name)
        members.each do |member|
          marker = selected_names.include?(member.name) ? "*" : "-"
          lines << "  #{marker} #{member.name} #{member.version} #{member.root}"
        end
        append_results(lines)
        lines.join("\n")
      end

      def success?
        results.all?(&:ok?)
      end

      private

      def append_results(lines)
        return if results.empty?

        lines << "results:"
        results.each do |result|
          lines << "  #{result_state(result)} #{result.member_name} #{result.phase} #{result.reason || ""}".rstrip
          lines << "    #{result.stdout}" unless result.stdout.to_s.empty?
          lines << "    resume: #{resume_hint_for(result)}" unless result.ok?
        end
      end

      def result_state(result)
        return "skipped" if result.skipped
        return "ok" if result.success

        "failed"
      end

      def resume_hint
        failed = results.find { |result| !result.ok? }
        resume_hint_for(failed) if failed
      end

      def resume_hint_for(result)
        "kettle-family #{command} --start-at #{result.member_name}"
      end
    end
  end
end
