# frozen_string_literal: true

module Kettle
  module Family
    class Selection
      STATUS_TOKEN_KEYS = {
        "unreleased" => "unreleased_entries",
        "unrel" => "unreleased_entries",
        "prepared" => "prepared_release_pending",
        "prep" => "prepared_release_pending",
        "pending" => "pending_release",
        "pend" => "pending_release",
        "bump" => "bump_release_pending"
      }.freeze

      # Commands whose member dispatch is not positional, so `--start-at` cannot
      # express "the members that still need work" for them.
      #
      # template groups members into dependency waves derived from gemspec
      # dependencies and test uses a concurrent work queue. In both, a failure only
      # sets a stop flag that prevents threads from popping further work: members
      # already in flight finish while later waves never run. The pending set is
      # therefore interleaved through the configured order rather than being a
      # suffix of it, so no --start-at value selects exactly that set.
      #
      # Measured on the kettle-dev family: nomono failed in template wave 1 and
      # left kettle-dev, kettle-changelog, kettle-family and kettle-soup-cover
      # pending at ordered positions 6, 8, 9 and 11, while kettle-drift at 7 and
      # kettle-wash at 10 had already succeeded. The pending positions were
      # [5, 7, 8, 10] against a required suffix of [9, 10, 11, 12].
      #
      # These commands ignore the configured `release.waves`, which only feed
      # display_members_for and so only affect release ordering.
      NON_POSITIONAL_DISPATCH_COMMANDS = %w[template test].freeze

      def self.non_positional_dispatch?(command)
        NON_POSITIONAL_DISPATCH_COMMANDS.include?(command)
      end

      # Rejects `--start-at` for commands whose dispatch is not positional, rather
      # than letting it silently drop members. Mirrors the class-method validation
      # convention used by validate_release_state_only_filter! so callers in the CLI
      # do not have to know which commands are affected.
      def self.validate_positional_start_at!(command, start_at)
        return if start_at.nil? || start_at.to_s.empty?
        return unless non_positional_dispatch?(command)

        raise Error, "--start-at is not supported for #{command}: members are dispatched in dependency " \
                     "waves, so a positional resume would silently skip members that never ran. " \
                     "Use --only #{start_at} (or the resume hint from the previous report) instead."
      end

      def self.status_tokens
        STATUS_TOKEN_KEYS.keys
      end

      def self.status_token?(value)
        STATUS_TOKEN_KEYS.key?(value.to_s)
      end

      # Defined as a singleton method above the `private` keyword: a `private`
      # instance modifier does not apply to `def self.` definitions.
      #
      # Branches of one member that currently satisfy +tokens+. Used to decide
      # per-branch bump work, so a bump never touches a branch that has nothing
      # to release.
      def self.branches_matching(release_state_results, member_name:, tokens:)
        keys = Array(tokens).map(&:to_s).filter_map { |token| STATUS_TOKEN_KEYS[token] }
        return [] if keys.empty?

        Array(release_state_results).select do |result|
          result.member_name == member_name && keys.all? { |key| result.state[key] == true }
        end.map(&:branch).compact.uniq
      end

      def self.validate_release_state_only_filter!(only)
        names = only.to_s.split(",").map(&:strip).reject(&:empty?)
        status_tokens = names.select { |name| status_token?(name) }
        return if status_tokens.empty?

        member_names = names - status_tokens
        raise Error, "--only release-state tokens cannot be combined with member names: #{member_names.join(", ")}" unless member_names.empty?
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
          self.class.validate_release_state_only_filter!(only)

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

      # A branch-stack member yields one release-state result per branch, all
      # sharing a member_name. Collapsing them by member_name alone would let
      # whichever branch came last decide selection for every branch, so a
      # member qualifies when *any* of its branches matches the token.
      def select_release_state_status(selected, status_tokens)
        results_by_member = release_state_results_by_member
        failed = results_by_member.values.flatten.select { |result| !result.ok? }
        raise Error, "release-state check failed for: #{failed.map(&:member_name).uniq.join(", ")}" unless failed.empty?

        selected.select do |candidate|
          Array(results_by_member[candidate.name]).any? do |result|
            status_tokens.all? { |token| truthy_state?(result.state[STATUS_TOKEN_KEYS.fetch(token)]) }
          end
        end
      end

      # Branch-stack members report one result per branch, all sharing a member
      # name, so results are grouped per member instead of collapsed to one.
      def release_state_results_by_member
        raise Error, "--only release-state tokens require release-state results" unless release_state_results

        release_state_results.each_with_object({}) do |result, memo|
          (memo[result.member_name] ||= []) << result
        end
      end

      def truthy_state?(value)
        value == true
      end
    end
  end
end
