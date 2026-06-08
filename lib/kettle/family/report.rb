# frozen_string_literal: true

require "json"

module Kettle
  module Family
    class Report
      attr_reader :family_name, :order_mode, :members, :selected_members, :config_path

      def initialize(family_name:, order_mode:, members:, selected_members:, config_path:)
        @family_name = family_name
        @order_mode = order_mode
        @members = members
        @selected_members = selected_members
        @config_path = config_path
      end

      def to_h
        {
          "family" => family_name,
          "config_path" => config_path,
          "order_mode" => order_mode,
          "members" => members.map(&:to_h),
          "selected_members" => selected_members.map(&:name)
        }
      end

      def to_json(*args)
        JSON.pretty_generate(to_h, *args)
      end

      def to_text
        lines = ["family: #{family_name}"]
        lines << "config: #{config_path || "none"}"
        lines << "order: #{order_mode}"
        lines << "members:"
        selected_names = selected_members.map(&:name)
        members.each do |member|
          marker = selected_names.include?(member.name) ? "*" : "-"
          lines << "  #{marker} #{member.name} #{member.version} #{member.root}"
        end
        lines.join("\n")
      end
    end
  end
end
