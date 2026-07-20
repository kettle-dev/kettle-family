# frozen_string_literal: true

require "json"

module Kettle
  module Family
    class Report
      MEMBER_RESULT_COMMANDS = %w[
        add-changelog
        bex
        bump-version
        bup
        bupb
        check
        docs
        gha-sha-pins
        install
        lint
        pull
        push
        release
        release-state
        template
        test
        up
      ].freeze

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
          "summary" => summary,
          "resume_hint" => resume_hint
        }
      end

      def to_json(*args)
        JSON.pretty_generate(to_h, *args)
      end

      def to_text
        lines = ["kettle-family: #{Kettle::Family::VERSION}", "family: #{family_name}"]
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
        append_release_waves(lines)
        append_results(lines)
        append_summary(lines)
        lines.join("\n")
      end

      def success?
        results.all?(&:ok?) && summary_pending.empty?
      end

      private

      def append_results(lines)
        return append_metadata_results(lines) if command == "metadata"
        return if results.empty?
        return append_release_state_results(lines) if command == "release-state"

        visible_results = results.reject { |result| release_wave_result?(result) }
        return if visible_results.empty?

        lines << "results:"
        visible_results.each do |result|
          lines << "  #{result_state(result)} #{result.member_name} #{result.phase} #{result.reason || ""}".rstrip
          append_indented_output(lines, result.stdout) unless suppress_success_output?(result)
          append_indented_output(lines, result.stderr) if !result.ok? && !result.stderr.to_s.empty?
          lines << "    resume: #{resume_hint_for(result)}" unless result.ok?
        end
        append_template_summary(lines) if command == "template"
      end

      def append_summary(lines)
        data = summary
        lines << "summary:"
        lines << "  outcome: #{data.fetch("outcome")}"
        lines << "  selected: #{data.fetch("selected_count")}"
        lines << "  results: #{data.fetch("result_count")}"
        lines << "  succeeded: #{summary_list(data.fetch("succeeded"))}"
        lines << "  skipped: #{summary_list(data.fetch("skipped"))}"
        lines << "  failed: #{summary_list(data.fetch("failed").map { |entry| summary_entry(entry) })}"
        lines << "  pending: #{summary_list(data.fetch("pending").map { |entry| summary_entry(entry) })}"
        lines << "  resume: #{data.fetch("resume_hint")}" if data.fetch("resume_hint")
      end

      def summary
        {
          "outcome" => success? ? "success" : "failure",
          "selected_count" => selected_members.length,
          "result_count" => visible_results.length,
          "succeeded" => summary_succeeded,
          "skipped" => summary_skipped,
          "failed" => summary_failed,
          "pending" => summary_pending,
          "resume_hint" => resume_hint
        }
      end

      def append_release_waves(lines)
        wave_results = results.select { |result| release_wave_result?(result) }
        return if wave_results.empty?

        lines << "release waves:"
        wave_results.each do |result|
          lines << "  #{result.member_name}: #{result.stdout} (#{result.reason})"
        end
      end

      def release_wave_result?(result)
        result.phase == "release_wave"
      end

      def visible_results
        results.reject { |result| release_wave_result?(result) }
      end

      def append_indented_output(lines, output)
        output.to_s.each_line(chomp: true) { |line| lines << "    #{line}" }
      end

      def suppress_success_output?(result)
        result.stdout.to_s.empty? || (command == "template" && result.ok?)
      end

      def append_template_summary(lines)
        template_results = results.select { |result| result.phase == "template" }
        return if template_results.empty?

        changed_files = template_results.sum { |result| template_changed_file_count(result) }
        lines << "template summary:"
        lines << "  #{template_results.count(&:ok?)}/#{template_results.length} members ok"
        lines << "  #{changed_files} file#{"s" unless changed_files == 1} changed"
      end

      def template_changed_file_count(result)
        payload = JSON.parse(result.stdout.to_s)
        Array(payload["changed_files"] || payload[:changed_files]).length if payload.is_a?(Hash)
      rescue JSON::ParserError
        match = result.stdout.to_s.match(/(?:install|apply|prepare|template):\s+(\d+)\s+changed file/)
        return match[1].to_i if match

        0
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

      def member_result_command?
        MEMBER_RESULT_COMMANDS.include?(command)
      end

      def selected_names
        selected_members.map(&:name)
      end

      def selected_member_results
        return {} unless member_result_command?

        visible_results.each_with_object(Hash.new { |hash, key| hash[key] = [] }) do |result, memo|
          next unless selected_names.include?(result.member_name)

          memo[result.member_name] << result
        end
      end

      def summary_succeeded
        selected_member_results.filter_map do |member_name, member_results|
          next if member_results.empty?
          next if member_results.any? { |result| !result.ok? }
          next if member_results.all?(&:skipped)

          member_name
        end
      end

      def summary_skipped
        selected_member_results.filter_map do |member_name, member_results|
          next if member_results.empty?
          next unless member_results.all?(&:skipped)

          member_name
        end
      end

      def summary_failed
        visible_results.reject(&:ok?).map do |result|
          {
            "member" => result.member_name,
            "phase" => result.phase,
            "reason" => result.reason || "command failed"
          }
        end
      end

      def summary_pending
        return [] unless member_result_command?
        return [] if visible_results.empty?

        ran = selected_member_results.keys
        reason = pending_reason
        (selected_names - ran).map do |member_name|
          {
            "member" => member_name,
            "phase" => command,
            "reason" => reason
          }
        end
      end

      def pending_reason
        if visible_results.any? { |result| !result.ok? }
          "not run after earlier failure"
        else
          "no command result recorded"
        end
      end

      def summary_list(values)
        values.empty? ? "none" : values.join(", ")
      end

      def summary_entry(entry)
        reason = entry.fetch("reason")
        "#{entry.fetch("member")} #{entry.fetch("phase")} (#{reason})"
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
          state.fetch("ahead", nil).nil? ? "unknown" : state.fetch("ahead").to_s,
          yes_no(state.fetch("unreleased_entries", nil)),
          yes_no(state.fetch("prepared_release_pending", nil)),
          yes_no(state.fetch("pending_release", nil))
        ]
        return row unless release_state_has_branches?

        [result.branch.to_s.empty? ? "current" : result.branch.to_s, *row]
      end

      def release_state_header
        header = [["gem", "version.rb", "latest released", "latest changelog", "ahead", "unreleased", "prepared", "pending"]]
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
        return release_resume_hint if command == "release"

        "kettle-family #{command} --start-at #{result.member_name}"
      end

      def release_resume_hint
        hint = "kettle-family release --execute"
        hint = "#{hint} --publish" if release_mode == "publish"
        hint
      end
    end
  end
end
