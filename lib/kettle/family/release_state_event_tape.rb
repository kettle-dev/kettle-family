# frozen_string_literal: true

require "fileutils"
require "time"
require "kettle/ndjson"

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
        # Preserve the origin event type when taping relayed child events
        # (command_step, github_release, ...); emit our own type only for
        # family-level state events that arrive without one.
        payload = event.merge(
          "event_version" => 1,
          "timestamp" => @wall_clock.call,
          "elapsed_seconds" => @clock.call - @started_at
        )
        payload["type"] = "release_state" if payload["type"].to_s.empty?
        target = target_key(payload)
        @mutex.synchronize do
          @sequence_by_member[target] += 1
          payload["sequence"] = @sequence_by_member.fetch(target)
          File.open(path_for(target), "a") { |file| emit_ndjson(file, payload) }
          emit_ndjson(@stream, payload) if @stream
        end
        payload
      rescue
        nil
      end

      private

      def emit_ndjson(io, payload)
        type = payload.fetch("type").to_s
        stream = Kettle::Ndjson.event_stream(io, types: type, event_types: [type], aliases: {})
        attributes = payload.each_with_object({}) do |(key, value), result|
          next if %w[type event_version].include?(key.to_s)

          result[key.to_sym] = value
        end
        Kettle::Ndjson.emit_event(stream, type, attributes)
      end

      def target_key(payload)
        member = payload.fetch("member", "family").to_s
        branch = payload["branch"].to_s
        branch.empty? ? member : "#{member}@#{branch}"
      end

      def path_for(target)
        filename = target.gsub(/[^A-Za-z0-9_.-]+/, "_")
        File.join(@directory, "#{filename}.ndjson")
      end
    end
  end
end
