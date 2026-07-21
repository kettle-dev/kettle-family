# frozen_string_literal: true

module Kettle
  module Family
    class ReleaseWaves
      def initialize(members:)
        @members = members
      end

      def waves
        by_name = members.to_h { |member| [member.name, member] }
        pending = by_name.keys
        completed = []
        [].tap do |planned_waves|
          until pending.empty?
            hard_ready = pending.select do |name|
              selected_hard_dependencies_for(by_name.fetch(name), by_name).all? { |dependency| completed.include?(dependency) }
            end
            raise Error, "cyclic release dependency order: #{pending.join(", ")}" if hard_ready.empty?

            wave_names = hard_ready.select do |name|
              selected_dependencies_for(by_name.fetch(name), by_name).all? { |dependency| completed.include?(dependency) }
            end
            wave_names = [hard_ready.first] if wave_names.empty?

            planned_waves << wave_names.map { |name| by_name.fetch(name) }
            completed.concat(wave_names)
            pending -= wave_names
          end
        end
      end

      private

      attr_reader :members

      def selected_hard_dependencies_for(member, by_name)
        Array(member.dependencies).map(&:to_s).select { |dependency| by_name.key?(dependency) }
      end

      def selected_dependencies_for(member, by_name)
        release_dependency_names(member).select { |dependency| by_name.key?(dependency) }
      end

      def release_dependency_names(member)
        Array(member.release_dependencies || member.dependencies).map(&:to_s)
      end
    end
  end
end
