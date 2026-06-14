# frozen_string_literal: true

require "json"
require "fileutils"
require "open3"
require "rbconfig"
require "securerandom"

module Kettle
  module Family
    class ReleaseStateCheck
      RELEASE_STATE_SCRIPT = <<~RUBY
        require "json"
        require "kettle/dev"
        cli = Kettle::Dev::ChangelogCLI.new(strict: false, root: Dir.pwd)
        puts JSON.pretty_generate(cli.release_state)
      RUBY

      def initialize(members:, config: nil)
        @members = members
        @config = config
      end

      def results
        return branch_results unless release_target_branches.empty?

        members.map { |member| check_member(member) }
      end

      private

      attr_reader :members, :config

      def branch_results
        root = git_root
        selected_names = members.map(&:name)
        release_target_branches.each_with_object([]) do |branch, memo|
          with_branch_worktree(root: root, branch: branch) do |worktree_root|
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
        stdout, stderr, status = Open3.capture3(*command, chdir: member.root)
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
        success = status.success?
        state = success ? JSON.parse(stdout) : {}
        result(member: member, command: command, stdout: stdout, stderr: stderr, status: status.exitstatus, elapsed: elapsed, success: success, state: state, branch: branch)
      rescue JSON::ParserError => error
        result(member: member, command: command || release_state_command, stdout: stdout, stderr: stderr, status: 1, elapsed: elapsed || 0.0, success: false, state: {}, reason: "invalid release-state JSON: #{error.message}", branch: branch)
      end

      def release_state_command
        [RbConfig.ruby, "-e", RELEASE_STATE_SCRIPT]
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
