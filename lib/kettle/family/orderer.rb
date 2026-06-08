# frozen_string_literal: true

require "tsort"

module Kettle
  module Family
    class Orderer
      include TSort

      def initialize(members:, mode: "dependency", hints: [])
        @members = members
        @mode = mode
        @hints = hints
        @by_name = members.to_h { |member| [member.name, member] }
      end

      def ordered
        case mode
        when "dependency"
          tsort
        when "fixed"
          fixed_order
        else
          raise Error, "unknown order mode #{mode.inspect}"
        end
      rescue TSort::Cyclic => error
        raise Error, "dependency cycle detected: #{error.message}"
      end

      private

      attr_reader :members, :mode, :hints, :by_name

      def tsort_each_node(&block)
        hinted_members.each(&block)
      end

      def tsort_each_child(member, &block)
        member.dependencies
          .filter_map { |dependency| by_name[dependency] }
          .sort_by(&:name)
          .each(&block)
      end

      def hinted_members
        hinted = hints.filter_map { |name| by_name[name] }
        remaining = members.reject { |member| hints.include?(member.name) }.sort_by(&:name)
        hinted + remaining
      end

      def fixed_order
        unknown = hints - by_name.keys
        raise Error, "fixed order references unknown members: #{unknown.join(", ")}" if unknown.any?

        ordered_names = hints + (by_name.keys.sort - hints)
        ordered_names.map { |name| by_name.fetch(name) }
      end
    end
  end
end
