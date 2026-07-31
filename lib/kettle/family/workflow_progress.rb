# frozen_string_literal: true

require "tty-progressbar"
require "tty-screen"

module Kettle
  module Family
    class WorkflowProgress
      MEMBER_WIDTH = 24
      PROGRESS_WIDTH = 7
      ELAPSED_WIDTH = 7
      FORMAT = "%<member>-#{MEMBER_WIDTH}.#{MEMBER_WIDTH}s :progress :duration :events :status"
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
        @bars = {}
        @line_order = members.map(&:name)
        @started = false
        @stopped = false
        @member_totals = {}
        @member_counts = Hash.new(0)
        @member_started_at = {}
        @member_finished_elapsed = {}
        @member_events = Hash.new("")
        @member_statuses = Hash.new("")
        @mutex = Mutex.new
        @tty = @enabled && io.respond_to?(:tty?) && io.tty?
        @multibar = @tty ? TTY::ProgressBar::Multi.new(output: io, frequency: 0) : nil
      end

      def start
        return unless @enabled

        synchronize do
          next if @started

          write_line(@heading || "#{@label} #{@total} member#{plural(@total)} with #{@jobs} job#{plural(@jobs)}:")
          @started = true
          @line_order.each { |member_name| render_name(member_name, status: "") } if @tty
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

          @multibar&.stop
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

      private

      def render(member, status:)
        render_name(member.name, status: status)
      end

      def append_event(member, mark)
        return if mark.to_s.empty?

        @member_events[member.name] = (@member_events[member.name] + mark.to_s).chars.last(EVENT_WIDTH).join
      end

      def render_name(member_name, status:)
        @member_statuses[member_name] = truncate_status(status)
        @line_order << member_name unless @line_order.include?(member_name)
        bar_for(member_name).advance(
          0,
          progress: progress_text(member_name),
          duration: elapsed_text(member_name),
          events: @member_events[member_name].rjust(EVENT_WIDTH),
          status: @member_statuses[member_name]
        )
      end

      def bar_for(member_name)
        @bars[member_name] ||= @multibar.register(Kernel.format(FORMAT, member: member_name), total: nil)
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
        return normalized if normalized.length <= width
        return normalized[0, width] if width <= ELLIPSIS.length

        "#{normalized[0, width - ELLIPSIS.length]}#{ELLIPSIS}"
      end

      def status_width
        [terminal_width - MEMBER_WIDTH - 1 - PROGRESS_WIDTH - 1 - ELAPSED_WIDTH - 1 - EVENT_WIDTH - 1, MIN_STATUS_WIDTH].max
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
