# frozen_string_literal: true

module Kettle
  module Family
    class Selection
      STATUS_TOKEN_KEYS = {
        "unreleased" => "unreleased_entries",
        "prepared" => "prepared_release_pending",
        "pending" => "pending_release",
        "bump" => "bump_release_pending"
      }.freeze

      def self.status_tokens
        STATUS_TOKEN_KEYS.keys
      end

      def self.status_token?(value)
        STATUS_TOKEN_KEYS.key?(value.to_s)
      end

      def initialize(members:, release_state_results: nil)
        @members = members
        @release_state_results = release_state_results
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

      attr_reader :members, :release_state_results

      def select_only(selected, only)
        names = only.split(",").map(&:strip).reject(&:empty?)
        raise Error, "--only requires at least one member" if names.empty?

        status_tokens = names.select { |name| self.class.status_token?(name) }
        unless status_tokens.empty?
          member_names = names - status_tokens
          raise Error, "--only release-state tokens cannot be combined with member names: #{member_names.join(", ")}" unless member_names.empty?

          return select_release_state_status(selected, status_tokens)
        end

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

      def select_release_state_status(selected, status_tokens)
        results_by_member = release_state_results_by_member
        failed = results_by_member.values.select { |result| !result.ok? }
        raise Error, "release-state check failed for: #{failed.map(&:member_name).join(", ")}" unless failed.empty?

        selected.select do |candidate|
          result = results_by_member[candidate.name]
          result && status_tokens.all? { |token| truthy_state?(result.state[STATUS_TOKEN_KEYS.fetch(token)]) }
        end
      end

      def release_state_results_by_member
        raise Error, "--only release-state tokens require release-state results" unless release_state_results

        release_state_results.each_with_object({}) do |result, memo|
          memo[result.member_name] = result
        end
      end

      def truthy_state?(value)
        value == true
      end
    end
  end
end
