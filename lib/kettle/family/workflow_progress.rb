# frozen_string_literal: true

require "tty-progressbar"

module Kettle
  module Family
    class WorkflowProgress
      FORMAT = "%<member>-24s :events :status"
      EVENT_WIDTH = 30

      def initialize(io:, label:, total:, jobs:, enabled: true)
        @io = io
        @label = label
        @total = total.to_i
        @jobs = jobs.to_i
        @enabled = enabled && !!io
        @bars = {}
        @member_totals = {}
        @member_events = Hash.new("")
        @mutex = Mutex.new
        @tty = @enabled && io.respond_to?(:tty?) && io.tty?
        @multibar = @tty ? TTY::ProgressBar::Multi.new(output: io) : nil
      end

      def start
        return unless @enabled

        write_line("#{@label} #{@total} member#{plural(@total)} with #{@jobs} job#{plural(@jobs)}:")
      end

      def start_member(member, total:, status:)
        return unless @enabled

        synchronize do
          @member_totals[member.name] = total.to_i
          if @tty
            render(member, status: status)
          else
            write_line("[#{member.name}] > #{status}")
          end
        end
      end

      def advance(member, status:, success: true, mark: nil)
        return unless @enabled

        synchronize do
          event_mark = mark || (success ? "." : "F")
          if @tty
            append_event(member, event_mark)
            render(member, status: status)
          else
            write_line("[#{member.name}] #{event_mark} #{status}")
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
            write_line("[#{member.name}] #{mark || ">"} #{status}")
          end
        end
      end

      def finish_member(member, success:, status:)
        return unless @enabled

        synchronize do
          if @tty
            render(member, status: status)
          else
            write_line("[#{member.name}] #{success ? "done" : "failed"} #{status}")
          end
        end
      end

      def stop
        return unless @enabled

        synchronize { @multibar&.stop }
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
        bar_for(member).advance(0, events: event_tape(member), status: status)
      end

      def append_event(member, mark)
        return if mark.to_s.empty?

        @member_events[member.name] = (@member_events[member.name] + mark.to_s).chars.last(EVENT_WIDTH).join
      end

      def event_tape(member)
        @member_events[member.name].rjust(EVENT_WIDTH)
      end

      def bar_for(member)
        @bars[member.name] ||= @multibar.register(Kernel.format(FORMAT, member: member.name), total: nil)
      end

      def plural(count)
        "s" unless count == 1
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
