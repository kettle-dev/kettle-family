# frozen_string_literal: true

module Kettle
  module Family
    class Selection
      def initialize(members:)
        @members = members
      end

      def apply(only: nil, start_at: nil)
        selected = members
        selected = select_only(selected, only) if only
        selected = select_start_at(selected, start_at) if start_at
        raise Error, "selection is empty" if selected.empty?

        selected
      end

      private

      attr_reader :members

      def select_only(selected, only)
        member = selected.find { |candidate| candidate.name == only }
        raise Error, "unknown member #{only.inspect}" unless member

        [member]
      end

      def select_start_at(selected, start_at)
        index = selected.index { |candidate| candidate.name == start_at }
        raise Error, "unknown member #{start_at.inspect}" unless index

        selected.drop(index)
      end
    end
  end
end
