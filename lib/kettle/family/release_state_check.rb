# frozen_string_literal: true

require "json"
require "fileutils"
require "open3"
require "rbconfig"
require "rubygems"
require "securerandom"

module Kettle
  module Family
    class ReleaseStateCheck
      def initialize(members:, config: nil)
        @members = members
        @config = config
      end

      def results
        return branch_results unless release_target_branches.empty?
        return [check_family_changelog] if shared_changelog?

        members.each_with_object([]) do |member, memo|
          member_branch_results = member_local_branch_results(member)
          if member_branch_results
            memo.concat(member_branch_results)
          else
            memo << check_member(member)
          end
        end
      end

      private

      attr_reader :members, :config

      def branch_results
        root = git_root
        selected_names = members.map(&:name)
        release_target_branches.each_with_object([]) do |branch, memo|
          with_branch_worktree(root: root, branch: branch) do |worktree_root|
            if shared_changelog?
              memo << check_family_changelog(branch: branch, worktree_root: worktree_root)
              next
            end

            branch_members = discover_branch_members(worktree_root: worktree_root, selected_names: selected_names)
            memo.concat(branch_members.map { |member| check_member(member, branch: branch) })
          end
        rescue Error => error
          memo << error_result(branch: branch, error: error)
        end
      end

      def check_member(member, branch: nil)
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        command = release_state_command
        stdout, stderr, status = Open3.capture3(release_state_env, *command, chdir: release_state_workdir(member))
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
        success = status.success?
        state = success ? JSON.parse(stdout) : {}
        state = branch_filtered_state(member, state, branch) if success && branch
        result(member: member, command: command, stdout: stdout, stderr: stderr, status: status.exitstatus, elapsed: elapsed, success: success, state: state, branch: branch)
      rescue JSON::ParserError => error
        result(member: member, command: command || release_state_command, stdout: stdout, stderr: stderr, status: 1, elapsed: elapsed || 0.0, success: false, state: {}, reason: "invalid release-state JSON: #{error.message}", branch: branch)
      end

      def release_state_command
        [RbConfig.ruby, "-S", "kettle-changelog", "--release-state", "--json"]
      end

      def check_family_changelog(branch: nil, worktree_root: nil)
        member = family_member(root: worktree_root ? branch_config_root(worktree_root) : config.root)
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        state = family_changelog_state(member.root)
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
        result(
          member: member,
          command: ["internal", "release-state", "root-changelog"],
          stdout: "",
          stderr: "",
          status: 0,
          elapsed: elapsed,
          success: true,
          state: state,
          branch: branch
        )
      rescue Error => error
        result(
          member: member,
          command: ["internal", "release-state", "root-changelog"],
          stdout: "",
          stderr: error.message,
          status: 1,
          elapsed: 0.0,
          success: false,
          state: {},
          reason: "release state check failed",
          branch: branch
        )
      end

      def family_member(root:)
        Member.new(
          name: config.family_name,
          root: root,
          gemspec_path: nil,
          version_file: nil,
          version: nil,
          dependencies: []
        )
      end

      def release_state_workdir(member)
        return member.root unless config
        return member.root if config.shared_changelog?

        config.changelog_workdir(member) || member.root
      end

      def release_state_env
        config ? config.changelog_env : {}
      end

      def branch_filtered_state(member, state, _branch)
        latest_released = branch_latest_released(member, state["latest_changelog_version"])
        return state unless latest_released

        state.merge(
          "latest_released" => latest_released,
          "ahead" => commits_ahead_of_release(member.root, latest_released)
        )
      rescue ArgumentError
        state
      end

      def branch_latest_released(member, line_version)
        target_major = gem_version(line_version).segments.first
        versions = release_tag_versions(member.root).select do |version|
          version.segments.first == target_major
        end
        versions.max&.to_s
      end

      def release_tag_versions(root)
        stdout, stderr, status = Open3.capture3("git", "tag", "--list", "v*", chdir: root)
        raise Error, "could not list release tags for #{root}: #{stderr}" unless status.success?

        stdout.lines.each_with_object([]) do |line, memo|
          tag = line.strip
          next unless tag.start_with?("v")

          begin
            memo << gem_version(tag.delete_prefix("v"))
          rescue ArgumentError
            nil
          end
        end
      end

      def gem_version(value)
        raise ArgumentError, "missing version" if value.to_s.empty?

        Gem::Version.new(value)
      end

      def commits_ahead_of_release(root, version)
        tag = release_tag_for_version(root, version)
        branch = default_branch_ref(root)
        return nil unless tag && branch

        stdout, _stderr, status = Open3.capture3("git", "rev-list", "--count", "#{tag}..#{branch}", chdir: root)
        status.success? ? stdout.to_i : nil
      end

      def release_tag_for_version(root, version)
        return nil if version.to_s.empty?

        ["v#{version}", version.to_s].find { |tag| git_ref_exists?(root, "refs/tags/#{tag}^{commit}") }
      end

      def default_branch_ref(root)
        stdout, _stderr, status = Open3.capture3("git", "symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD", chdir: root)
        return stdout.strip if status.success? && !stdout.strip.empty?

        %w[main master HEAD].find { |ref| git_ref_exists?(root, ref) }
      end

      def git_ref_exists?(root, ref)
        _stdout, _stderr, status = Open3.capture3("git", "rev-parse", "--verify", "--quiet", ref, chdir: root)
        status.success?
      end

      def family_changelog_state(root)
        changelog = File.expand_path(config.changelog_path, root)
        raise Error, "missing root changelog #{config.changelog_path}" unless File.file?(changelog)

        version = root_changelog_version(root)
        content = File.read(changelog)
        latest_changelog_version = latest_changelog_version(content)
        unreleased_entries = unreleased_entries?(content)
        prepared_release_pending = !version.to_s.empty? && latest_changelog_version == version
        ahead = commits_ahead_of_release(root, latest_changelog_version)
        {
          "gem_name" => config.family_name,
          "version" => version,
          "latest_released" => nil,
          "latest_changelog_version" => latest_changelog_version,
          "ahead" => ahead,
          "unreleased_entries" => unreleased_entries,
          "prepared_release_pending" => prepared_release_pending,
          "pending_release" => unreleased_entries || prepared_release_pending
        }
      end

      def root_changelog_version(root)
        version_file = config.changelog_version_file
        return nil unless version_file

        path = File.expand_path(version_file, root)
        raise Error, "missing changelog version file #{version_file}" unless File.file?(path)

        version_string_node(File.read(path), path).unescaped
      end

      def version_string_node(source, path)
        require_prism
        parse_result = Prism.parse(source)
        raise Error, "could not parse #{path}" unless parse_result.success?

        constant = each_node(parse_result.value).find do |node|
          node.is_a?(Prism::ConstantWriteNode) && node.name == :VERSION && node.value.is_a?(Prism::StringNode)
        end
        raise Error, "could not find string VERSION constant in #{path}" unless constant

        constant.value
      end

      def latest_changelog_version(content)
        content.each_line.filter_map do |line|
          match = line.match(/\A## \[([^\]]+)\]/)
          next unless match

          version = match[1]
          next if version == "Unreleased"

          version
        end.first
      end

      def unreleased_entries?(content)
        lines = content.lines
        start = lines.index { |line| line.start_with?("## [Unreleased]") }
        return false unless start

        following = lines.drop(start + 1)
        block = following.take_while { |line| !line.start_with?("## [") }
        block.any? { |line| line.match?(/\S/) && !line.match?(/\A###? /) }
      end

      def require_prism
        return if defined?(Prism)

        require "prism"
      rescue LoadError => error
        raise Error, "root changelog release-state requires Prism; install the prism gem or run on a Ruby engine that provides it (#{error.message})"
      end

      def each_node(root)
        return enum_for(__method__, root) unless block_given?

        queue = [root]
        until queue.empty?
          node = queue.shift
          yield node
          queue.concat(node.child_nodes.compact) if node.respond_to?(:child_nodes)
        end
      end

      def result(member:, command:, stdout:, stderr:, status:, elapsed:, success:, state:, reason: nil, branch: nil)
        ReleaseStateResult.new(
          member_name: member.name,
          command: command,
          workdir: member.root,
          status: status,
          success: success,
          stdout: stdout,
          stderr: stderr,
          elapsed_seconds: elapsed,
          state: state,
          reason: reason || (success ? nil : "release state check failed"),
          branch: branch
        )
      end

      def error_result(branch:, error:)
        ReleaseStateResult.new(
          member_name: branch,
          command: ["internal", "release-state", branch],
          workdir: config.root,
          status: 1,
          success: false,
          stdout: "",
          stderr: error.message,
          elapsed_seconds: 0.0,
          state: {},
          reason: "branch release state failed",
          branch: branch
        )
      end

      def release_target_branches
        return [] unless config

        config.release_target_branches
      end

      def member_local_branch_results(member)
        member_config = member_local_release_config(member)
        return unless member_config

        self.class.new(config: member_config, members: [member]).results
      end

      def member_local_release_config(member)
        BranchTargetConfig.member_release_config(member: member, config: config)
      end

      def shared_changelog?
        config&.shared_changelog?
      end

      def git_root
        stdout, stderr, status = Open3.capture3("git", "rev-parse", "--show-toplevel", chdir: config.root)
        raise Error, "could not determine git root for #{config.root}: #{stderr}" unless status.success?

        File.realpath(stdout.strip)
      end

      def with_branch_worktree(root:, branch:)
        base = File.join(root, "tmp", "kettle-family-release-state")
        FileUtils.mkdir_p(base)
        worktree_root = File.join(base, "worktree-#{Process.pid}-#{SecureRandom.hex(8)}")
        add_branch_worktree(root: root, branch: branch, worktree_root: worktree_root)
        yield worktree_root
      ensure
        remove_branch_worktree(root: root, worktree_root: worktree_root)
      end

      def add_branch_worktree(root:, branch:, worktree_root:)
        _stdout, stderr, status = Open3.capture3("git", "worktree", "add", "--detach", worktree_root, branch, chdir: root)
        raise Error, "could not add worktree for #{branch}: #{stderr}" unless status.success?
      end

      def remove_branch_worktree(root:, worktree_root:)
        return unless worktree_root && Dir.exist?(worktree_root)

        Open3.capture3("git", "worktree", "remove", "--force", worktree_root, chdir: root)
      end

      def discover_branch_members(worktree_root:, selected_names:)
        branch_config = Config.load(root: branch_config_root(worktree_root))
        Discovery.new(config: branch_config).members
          .sort_by(&:name)
          .select { |member| selected_names.include?(member.name) }
      end

      def branch_config_root(worktree_root)
        File.join(worktree_root, relative_config_root)
      end

      def relative_config_root
        @relative_config_root ||= begin
          root = git_root
          config_root = File.realpath(config.root)
          if config_root == root
            "."
          elsif config_root.start_with?("#{root}/")
            config_root.delete_prefix("#{root}/")
          else
            raise Error, "configured root #{config.root} is outside git root #{root}"
          end
        end
      end
    end
  end
end
