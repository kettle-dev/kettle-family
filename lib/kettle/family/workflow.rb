# frozen_string_literal: true

require "io/console"
require "json"
require "net/http"
require "uri"

module Kettle
  module Family
    class Workflow
      DEFAULT_COMMANDS = {
        "template" => "bundle exec kettle-jem install",
        "test" => "bundle exec kettle-test",
        "lint" => "bundle exec rake rubocop_gradual",
        "docs" => "bundle exec rake yard"
      }.freeze

      def initialize(command:, config:, members:, execute: false, commit: true, allow_dirty: false, publish: false, push: false, tag: false, start_step: nil, local_ci: false, continue_ci_failures: false, env_overrides: {})
        @command = command
        @config = config
        @members = members
        @execute = execute
        @commit = commit
        @allow_dirty = allow_dirty
        @publish = publish
        @push = push
        @tag = tag
        @start_step = start_step
        @local_ci = local_ci
        @continue_ci_failures = continue_ci_failures
        @env_overrides = env_overrides
        @gem_signing_password = nil
      end

      def results
        return check_results if command == "check"
        return release_results if command == "release"
        runner = CommandRunner.new(execute: execute)
        command_text = workflow_command
        members.each_with_object([]) do |member, memo|
          if command == "template" && config.normalize_lockfiles?
            normalize_lockfiles(member: member, runner: runner, memo: memo, phase: "prepare_lockfiles")
            break memo unless memo.last.ok?
          end

          result = runner.call(member: member, phase: command, command: command_text, env: workflow_env)
          memo << result
          break memo unless result.ok?

          normalize_lockfiles(member: member, runner: runner, memo: memo, phase: "normalize_lockfiles") if command == "template"
        end
      end

      private

      attr_reader :command, :config, :members, :execute, :commit, :allow_dirty, :publish, :push, :tag, :start_step, :local_ci, :continue_ci_failures, :env_overrides

      def check_results
        members.map { |member| ReadinessCheck.call(member: member, config: config) }
      end

      def release_results
        prompt_for_gem_signing_password if execute && publish && gem_signing_required?
        return branch_target_release_results unless config.release_target_branches.empty?

        release_member_results(members, include_family_changelog: true)
      end

      def branch_target_release_results
        runner = command_runner
        selected_names = members.map(&:name)
        config.release_target_branches.each_with_object([]) do |branch, memo|
          memo << checkout_branch_result(branch: branch, runner: runner)
          break memo unless memo.last.ok?

          branch_members = rediscovered_selected_members(selected_names)
          memo.concat(release_member_results(branch_members, include_family_changelog: true))
          break memo unless memo.last&.ok?
        end
      end

      def release_member_results(release_members, include_family_changelog: false)
        runner = command_runner
        results = []
        append_family_changelog_result(runner: runner, memo: results) if include_family_changelog
        return results unless results.all?(&:ok?)

        release_members.each_with_object(results) do |member, memo|
          if skip_already_released?(member)
            memo << already_released_result(member)
            next
          end

          append_release_internal_checks(member: member, memo: memo)
          break memo unless memo.last(2).all?(&:ok?)

          memo << runner.call(
            member: member,
            phase: release_phase,
            command: release_command,
            env: release_env,
            interactive: publish
          )
          break memo unless memo.last.ok?

          append_release_git_phases(member: member, runner: runner, memo: memo)
          break memo unless memo.last.ok?
        end
      end

      def command_runner
        CommandRunner.new(execute: execute, gem_signing_password: @gem_signing_password)
      end

      def rediscovered_selected_members(selected_names)
        discovered = Discovery.new(config: config).members
        ordered = Orderer.new(members: discovered, mode: config.order_mode, hints: config.order_hints).ordered
        ordered.select { |member| selected_names.include?(member.name) }
      end

      def checkout_branch_result(branch:, runner:)
        runner.call(
          member: family_member,
          phase: "release_checkout",
          command: ["git", "checkout", branch]
        )
      end

      def append_release_internal_checks(member:, memo:)
        memo << ReadinessCheck.call(member: member, config: config)
        memo << ChangelogCheck.call(member: member, config: config) if memo.last.ok?
      end

      def append_family_changelog_result(runner:, memo:)
        return unless config.release_family_changelog?

        memo << runner.call(
          member: family_member,
          phase: "family_changelog",
          command: config.release_family_changelog_command,
          env: release_env.merge(config.changelog_env)
        )
      end

      def release_phase
        publish ? "release_publish" : "release_build"
      end

      def release_command
        command = publish ? config.release_publish_command : config.release_build_command
        kettle_release_command?(command) ? append_kettle_release_args(command) : command
      end

      def kettle_release_command?(command)
        case command
        when Array
          command.any? { |part| part.to_s.include?("kettle-release") }
        when String
          command.include?("kettle-release")
        else
          false
        end
      end

      def append_kettle_release_args(command)
        args = []
        args << "start_step=#{start_step}" if start_step
        args << "--local-ci" if local_ci
        return command if args.empty?

        command.is_a?(Array) ? [*command, *args] : "#{command} #{args.join(" ")}"
      end

      def release_env
        env = config.release_env.dup
        env["K_RELEASE_CI_CONTINUE"] = "true" if continue_ci_failures
        env
      end

      def append_release_git_phases(member:, runner:, memo:)
        memo << runner.call(member: member, phase: "release_tag", command: config.release_tag_command) if tag
        return if memo.any? && !memo.last.ok?

        memo << runner.call(member: member, phase: "release_push", command: config.release_push_command) if push
      end

      def skip_already_released?(member)
        publish && execute && released_version?(member.name, member.version)
      end

      def released_version?(gem_name, version)
        uri = URI("https://gem.coop/api/v1/versions/#{gem_name}.json")
        response = Net::HTTP.get_response(uri)
        raise Error, "could not check published versions for #{gem_name}: HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)

        JSON.parse(response.body).any? { |entry| entry["number"].to_s == version.to_s }
      rescue JSON::ParserError => error
        raise Error, "could not parse published versions for #{gem_name}: #{error.message}"
      end

      def already_released_result(member)
        CommandResult.new(
          member_name: member.name,
          phase: "release_skip",
          command: ["internal", "released-version-check", member.version],
          workdir: member.root,
          status: 0,
          success: true,
          stdout: "#{member.name} #{member.version} is already published; skipping release",
          stderr: "",
          elapsed_seconds: 0.0,
          skipped: true,
          reason: "already released"
        )
      end

      def gem_signing_required?
        !ENV.fetch("SKIP_GEM_SIGNING", "").casecmp("true").zero?
      end

      def prompt_for_gem_signing_password
        return if @gem_signing_password

        print("Gem signing key password (cached for this family release; MFA prompts still remain interactive): ")
        @gem_signing_password = if $stdin.respond_to?(:noecho)
          $stdin.noecho(&:gets)&.chomp
        else
          $stdin.gets&.chomp
        end
        puts
        raise Error, "gem signing password is required" if @gem_signing_password.to_s.empty?
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
        return command_text if commit
        return command_text if command_text.is_a?(Array) && command_text.include?("--skip-commit")
        return [*command_text, "--skip-commit"] if command_text.is_a?(Array)
        return command_text if command_text.include?("--skip-commit")

        "#{command_text} --skip-commit"
      end

      def workflow_env
        {}.tap do |env|
          if command == "template"
            env["KETTLE_JEM_TEMPLATE_PROFILE"] = config.template_profile if config.template_profile
            env["KJ_REPOSITORY_TOPOLOGY"] = config.template_repository_topology if config.template_repository_topology
          end
          env.merge!(env_overrides)
        end
      end

      def normalize_lockfiles(member:, runner:, memo:, phase:)
        return unless config.normalize_lockfiles?

        result = runner.call(
          member: member,
          phase: phase,
          command: config.normalize_lockfiles_command
        )
        memo << result
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
