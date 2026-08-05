# frozen_string_literal: true

require "fileutils"
require "json"
require "time"

module Kettle
  module Family
    class ReleaseStateEventTape
      attr_reader :directory

      def initialize(root:, stream: nil, clock: nil, wall_clock: nil)
        @directory = File.join(root, "tmp", "kettle-family", "release-state-#{Time.now.strftime("%Y%m%d-%H%M%S")}-#{Process.pid}")
        FileUtils.mkdir_p(@directory)
        @stream = stream
        @clock = clock || lambda { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
        @wall_clock = wall_clock || lambda { Time.now.utc.iso8601 }
        @started_at = @clock.call
        @sequence_by_member = Hash.new(0)
        @mutex = Mutex.new
      end

      def call(event)
        payload = event.merge(
          "event_version" => 1,
          "type" => "release_state",
          "timestamp" => @wall_clock.call,
          "elapsed_seconds" => @clock.call - @started_at
        )
        member = payload.fetch("member", "family").to_s
        @mutex.synchronize do
          @sequence_by_member[member] += 1
          payload["sequence"] = @sequence_by_member.fetch(member)
          line = JSON.generate(payload)
          File.open(path_for(member), "a") { |file| file.puts(line) }
          @stream&.puts(line)
          @stream.flush if @stream&.respond_to?(:flush)
        end
        payload
      rescue
        nil
      end

      private

      def path_for(member)
        filename = member.gsub(/[^A-Za-z0-9_.-]+/, "_")
        File.join(@directory, "#{filename}.ndjson")
      end
    end
  end
end
