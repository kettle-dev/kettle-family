# frozen_string_literal: true

module Kettle
  module Family
    class Workflow
      DEFAULT_COMMANDS = {
        "template" => "bundle exec kettle-jem install",
        "test" => "bundle exec kettle-test",
        "lint" => "bundle exec rake rubocop_gradual",
        "docs" => "bundle exec rake yard"
      }.freeze

      def initialize(command:, config:, members:, execute: false, commit: false, allow_dirty: false, publish: false, push: false, tag: false)
        @command = command
        @config = config
        @members = members
        @execute = execute
        @commit = commit
        @allow_dirty = allow_dirty
        @publish = publish
        @push = push
        @tag = tag
      end

      def results
        return check_results if command == "check"
        return release_results if command == "release"
        guard_family_commit!

        runner = CommandRunner.new(execute: execute)
        command_text = workflow_command
        results = members.each_with_object([]) do |member, memo|
          result = runner.call(member: member, phase: command, command: command_text, env: workflow_env)
          memo << result
          break memo unless result.ok?

          normalize_lockfiles(member: member, runner: runner, memo: memo) if command == "template"
        end
        append_family_commit(results: results, runner: runner)
        results
      end

      private

      attr_reader :command, :config, :members, :execute, :commit, :allow_dirty, :publish, :push, :tag

      def check_results
        members.map { |member| ReadinessCheck.call(member: member) }
      end

      def release_results
        runner = CommandRunner.new(execute: execute)
        members.each_with_object([]) do |member, memo|
          append_release_internal_checks(member: member, memo: memo)
          break memo unless memo.last(2).all?(&:ok?)

          memo << runner.call(member: member, phase: release_phase, command: release_command)
          break memo unless memo.last.ok?

          append_release_git_phases(member: member, runner: runner, memo: memo)
          break memo unless memo.last.ok?
        end
      end

      def append_release_internal_checks(member:, memo:)
        memo << ReadinessCheck.call(member: member)
        memo << ChangelogCheck.call(member: member) if memo.last.ok?
      end

      def release_phase
        publish ? "release_publish" : "release_build"
      end

      def release_command
        publish ? config.release_publish_command : config.release_build_command
      end

      def append_release_git_phases(member:, runner:, memo:)
        memo << runner.call(member: member, phase: "release_tag", command: config.release_tag_command) if tag
        return if memo.any? && !memo.last.ok?

        memo << runner.call(member: member, phase: "release_push", command: config.release_push_command) if push
      end

      def guard_family_commit!
        return unless command == "template" && commit && execute
        return if allow_dirty
        return unless GitStatus.dirty?(config.root)

        raise Error, "refusing template --commit with dirty worktree; pass --allow-dirty to override"
      end

      def workflow_command
        return template_command if command == "template"

        command_for(command)
      end

      def command_for(name)
        configured = config.command_for(name)
        configured || DEFAULT_COMMANDS.fetch(name)
      end

      def template_command
        command_text = config.template_command || DEFAULT_COMMANDS.fetch("template")
        return command_text if command_text.is_a?(Array) && command_text.include?("--skip-commit")
        return [*command_text, "--skip-commit"] if command_text.is_a?(Array)
        return command_text if command_text.include?("--skip-commit")

        "#{command_text} --skip-commit"
      end

      def workflow_env
        return {} unless command == "template"

        {}.tap do |env|
          env["KETTLE_JEM_TEMPLATE_PROFILE"] = config.template_profile if config.template_profile
          env["KJ_REPOSITORY_TOPOLOGY"] = config.template_repository_topology if config.template_repository_topology
        end
      end

      def normalize_lockfiles(member:, runner:, memo:)
        return unless config.normalize_lockfiles?

        result = runner.call(
          member: member,
          phase: "normalize_lockfiles",
          command: config.normalize_lockfiles_command
        )
        memo << result
      end

      def append_family_commit(results:, runner:)
        return unless command == "template" && commit
        return unless results.all?(&:ok?)

        results << runner.call(
          member: family_member,
          phase: "family_commit",
          command: "git add -A && git commit -m 'Apply kettle-family template updates'"
        )
      end

      def family_member
        Member.new(
          name: config.family_name,
          root: config.root,
          gemspec_path: nil,
          version: nil,
          dependencies: []
        )
      end
    end
  end
end
