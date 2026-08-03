# frozen_string_literal: true

require "tty-screen"
require "unicode/display_width"

module Kettle
  module Family
    class WorkflowProgress
      MEMBER_WIDTH = 24
      PROGRESS_WIDTH = 7
      ELAPSED_WIDTH = 7
      FORMAT = "%<member>-#{MEMBER_WIDTH}.#{MEMBER_WIDTH}s %<progress>s %<duration>s %<events>s %<status>s"
      EVENT_WIDTH = 20
      MIN_STATUS_WIDTH = 12
      DEFAULT_TERMINAL_WIDTH = 80
      ELLIPSIS = "..."

      def initialize(io:, label:, total:, jobs:, members: [], enabled: true, clock: nil, heading: nil)
        @io = io
        @label = label
        @total = total.to_i
        @jobs = jobs.to_i
        @heading = heading
        @clock = clock || lambda { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
        @enabled = enabled && !!io
        @line_order = members.map(&:name)
        @started = false
        @stopped = false
        @member_totals = {}
        @member_counts = Hash.new(0)
        @member_started_at = {}
        @member_finished_elapsed = {}
        @member_events = Hash.new("")
        @member_statuses = Hash.new("")
        @notification = ""
        @mutex = Mutex.new
        @tty = @enabled && io.respond_to?(:tty?) && io.tty?
        @tty_rendered = false
        @tty_block_rows = 0
        @tty_tape_rows = 0
      end

      def start
        return unless @enabled

        synchronize do
          next if @started

          write_line(@heading || "#{@label} #{@total} member#{plural(@total)} with #{@jobs} job#{plural(@jobs)}:")
          @started = true
          if @tty
            @line_order.each { |member_name| render_name(member_name, status: "") }
            render_tty_block unless @line_order.empty?
          end
        end
      end

      def start_member(member, total:, status:)
        return unless @enabled

        synchronize do
          @member_totals[member.name] = total.to_i
          @member_counts[member.name] = 0
          @member_started_at[member.name] ||= monotonic_now
          @member_finished_elapsed.delete(member.name)
          if @tty
            render(member, status: status)
          else
            write_line(non_tty_line(member, mark: ">", status: status))
          end
        end
      end

      def advance(member, status:, success: true, mark: nil)
        return unless @enabled

        synchronize do
          event_mark = mark || (success ? "." : "F")
          increment_member_count(member)
          if @tty
            append_event(member, event_mark)
            render(member, status: status)
          else
            write_line(non_tty_line(member, mark: event_mark, status: status))
          end
        end
      end

      def update(member, status:, mark: nil)
        return unless @enabled
        return if status.to_s.empty?

        synchronize do
          if @tty
            append_event(member, mark) if mark
            render(member, status: status)
          else
            write_line(non_tty_line(member, mark: mark || ">", status: status))
          end
        end
      end

      def finish_member(member, success:, status:)
        return unless @enabled

        synchronize do
          @member_finished_elapsed[member.name] = elapsed_seconds(member)
          if @tty
            render(member, status: status)
          else
            write_line(non_tty_line(member, mark: success ? "done" : "failed", status: status))
          end
        end
      end

      def stop
        return unless @enabled

        synchronize do
          next if @stopped

          @stopped = true
        end
      end

      def tty?
        @tty
      end

      def summary(message)
        return unless @enabled

        synchronize do
          @io.puts unless @tty
          write_line(message)
        end
      end

      def notification(message)
        return unless @enabled

        synchronize do
          @notification = message.to_s
          if @tty
            render_tty_block if @started && !@line_order.empty?
          elsif !@notification.empty?
            write_line("[notification] #{@notification}")
          end
        end
      end

      private

      def render(member, status:)
        render_name(member.name, status: status)
        render_tty_block if @tty
      end

      def append_event(member, mark)
        return if mark.to_s.empty?

        @member_events[member.name] = (@member_events[member.name] + mark.to_s).chars.last(EVENT_WIDTH).join
      end

      def render_name(member_name, status:)
        @member_statuses[member_name] = truncate_status(status)
        @line_order << member_name unless @line_order.include?(member_name)
      end

      # Redraw the complete block from a stable cursor position. TTY::ProgressBar::Multi
      # saves and restores the cursor independently for each bar, which is unreliable
      # across terminals that do not implement its legacy ESC 7/ESC 8 sequences.
      def render_tty_block
        rows = @line_order.map { |member_name| tty_line(member_name) }
        return if rows.empty?

        output = +""
        if @tty_rendered && @tty_block_rows.positive?
          # Restore the bottom-of-block cursor before moving to the first row.
          # This keeps unrelated prompt output from changing the redraw anchor.
          output << "\e[u\e[#{@tty_block_rows}A"
        end
        # The notification line is deliberately separate from the event tape.
        # It is transient operator guidance, not a member row or an event.
        output << render_tty_notification_line
        output << render_tty_tape_rows(rows)
        # LF moves down without necessarily returning to column 1. Reset the
        # anchor explicitly so external prompt output starts on a fresh line.
        output << "\e[1G\e[s"
        @io.write(output)
        @io.flush if @io.respond_to?(:flush)
        @tty_rendered = true
        @tty_tape_rows = rows.length
        @tty_block_rows = @tty_tape_rows + 1
      end

      def render_tty_notification_line
        "\e[1G\e[2K#{truncate_display(@notification, render_width)}\n"
      end

      def render_tty_tape_rows(rows)
        rows.map { |line| "\e[1G\e[2K#{line}\n" }.join
      end

      def tty_line(member_name)
        Kernel.format(
          FORMAT,
          member: member_name,
          progress: progress_text(member_name),
          duration: elapsed_text(member_name),
          events: @member_events[member_name].rjust(EVENT_WIDTH),
          status: @member_statuses[member_name]
        )
      end

      def plural(count)
        "s" unless count == 1
      end

      def non_tty_line(member, mark:, status:)
        "[#{member.name}] #{progress_text(member.name)} #{elapsed_text(member.name)} #{mark} #{status}"
      end

      def increment_member_count(member)
        member_name = member.name
        total = @member_totals[member_name].to_i
        @member_counts[member_name] += 1
        @member_counts[member_name] = total if total.positive? && @member_counts[member_name] > total
      end

      def progress_text(member_name)
        count = @member_counts[member_name].to_i
        total = @member_totals[member_name].to_i
        denominator = total.positive? ? total.to_s : "*"
        "(#{count}/#{denominator})".rjust(PROGRESS_WIDTH)
      end

      def elapsed_text(member_name)
        format_elapsed(elapsed_seconds_by_name(member_name)).rjust(ELAPSED_WIDTH)
      end

      def elapsed_seconds(member)
        elapsed_seconds_by_name(member.name)
      end

      def elapsed_seconds_by_name(member_name)
        return @member_finished_elapsed[member_name] if @member_finished_elapsed.key?(member_name)

        started_at = @member_started_at[member_name] || monotonic_now
        [monotonic_now - started_at, 0].max
      end

      def format_elapsed(seconds)
        total_seconds = seconds.to_i
        hours = total_seconds / 3600
        minutes = (total_seconds % 3600) / 60
        remaining_seconds = total_seconds % 60
        return Kernel.format("%d:%02d:%02d", hours, minutes, remaining_seconds) if hours.positive?

        Kernel.format("%02d:%02d", minutes, remaining_seconds)
      end

      def monotonic_now
        @clock.call.to_f
      end

      def truncate_status(status)
        normalized = status.to_s.gsub(/\s+/, " ").strip
        width = status_width
        truncated = truncate_display(normalized, width)
        truncated + (" " * [width - display_width(truncated), 0].max)
      end

      def truncate_display(value, width)
        return "" if width <= 0

        normalized = value.to_s
        return normalized if display_width(normalized) <= width
        return take_display_width(ELLIPSIS, width) if width <= display_width(ELLIPSIS)

        "#{take_display_width(normalized, width - display_width(ELLIPSIS))}#{ELLIPSIS}"
      end

      def take_display_width(value, width)
        value.to_s.each_char.each_with_object(+"") do |character, result|
          candidate = result + character
          break result if display_width(candidate) > width

          result << character
        end
      end

      def display_width(value)
        Unicode::DisplayWidth.of(value.to_s)
      end

      def status_width
        available = [render_width - MEMBER_WIDTH - 1 - PROGRESS_WIDTH - 1 - ELAPSED_WIDTH - 1 - EVENT_WIDTH - 1, 1].max
        [available, MIN_STATUS_WIDTH].max.clamp(1, available)
      end

      def render_width
        # Leave the last terminal column unused. Writing into it can trigger
        # an automatic wrap before the explicit newline, which invalidates the
        # fixed physical-row cursor accounting used by the redrawer.
        [terminal_width - 1, 1].max
      end

      def terminal_width
        return DEFAULT_TERMINAL_WIDTH unless @tty

        TTY::Screen.width.to_i
      rescue
        DEFAULT_TERMINAL_WIDTH
      end

      def write_line(line)
        @io.puts(line)
        @io.flush if @io.respond_to?(:flush)
      end

      def synchronize(&block)
        @mutex.synchronize(&block)
      end
    end
  end
end
