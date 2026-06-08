# frozen_string_literal: true

module Kettle
  module Family
    class BranchLaneAudit
      REQUIRED_KEYS = %w[branch version members].freeze

      def initialize(config:, members:)
        @config = config
        @members = members
        @member_names = members.map(&:name)
      end

      def results
        lanes = config.branch_lanes
        return [missing_lanes_result] if lanes.empty?

        lanes.map do |name, lane|
          audit_lane(name.to_s, stringify_keys(lane))
        end
      end

      private

      attr_reader :config, :members, :member_names

      def missing_lanes_result
        result("branch_lanes", ["no branch lanes configured"])
      end

      def audit_lane(name, lane)
        diagnostics = []
        REQUIRED_KEYS.each do |key|
          diagnostics << "lane #{name} missing #{key}" unless lane.key?(key)
        end
        diagnostics.concat(unknown_members(name, lane.fetch("members", [])))
        result(name, diagnostics)
      end

      def unknown_members(name, configured_members)
        configured_members.reject { |member| member_names.include?(member) }.map do |member|
          "lane #{name} references unknown member #{member}"
        end
      end

      def result(name, diagnostics)
        CommandResult.new(
          member_name: name,
          phase: "branch_lane_audit",
          command: ["internal", "branch-lanes"],
          workdir: config.root,
          status: diagnostics.empty? ? 0 : 1,
          success: diagnostics.empty?,
          stdout: diagnostics.join("\n"),
          stderr: "",
          elapsed_seconds: 0.0,
          skipped: false,
          reason: diagnostics.empty? ? nil : "branch lane audit failed"
        )
      end

      def stringify_keys(value)
        case value
        when Hash
          value.to_h { |key, item| [key.to_s, stringify_keys(item)] }
        when Array
          value.map { |item| stringify_keys(item) }
        else
          value
        end
      end
    end
  end
end
