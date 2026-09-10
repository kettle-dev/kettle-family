# frozen_string_literal: true

require "json"

module Kettle
  module Family
    # Immutable release dependency graph selected for one member or branch
    # target. It is passed to kettle-dev as data, never reconstructed from
    # whichever *_DEV variables happened to launch the family command.
    class ReleaseGraph
      ENV_KEY = "KETTLE_RELEASE_GRAPH_CONTRACT_JSON"
      NAMES = %w[registry_only wave_transition monorepo_ci_local branch_terminal].freeze

      attr_reader :name, :ci_root, :local_path_roots, :selector_env

      def initialize(name:, ci_root: nil, local_path_roots: [], selector_env: {})
        @name = name.to_s
        @ci_root = canonical_path(ci_root) if ci_root
        @local_path_roots = Array(local_path_roots).map { |path| canonical_path(path) }.uniq.freeze
        @selector_env = selector_env.to_h.transform_keys(&:to_s).transform_values(&:to_s).freeze
        validate!
        freeze
      end

      def registry_only?
        name == "registry_only" || name == "branch_terminal"
      end

      def local_paths?
        !local_path_roots.empty?
      end

      def environment
        selector_env.merge(ENV_KEY => JSON.generate(to_h))
      end

      def to_h
        {
          "name" => name,
          "ci_root" => ci_root,
          "local_path_roots" => local_path_roots,
          "selector_env" => selector_env
        }
      end

      private

      def validate!
        raise Error, "unknown release graph contract #{name.inspect}" unless NAMES.include?(name)

        if registry_only? && (local_paths? || !selector_env.empty?)
          raise Error, "#{name} release graph cannot declare local paths or selectors"
        end
        return unless %w[wave_transition monorepo_ci_local].include?(name)

        raise Error, "#{name} release graph requires at least one local path root" unless local_paths?
        raise Error, "#{name} release graph requires a local path selector" if selector_env.empty?

        selector_env.each_value do |value|
          next if local_path_roots.any? { |root| value == root || value.start_with?("#{root}/") }

          raise Error, "#{name} selector #{value.inspect} is outside its declared local path roots"
        end

        return unless name == "monorepo_ci_local"

        raise Error, "monorepo_ci_local release graph requires a CI root" if ci_root.to_s.empty?
        local_path_roots.each do |path|
          next if path == ci_root || path.start_with?("#{ci_root}/")

          raise Error, "monorepo_ci_local path #{path.inspect} is outside CI root #{ci_root.inspect}"
        end
      end

      def canonical_path(path)
        expanded = File.expand_path(path)
        File.realpath(expanded)
      rescue Errno::ENOENT
        expanded
      end
    end
  end
end
