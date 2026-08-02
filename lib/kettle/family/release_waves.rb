# frozen_string_literal: true

module Kettle
  module Family
    class ReleaseWaves
      def initialize(members:, configured_waves: [])
        @members = members
        @configured_waves = configured_waves
      end

      def waves
        configured = configured_waves_for_selected_members
        configured_names = configured.flatten.map(&:name)
        remaining_members = members.reject { |member| configured_names.include?(member.name) }

        configured + inferred_waves(remaining_members)
      end

      private

      attr_reader :members, :configured_waves

      def configured_waves_for_selected_members
        duplicates = configured_waves.flatten.group_by(&:itself).select { |_name, names| names.length > 1 }.keys
        raise Error, "release waves contain duplicate member(s): #{duplicates.join(", ")}" unless duplicates.empty?

        selected_names = members.map(&:name)
        selected_members = members.to_h { |member| [member.name, member] }
        # Configured waves commonly name the complete family while --only selects
        # a subset. Ignore entries outside the current selection.
        return [] if configured_waves.empty?

        configured_waves.filter_map do |wave|
          names = wave & selected_names
          names.map { |name| selected_members.fetch(name) } unless names.empty?
        end
      end

      def inferred_waves(candidate_members)
        return [] if candidate_members.empty?

        by_name = candidate_members.to_h { |member| [member.name, member] }
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
