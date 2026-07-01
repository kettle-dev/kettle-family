# frozen_string_literal: true

module Kettle
  module Family
    class Selection
      def initialize(members:)
        @members = members
      end

      def apply(only: nil, exclude: nil, start_at: nil)
        selected = members
        selected = select_only(selected, only) if only
        selected = select_exclude(selected, exclude) if exclude
        selected = select_start_at(selected, start_at) if start_at
        raise Error, "selection is empty" if selected.empty?

        selected
      end

      private

      attr_reader :members

      def select_only(selected, only)
        names = only.split(",").map(&:strip).reject(&:empty?)
        raise Error, "--only requires at least one member" if names.empty?

        unknown = names - members.map(&:name)
        raise Error, "unknown member(s): #{unknown.join(", ")}" unless unknown.empty?

        selected.select { |candidate| names.include?(candidate.name) }
      end

      def select_exclude(selected, exclude)
        names = exclude.split(",").map(&:strip).reject(&:empty?)
        raise Error, "--exclude requires at least one member" if names.empty?

        unknown = names - members.map(&:name)
        raise Error, "unknown member(s): #{unknown.join(", ")}" unless unknown.empty?

        selected.reject { |candidate| names.include?(candidate.name) }
      end

      def select_start_at(selected, start_at)
        index = selected.index { |candidate| candidate.name == start_at }
        raise Error, "unknown member #{start_at.inspect}" unless index

        selected.drop(index)
      end
    end
  end
end
