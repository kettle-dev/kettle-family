# frozen_string_literal: true

require "open3"
require "yaml"

module Kettle
  module Family
    module BranchTargetConfig
      MAIN_BRANCH_SKIPPING_COMMANDS = %w[install release].freeze

      module_function

      def branch_targets_for(command, branches)
        return branches unless MAIN_BRANCH_SKIPPING_COMMANDS.include?(command)

        branches.reject { |branch| branch == "main" }
      end

      def member_release_config(member:, config:)
        member_configured_release_config(member: member, config: config) ||
          member_local_release_config(member: member, config: config)
      end

      def member_configured_release_config(member:, config:)
        return unless config&.respond_to?(:member_release_target_branches)

        branches = config.member_release_target_branches.fetch(member.name, nil)
        return if branches.nil? || branches.empty?

        data = config.data.merge(
          "release" => config.data.fetch("release", {}).merge("target_branches" => branches)
        )
        Config.new(root: member.root, path: config.path, data: data)
      end

      def member_local_release_config(member:, config:)
        member_config = Config.load(root: member.root)
        member_config = member_local_release_config_from_branch(member) || member_config unless member_config.path
        return unless member_config.path
        return if same_config_path?(config&.path, member_config.path)
        return if member_config.release_target_branches.empty?

        member_config
      rescue Errno::ENOENT
        nil
      end

      def same_config_path?(left, right)
        return false if left.to_s.empty? || right.to_s.empty?
        return false unless File.file?(left) && File.file?(right)

        File.realpath(left) == File.realpath(right)
      end

      def member_local_release_config_from_branch(member)
        root = member_git_root(member)
        relative_root = member_relative_root(member, root)
        member_local_config_paths(root, relative_root).each do |config_ref, content|
          loaded = YAML.safe_load(content) || {}
          branch_config = Config.new(root: member.root, path: config_ref, data: loaded)
          return branch_config unless branch_config.release_target_branches.empty?
        end
        nil
      rescue Error, Psych::SyntaxError
        nil
      end

      def member_git_root(member)
        stdout, stderr, status = Open3.capture3("git", "rev-parse", "--show-toplevel", chdir: member.root)
        raise Error, "could not determine git root for #{member.root}: #{stderr}" unless status.success?

        File.realpath(stdout.strip)
      end

      def member_relative_root(member, root)
        member_root = File.realpath(member.root)
        return "." if member_root == root
        return member_root.delete_prefix("#{root}/") if member_root.start_with?("#{root}/")

        raise Error, "member root #{member.root} is outside git root #{root}"
      end

      def member_local_config_paths(root, relative_root)
        branches = local_branches(root)
        candidates = Config::DEFAULT_PATHS.map do |path|
          (relative_root == ".") ? path : File.join(relative_root, path)
        end
        branches.each_with_object([]) do |branch, memo|
          candidates.each do |path|
            content = git_show(root, "#{branch}:#{path}")
            memo << ["#{branch}:#{path}", content] if content
          end
        end
      end

      def local_branches(root)
        stdout, stderr, status = Open3.capture3("git", "for-each-ref", "--format=%(refname:short)", "refs/heads", chdir: root)
        raise Error, "could not list local branches for #{root}: #{stderr}" unless status.success?

        stdout.lines.map(&:strip).reject(&:empty?)
      end

      def git_show(root, revision)
        stdout, _stderr, status = Open3.capture3("git", "show", revision, chdir: root)
        status.success? ? stdout : nil
      end
    end
  end
end
