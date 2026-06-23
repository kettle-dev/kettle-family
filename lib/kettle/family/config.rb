# frozen_string_literal: true

require "yaml"

module Kettle
  module Family
    class Config
      DEFAULT_PATHS = [".kettle-family.yml", ".structuredmerge/kettle-family.yml"].freeze
      DEFAULT_MEMBER_EXCLUDES = [
        "vendor/**",
        "**/vendor/**",
        "tmp/**",
        "**/tmp/**",
        "spec/**",
        "**/spec/**",
        "test/**",
        "**/test/**"
      ].freeze

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

      def member_exclude_patterns
        members = data.fetch("members", {})
        patterns = members.fetch("exclude", nil) || members.fetch("ignore", nil) || []
        DEFAULT_MEMBER_EXCLUDES + Array(patterns)
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

      def check_required_files
        fetch_path("check", "required_files") || ReadinessCheck::REQUIRED_FILES
      end

      def check_required_bins
        fetch_path("check", "required_bins") || ReadinessCheck::REQUIRED_BINS
      end

      def check_root_required_files
        fetch_path("check", "root_required_files") || []
      end

      def check_member_required_dirs
        fetch_path("check", "member_required_dirs") || []
      end

      def check_forbidden_tracked_member_dirs
        fetch_path("check", "forbidden_tracked_member_dirs") || []
      end

      def check_forbidden_tracked_member_dirs_except
        fetch_path("check", "forbidden_tracked_member_dirs_except") || []
      end

      def check_readme_links
        fetch_path("check", "readme_links") || {}
      end

      def changelog_mode
        fetch_path("changelog", "mode") || "member"
      end

      def shared_changelog?
        changelog_mode == "root"
      end

      def changelog_path
        fetch_path("changelog", "path") || "CHANGELOG.md"
      end

      def changelog_version_file
        fetch_path("changelog", "version_file")
      end

      def changelog_workdir(_member = nil)
        shared_changelog? ? root : nil
      end

      def changelog_full_path(member)
        File.expand_path(changelog_path, shared_changelog? ? root : member.root)
      end

      def changelog_env
        return {} unless changelog_version_file

        {"K_CHANGELOG_VERSION_FILE" => changelog_version_file.to_s}
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

      def release_normalize_lockfiles?
        configured = fetch_path("release", "normalize_lockfiles")
        return configured unless configured.nil?

        normalize_lockfiles?
      end

      def release_normalize_lockfiles_command
        fetch_path("release", "normalize_lockfiles_command") || normalize_lockfiles_command
      end

      def release_disable_local_path_env
        configured = fetch_path("release", "disable_local_path_env")
        Array(configured || default_release_disable_local_path_env)
      end

      def install_local_dependencies
        paths = fetch_path("install", "local_dependencies") || fetch_path("local_dependencies") || []
        Array(paths).map do |entry|
          value = entry.is_a?(Hash) ? stringify_keys(entry).fetch("path") : entry
          expand_config_relative_path(value)
        end
      end

      def release_build_command
        fetch_path("release", "build_command") || command_for("release_build") || "bundle exec rake build"
      end

      def release_publish_command
        fetch_path("release", "publish_command") || command_for("release_publish") || "bundle exec kettle-release"
      end

      def release_env
        stringify_env(fetch_path("release", "env") || {})
      end

      def release_family_changelog?
        fetch_path("release", "family_changelog", "enabled") == true
      end

      def release_family_changelog_command
        fetch_path("release", "family_changelog", "command") || "bundle exec kettle-changelog"
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

      def default_release_disable_local_path_env
        %w[
          K_JEM_TEMPLATING
          SMORG_RB_DEV
          TREE_SITTER_LANGUAGE_PACK_DEV
          KETTLE_RB_DEV
          RUBOCOP_LTS_DEV
          PBOLING_DEV
          GALTZO_FLOSS_DEV
          UR_BRAIN_DEV
        ]
      end

      def expand_config_relative_path(value)
        text = value.to_s
        return text if text.start_with?("/")

        File.expand_path(text, config_dir)
      end

      def config_dir
        path ? File.dirname(path) : root
      end

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

      def stringify_env(value)
        stringify_keys(value).to_h { |key, item| [key.to_s, item.to_s] }
      end
    end
  end
end
