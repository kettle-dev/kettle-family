# frozen_string_literal: true

require "json"

module Kettle
  module Family
    class Report
      attr_reader :family_name, :family_mode, :order_mode, :members, :selected_members, :config_path, :command, :results, :branch_lanes, :release_target_branches, :member_release_target_branches, :release_mode

      def initialize(family_name:, order_mode:, members:, selected_members:, config_path:, family_mode: nil, branch_lanes: {}, release_target_branches: [], member_release_target_branches: {}, release_mode: nil, command: nil, results: [])
        @family_name = family_name
        @family_mode = family_mode
        @order_mode = order_mode
        @members = members
        @selected_members = selected_members
        @config_path = config_path
        @command = command
        @results = results
        @branch_lanes = branch_lanes
        @release_target_branches = release_target_branches
        @member_release_target_branches = member_release_target_branches
        @release_mode = release_mode
      end

      def to_h
        {
          "family" => family_name,
          "family_mode" => family_mode,
          "config_path" => config_path,
          "order_mode" => order_mode,
          "members" => members.map(&:to_h),
          "selected_members" => selected_members.map(&:name),
          "branch_lanes" => branch_lanes,
          "release_target_branches" => release_target_branches,
          "member_release_target_branches" => member_release_target_branches,
          "release_mode" => release_mode,
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
        lines << "mode: #{family_mode}" if family_mode
        lines << "config: #{config_path || "none"}"
        lines << "order: #{order_mode}"
        lines << "command: #{command}" if command
        lines << "release mode: #{release_mode}" if release_mode
        lines << "release targets: #{release_target_branches.join(", ")}" unless release_target_branches.empty?
        append_member_release_targets(lines)
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
        return append_metadata_results(lines) if command == "metadata"
        return if results.empty?
        return append_release_state_results(lines) if command == "release-state"

        lines << "results:"
        results.each do |result|
          lines << "  #{result_state(result)} #{result.member_name} #{result.phase} #{result.reason || ""}".rstrip
          append_indented_output(lines, result.stdout) unless result.stdout.to_s.empty?
          append_indented_output(lines, result.stderr) if !result.ok? && !result.stderr.to_s.empty?
          lines << "    resume: #{resume_hint_for(result)}" unless result.ok?
        end
      end

      def append_indented_output(lines, output)
        output.to_s.each_line(chomp: true) { |line| lines << "    #{line}" }
      end

      def append_member_release_targets(lines)
        return if member_release_target_branches.empty?

        lines << "member release targets:"
        member_release_target_branches.each do |member_name, branches|
          lines << "  #{member_name}: #{branches.join(", ")}"
        end
      end

      def result_state(result)
        return "skipped" if result.skipped
        return "ok" if result.success

        "failed"
      end

      def append_metadata_results(lines)
        lines << "metadata:"
        rows = [["gem", "version", "ruby", "licenses", "authors"]]
        selected_members.each do |member|
          rows << [
            member.name.to_s,
            member.version.to_s,
            blank_as_none(member.required_ruby_version),
            blank_as_none(Array(member.licenses).join(", ")),
            blank_as_none(Array(member.authors).join(", "))
          ]
        end
        lines.concat(format_table(rows).map { |line| "  #{line}" })
      end

      def append_release_state_results(lines)
        lines << "release state:"
        rows = release_state_header
        results.each do |result|
          rows << release_state_row(result)
        end
        lines.concat(format_table(rows).map { |line| "  #{line}" })
        failures = results.reject(&:ok?)
        return if failures.empty?

        lines << "release state errors:"
        failures.each do |result|
          lines << "  failed #{result.member_name} #{result.reason || ""}".rstrip
          lines << "    #{result.stderr}" unless result.stderr.to_s.empty?
        end
      end

      def release_state_row(result)
        state = result.state || {}
        row = [
          state.fetch("gem_name", result.member_name).to_s,
          state.fetch("version", "unknown").to_s,
          state.fetch("latest_released", nil).to_s.empty? ? "unknown" : state.fetch("latest_released").to_s,
          state.fetch("latest_changelog_version", nil).to_s.empty? ? "none" : state.fetch("latest_changelog_version").to_s,
          yes_no(state.fetch("unreleased_entries", nil)),
          yes_no(state.fetch("prepared_release_pending", nil)),
          yes_no(state.fetch("pending_release", nil))
        ]
        return row unless release_state_has_branches?

        [result.branch.to_s.empty? ? "current" : result.branch.to_s, *row]
      end

      def release_state_header
        header = [["gem", "version.rb", "latest released", "latest changelog", "unreleased", "prepared", "pending"]]
        return header unless release_state_has_branches?

        [["branch", *header.first]]
      end

      def release_state_has_branches?
        results.any? { |result| !result.branch.to_s.empty? }
      end

      def format_table(rows)
        widths = rows.transpose.map { |column| column.map(&:length).max }
        rows.flat_map.with_index do |row, index|
          line = row.each_with_index.map { |value, i| value.ljust(widths.fetch(i)) }.join("  ").rstrip
          index.zero? ? [line, widths.map { |width| "-" * width }.join("  ")] : [line]
        end
      end

      def yes_no(value)
        case value
        when true
          "yes"
        when false
          "no"
        else
          "unknown"
        end
      end

      def blank_as_none(value)
        text = value.to_s.strip
        text.empty? ? "(none)" : text
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
