# frozen_string_literal: true

require "yaml"

module Kettle
  module Family
    class Config
      DEFAULT_PATHS = [".kettle-family.yml", ".structuredmerge/kettle-family.yml"].freeze

      attr_reader :data, :path, :root

      def self.load(root:, path: nil)
        expanded_root = File.expand_path(root)
        config_path = path && File.expand_path(path, expanded_root)
        config_path ||= DEFAULT_PATHS
          .map { |candidate| File.join(expanded_root, candidate) }
          .find { |candidate| File.file?(candidate) }

        data = config_path ? YAML.load_file(config_path) : {}
        new(root: expanded_root, path: config_path, data: data || {})
      end

      def initialize(root:, path:, data:)
        @root = root
        @path = path
        @data = stringify_keys(data)
      end

      def family_name
        fetch_path("family", "name") || File.basename(root)
      end

      def family_mode
        fetch_path("family", "mode") || "monorepo"
      end

      def members_root
        configured = fetch_path("family", "members_root") || fetch_path("members", "root")
        configured ? File.expand_path(configured, root) : root
      end

      def member_roots
        configured = fetch_path("members", "roots")
        return configured.map { |path| File.expand_path(path, root) } if configured
        return sibling_member_roots if family_mode == "sibling_repos"

        [members_root]
      end

      def explicit_members
        members = data.fetch("members", {})
        explicit = members.fetch("explicit", [])
        explicit.map do |entry|
          entry = stringify_keys(entry)
          member_root = File.expand_path(entry.fetch("root"), root)
          entry.merge("root" => member_root)
        end
      end

      def discover_members?
        members = data.fetch("members", {})
        members.fetch("discover", true)
      end

      def order_mode
        fetch_path("members", "order", "mode") || "dependency"
      end

      def order_hints
        fetch_path("members", "order", "hints") || []
      end

      def command_for(name)
        fetch_path("commands", name)
      end

      def template_command
        fetch_path("template", "command") || command_for("template")
      end

      def template_profile
        fetch_path("template", "profile")
      end

      def template_repository_topology
        fetch_path("template", "repository_topology")
      end

      def normalize_lockfiles?
        fetch_path("template", "normalize_lockfiles") == true
      end

      def normalize_lockfiles_command
        fetch_path("template", "normalize_lockfiles_command") || "bundle lock"
      end

      def release_build_command
        fetch_path("release", "build_command") || command_for("release_build") || "bundle exec rake build"
      end

      def release_publish_command
        fetch_path("release", "publish_command") || command_for("release_publish") || "bundle exec kettle-release"
      end

      def release_tag_command
        fetch_path("release", "tag_command") || command_for("release_tag") || "git tag"
      end

      def release_push_command
        fetch_path("release", "push_command") || command_for("release_push") || "git push --follow-tags"
      end

      def release_target_branches
        fetch_path("release", "target_branches") || fetch_path("branches", "release_targets") || []
      end

      def branch_lanes
        fetch_path("branch_lanes") || fetch_path("branches", "lanes") || {}
      end

      private

      def sibling_member_roots
        Dir.children(root)
          .map { |entry| File.join(root, entry) }
          .select { |path| File.directory?(path) }
      end

      def fetch_path(*keys)
        keys.reduce(data) do |memo, key|
          break nil unless memo.is_a?(Hash)

          memo[key]
        end
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
