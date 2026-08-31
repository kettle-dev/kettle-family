# frozen_string_literal: true

require "json"
require "shellwords"

module Kettle
  module Family
    class Report
      MEMBER_RESULT_COMMANDS = %w[
        add-changelog
        bex
        bump
        bump-version
        bup
        bupb
        check
        clean-unreleased
        docs
        gha-sha-pins
        install
        lint
        pull
        push
        reconcile-releases
        release
        release-state
        reset
        sync
        template
        test
        up
      ].freeze

      attr_reader :family_name, :family_mode, :order_mode, :members, :selected_members, :config_path, :command, :results, :branch_lanes, :release_target_branches, :member_release_target_branches, :release_mode, :release_resume_arguments, :warnings, :event_log_dirs

      def initialize(family_name:, order_mode:, members:, selected_members:, config_path:, family_mode: nil, branch_lanes: {}, release_target_branches: [], member_release_target_branches: {}, release_mode: nil, release_resume_arguments: [], command: nil, results: [], warnings: [], event_log_dirs: [], elapsed_seconds: nil)
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
        @release_resume_arguments = release_resume_arguments.dup.freeze
        @warnings = warnings
        @event_log_dirs = event_log_dirs
        @elapsed_seconds = elapsed_seconds
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
          "warnings" => warnings,
          "event_log_dirs" => event_log_dirs,
          "command" => command,
          "results" => results.map(&:to_h),
          "summary" => summary,
          "resume_hint" => resume_hint,
          "resume_hints" => resume_hints
        }
      end

      def to_json(*args)
        JSON.pretty_generate(to_h, *args)
      end

      def to_text
        lines = report_context_lines
        append_member_release_targets(lines)
        append_warnings(lines)
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

      def append_warnings(lines)
        return if warnings.empty?

        lines << "warnings:"
        warnings.each do |warning|
          lines << "  #{warning.fetch("message")}"
        end
      end

      def append_results(lines)
        return append_metadata_results(lines) if command == "metadata"
        return if results.empty?
        return append_release_state_results(lines) if command == "release-state"

        visible_results = results.reject { |result| release_wave_result?(result) }
        return if visible_results.empty?

        lines << "results:"
        visible_results.each do |result|
          lines << "  #{result_state(result)} #{result.member_name} #{result.phase} #{result.reason || ""}".rstrip
          append_result_stdout(lines, result)
          append_indented_output(lines, result.stderr) if !result.ok? && !result.stderr.to_s.empty?
          resume_hint = resume_hint_for(result)
          lines << "    resume: #{resume_hint}" if !result.ok? && resume_hint
        end
        append_template_summary(lines) if command == "template"
      end

      def append_summary(lines)
        data = summary
        lines << "context:"
        report_context_lines.each { |line| lines << "  #{line}" }
        unless member_release_target_branches.empty?
          lines << "  member release targets:"
          member_release_target_branches.each do |member_name, branches|
            lines << "    #{member_name}: #{branches.join(", ")}"
          end
        end
        lines << "summary:"
        lines << "  outcome: #{data.fetch("outcome")}"
        lines << "  elapsed: #{format_elapsed(data.fetch("elapsed_seconds"))}"
        lines << "  events: #{event_log_dirs.join(", ")}" unless event_log_dirs.empty?
        lines << "  logs: #{data.fetch("release_log_dirs").join(", ")}" unless data.fetch("release_log_dirs").empty?
        lines << "  selected: #{data.fetch("selected_count")}"
        lines << "  results: #{data.fetch("result_count")}"
        lines << "  succeeded: #{summary_list(data.fetch("succeeded"))}"
        lines << "  skipped: #{summary_list(data.fetch("skipped"))}"
        lines << "  failed: #{summary_list(data.fetch("failed").map { |entry| summary_entry(entry) })}"
        lines << "  pending: #{summary_list(data.fetch("pending").map { |entry| summary_entry(entry) })}"
        hints = data.fetch("resume_hints")
        if hints.one?
          lines << "  resume: #{hints.first}"
        elsif hints.any?
          lines << "  resume:"
          hints.each { |hint| lines << "    #{hint}" }
        end
      end

      def report_context_lines
        lines = ["kettle-family: #{Kettle::Family::VERSION}", "family: #{family_name}"]
        lines << "mode: #{family_mode}" if family_mode
        lines << "config: #{config_path || "none"}"
        lines << "order: #{order_mode}"
        lines << "command: #{command}" if command
        lines << "release mode: #{release_mode}" if release_mode
        lines << "release targets: #{release_target_branches.join(", ")}" unless release_target_branches.empty?
        lines
      end

      def summary
        {
          "outcome" => success? ? "success" : "failure",
          "elapsed_seconds" => elapsed_seconds,
          "selected_count" => selected_members.length,
          "result_count" => visible_results.length,
          "succeeded" => summary_succeeded,
          "skipped" => summary_skipped,
          "failed" => summary_failed,
          "pending" => summary_pending,
          "release_log_dirs" => release_log_dirs,
          "resume_hint" => resume_hint,
          "resume_hints" => resume_hints
        }
      end

      def release_log_dirs
        return [] unless command == "release"

        visible_results.filter_map do |result|
          path = result.log_path.to_s if result.respond_to?(:log_path)
          File.dirname(path) unless path.to_s.empty?
        end.uniq
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

      def elapsed_seconds
        (@elapsed_seconds || visible_results.sum { |result| result.elapsed_seconds.to_f }).round(3)
      end

      def format_elapsed(seconds)
        total = seconds.to_f.round
        hours = total / 3600
        minutes = (total % 3600) / 60
        remaining_seconds = total % 60
        return format("%d:%02d:%02d", hours, minutes, remaining_seconds) if hours.positive?

        format("%02d:%02d", minutes, remaining_seconds)
      end

      def append_indented_output(lines, output)
        output.to_s.each_line(chomp: true) { |line| lines << "    #{line}" }
      end

      def append_result_stdout(lines, result)
        if machine_readable_result?(result)
          append_result_log_path(lines, result) unless result.ok?
          return
        end

        if suppress_success_output?(result)
          append_result_log_path(lines, result) unless result.ok?
          return
        end

        if output_streamed?(result)
          append_streamed_output_summary(lines, result) unless result.ok?
        elsif template_event_stdout?(result)
          append_template_event_failure_summary(lines, result.stdout) unless result.ok?
        elsif release_event_stdout?(result)
          append_release_event_failure_summary(lines, result.stdout) unless result.ok?
        else
          append_indented_output(lines, result.stdout)
        end
        append_result_log_path(lines, result) unless result.ok? || output_streamed?(result)
      end

      def append_result_log_path(lines, result)
        lines << "    log: #{result.log_path}" if result.respond_to?(:log_path) && !result.log_path.to_s.empty?
      end

      def suppress_success_output?(result)
        result.stdout.to_s.empty? || (command == "template" && result.ok?)
      end

      def machine_readable_result?(result)
        command == "release" && %w[gha_sha_pins_list gha_sha_pins_review].include?(result.phase.to_s)
      end

      def template_event_stdout?(result)
        command == "template" && template_events(result.stdout).any?
      end

      def release_event_stdout?(result)
        command == "release" && result.phase.to_s.start_with?("release_") && template_events(result.stdout).any?
      end

      def output_streamed?(result)
        result.respond_to?(:output_streamed?) && result.output_streamed?
      end

      def append_streamed_output_summary(lines, result)
        summary = streamed_output_summary(result)
        lines << "    summary: #{summary}" if summary
        recommended_fix = streamed_recommended_fix(result)
        lines << "    recommended fix: #{recommended_fix}" if recommended_fix
        append_result_log_path(lines, result)
        lines << "    output: omitted because it was already streamed"
      end

      def streamed_output_summary(result)
        lines = streamed_output_lines(result)
        lines.reverse.find do |line|
          line.match?(/(?:failed|failure|error|exited|aborted)/i) && !line.match?(/\A(?:Files|CI|Actions)/)
        end || lines.reverse.find { |line| !line.match?(/\A(?:Files|CI|Actions)/) }
      end

      def streamed_recommended_fix(result)
        line = streamed_output_lines(result).reverse.find { |candidate| candidate.match?(/\ARecommended fix:\s+/) }
        line&.sub(/\ARecommended fix:\s+/, "")
      end

      def streamed_output_lines(result)
        [result.stdout, result.stderr].join("\n").lines.map(&:strip).reject(&:empty?)
      end

      def append_template_event_failure_summary(lines, output)
        diagnostics = template_events(output).filter_map do |event|
          next unless event["type"] == "diagnostic"

          event["message"].to_s.empty? ? event["kind"].to_s : event["message"].to_s
        end.uniq
        diagnostics.each { |message| lines << "    diagnostic: #{message}" unless message.empty? }
        lines << "    template event stream omitted from text report"
      end

      def append_release_event_failure_summary(lines, output)
        events = template_events(output)
        diagnostics = events.filter_map do |event|
          next unless event["type"] == "diagnostic"

          event["message"].to_s.empty? ? event["kind"].to_s : event["message"].to_s
        end.uniq
        summary = events.reverse.find { |event| event["type"] == "summary" }
        diagnostics.each { |message| lines << "    diagnostic: #{message}" unless message.empty? }
        if summary
          detail = [summary["status"], summary["error_message"]].map(&:to_s).reject(&:empty?).join(": ")
          lines << "    summary: #{detail}" unless detail.empty?
        end
        lines << "    release event stream omitted from text report"
      end

      def append_template_summary(lines)
        template_results = results.select { |result| result.phase == "template" }
        return if template_results.empty?

        changed_files = template_results.sum { |result| template_changed_file_count(result) }
        outcome_counts = template_results.map { |result| template_file_outcomes(result) }
        lines << "template summary:"
        lines << "  #{template_results.count(&:ok?)}/#{selected_members.length} members ok"
        if outcome_counts.all?
          lines << "  #{outcome_counts.sum { |outcomes| outcomes.fetch(:checksum_hits) }} checksum hits"
          protected = outcome_counts.sum { |outcomes| outcomes.fetch(:checksum_protected) }
          lines << "  #{protected} checksum-protected changes" if protected.positive?
          lines << "  #{outcome_counts.sum { |outcomes| outcomes.fetch(:unchanged) }} unchanged"
        end
        lines << "  #{changed_files} file#{"s" unless changed_files == 1} changed"
      end

      def template_changed_file_count(result)
        event_count = template_changed_file_count_from_events(result.stdout)
        return event_count if event_count

        payload = JSON.parse(result.stdout.to_s)
        Array(payload["changed_files"] || payload[:changed_files]).length if payload.is_a?(Hash)
      rescue JSON::ParserError
        match = result.stdout.to_s.match(/(?:install|apply|prepare|template):\s+(\d+)\s+changed file/)
        return match[1].to_i if match

        0
      end

      def template_changed_file_count_from_events(output)
        summaries = template_events(output).select { |event| event["type"] == "summary" }
        return nil if summaries.empty?

        changed_files = summaries.flat_map { |event| Array(event["changed_files"] || event[:changed_files]) }
        changed_files = changed_files.map(&:to_s).reject(&:empty?).uniq
        return changed_files.length unless changed_files.empty?

        summary = summaries.reverse.find { |event| event.key?("changed_count") }
        summary&.fetch("changed_count")&.to_i
      end

      def template_file_outcomes(result)
        summary = template_events(result.stdout).reverse.find do |event|
          event["type"] == "summary" && event.key?("checksum_hit_count") &&
            event.key?("checksum_protected_count") && event.key?("unchanged_count")
        end
        return unless summary

        {
          checksum_hits: summary.fetch("checksum_hit_count").to_i,
          checksum_protected: summary.fetch("checksum_protected_count").to_i,
          unchanged: summary.fetch("unchanged_count").to_i
        }
      end

      def template_events(output)
        output.to_s.each_line.filter_map do |line|
          payload = JSON.parse(line)
          payload if payload.is_a?(Hash) && payload["event_version"]
        rescue JSON::ParserError
          nil
        end
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
          member_results = summary_terminal_member_results(member_results)
          next if member_results.empty?
          next if command == "template" && member_results.none? { |result| result.phase == "template" }
          next if command == "template" && member_results.any? { |result| result.phase == "template" && result.skipped }
          next if member_results.any? { |result| !result.ok? }
          next if member_results.all?(&:skipped)

          member_name
        end
      end

      def summary_skipped
        selected_member_results.filter_map do |member_name, member_results|
          next if member_results.empty?
          member_results = summary_terminal_member_results(member_results)
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

        ran = summary_ran_member_names
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

      def summary_ran_member_names
        if command == "template"
          failed = visible_results.reject(&:ok?).map(&:member_name)
          templated = selected_member_results.filter_map do |member_name, member_results|
            member_name if member_results.any? { |result| result.phase == "template" }
          end
          return (failed + templated).uniq
        end

        return selected_member_results.keys unless command == "release"

        failed = visible_results.reject(&:ok?).map(&:member_name)
        terminal = selected_member_results.filter_map do |member_name, member_results|
          member_name if member_results.any? { |result| release_terminal_result?(result) }
        end
        (failed + terminal).uniq
      end

      def summary_terminal_member_results(member_results)
        return member_results unless command == "release"

        member_results.select { |result| release_terminal_result?(result) }
      end

      def release_terminal_result?(result)
        result.phase == "release_skip" ||
          result.phase == "release_publish" ||
          result.phase == "release_build"
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
        lines << "  boolean columns:"
        lines << "    unrel: unreleased changelog entries are present (including replayed transfer entries)"
        lines << "    prep: V.ch.md matches V.rb and is ready to publish"
        lines << "    pend: unrel or prep"
        lines << "    bump: unrel is yes and V.rb matches V.rel"
        lines << "  count columns:"
        lines << "    T(n): filter-aware kettle-jem transfer changelog lag; n is the total source entry count and row values are missing / applicable (x excluded-present)"
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
          release_state_checkout(state),
          state.fetch("version", "unknown").to_s,
          state.fetch("latest_changelog_version", nil).to_s.empty? ? "none" : state.fetch("latest_changelog_version").to_s,
          state.fetch("latest_released", nil).to_s.empty? ? "unknown" : state.fetch("latest_released").to_s,
          release_state_github_release(state),
          release_state_transfer_changelog_value(state),
          release_state_ahead_behind(state),
          yes_no(state.fetch("unreleased_entries", nil)),
          yes_no(state.fetch("prepared_release_pending", nil)),
          yes_no(state.fetch("pending_release", nil)),
          yes_no(state.fetch("bump_release_pending", nil))
        ]
        return row unless release_state_has_branches?

        [result.branch.to_s.empty? ? "current" : result.branch.to_s, *row]
      end

      def release_state_header
        header = [["gem", "checkout", "V.rb", "V.ch.md", "V.rel", "GH.rel", release_state_transfer_changelog_header, "^ / v", "unrel", "prep", "pend", "bump"]]
        return header unless release_state_has_branches?

        [["branch", *header.first]]
      end

      def release_state_transfer_changelog_header
        total = results.filter_map do |result|
          value = (result.state || {}).fetch("transfer_changelog_total", nil)
          value unless value.to_s.empty?
        end.first
        "T(#{total || "?"})"
      end

      def release_state_transfer_changelog_value(state)
        missing = state.fetch("transfer_changelog_lag", 0).to_i
        applicable = state.fetch("transfer_changelog_applicable", nil)
        return missing.to_s if applicable.nil?

        excluded_present = state.fetch("transfer_changelog_excluded_present", 0).to_i
        value = "#{missing} / #{applicable.to_i}"
        excluded_present.positive? ? "#{value} (x#{excluded_present})" : value
      end

      def release_state_github_release(state)
        github_release = state.fetch("github_latest_release", nil).to_s
        return "unknown" if github_release.empty?

        latest_released = state.fetch("latest_released", nil).to_s
        return github_release if latest_released.empty? || latest_released == "unknown"

        release_state_release_versions_match?(latest_released, github_release) ? github_release : "🔴 #{github_release}"
      end

      def release_state_release_versions_match?(latest_released, github_release)
        latest_released.to_s.delete_prefix("v") == github_release.to_s.delete_prefix("v")
      end

      def release_state_checkout(state)
        branch = state.fetch("current_branch", nil).to_s
        branch.empty? ? "unknown" : branch[0, 10]
      end

      def release_state_ahead_behind(state)
        local_ahead = state.fetch("ahead", nil)
        local_behind = state.fetch("behind", nil)
        return "unknown" if local_ahead.nil? && local_behind.nil?

        "#{release_state_count(local_ahead, state.fetch("remote_ahead", nil))} / #{release_state_count(local_behind, state.fetch("remote_behind", nil))}"
      end

      def release_state_count(local_value, remote_value)
        local_text = local_value.nil? ? "unknown" : local_value.to_s
        return local_text if remote_value.nil? || remote_value == local_value

        "#{local_text} (#{remote_value})"
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
        resume_hints.first
      end

      def resume_hints
        return [] if success?
        return non_release_resume_hints unless command == "release"

        release_resume_hints
      end

      def non_release_resume_hints
        failed = results.find { |result| !result.ok? }
        failed ? [resume_hint_for(failed)] : []
      end

      def release_resume_hints
        failed_hints = visible_results.reject(&:ok?).filter_map { |result| resume_hint_for(result) }.uniq
        pending_names = summary_pending.map { |entry| entry.fetch("member") }
        return failed_hints if pending_names.empty?

        [*failed_hints, release_resume_hint_for_pending(pending_names)]
      end

      def resume_hint_for(result)
        return release_resume_hint(result) if command == "release"

        "kettle-family #{command} --start-at #{result.member_name}"
      end

      def release_resume_hint(result)
        return result.resume_command if result.respond_to?(:resume_command) && !result.resume_command.to_s.empty?
        return nil if result.phase == "aggregate_github_release"

        hint = release_resume_base
        hint = "#{hint} --only #{result.member_name}" if result.member_name
        hint = "#{hint} --start-step #{result.resume_step}" if result.respond_to?(:resume_step) && result.resume_step
        hint
      end

      def release_resume_hint_for_pending(member_names)
        "#{release_resume_base} --only #{member_names.join(",")}"
      end

      def release_resume_base
        arguments = ["kettle-family", "release", "--execute"]
        arguments << "--publish" if release_mode == "publish"
        shell_join([*arguments, *release_resume_arguments])
      end

      def shell_join(arguments)
        arguments.map do |argument|
          value = argument.to_s
          value.match?(/\A[A-Za-z0-9_.,:=+\/-]+\z/) ? value : Shellwords.escape(value)
        end.join(" ")
      end
    end
  end
end
