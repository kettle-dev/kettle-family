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
        "docs" => "bundle exec rake yard",
        "gha-sha-pins" => "bundle exec kettle-gha-sha-pins"
      }.freeze
      GIT_SYNC_COMMANDS = {
        "push" => [["push", %w[git push]]],
        "pull" => [["pull", %w[git pull --rebase]]],
        "up" => [["pull", %w[git pull --rebase]], ["push", %w[git push]]]
      }.freeze

      def initialize(command:, config:, members:, execute: false, accept: true, commit: true, allow_dirty: false, publish: false, push: false, tag: false, start_step: nil, local_ci: false, continue_ci_failures: false, gha_sha_pins_upgrade: "patch", gha_sha_pins_check: false, env_overrides: {}, gem_signing_password: nil)
        @command = command
        @config = config
        @members = members
        @execute = execute
        @accept = accept
        @commit = commit
        @allow_dirty = allow_dirty
        @publish = publish
        @push = push
        @tag = tag
        @start_step = start_step
        @local_ci = local_ci
        @continue_ci_failures = continue_ci_failures
        @gha_sha_pins_upgrade = gha_sha_pins_upgrade
        @gha_sha_pins_check = gha_sha_pins_check
        @env_overrides = env_overrides
        @gem_signing_password = gem_signing_password
      end

      def results
        prompt_for_gem_signing_password if command == "release" && execute && release_signing_prompt_required?
        return branch_target_results unless config.release_target_branches.empty?
        return member_local_branch_target_results if member_local_branch_targets?

        current_branch_results(members)
      end

      private

      attr_reader :command, :config, :members, :execute, :accept, :commit, :allow_dirty, :publish, :push, :tag, :start_step, :local_ci, :continue_ci_failures, :gha_sha_pins_upgrade, :gha_sha_pins_check, :env_overrides

      def current_branch_results(workflow_members)
        return check_results(workflow_members) if command == "check"
        return release_member_results(workflow_members, include_family_changelog: true) if command == "release"
        return git_sync_results(workflow_members) if GIT_SYNC_COMMANDS.key?(command)

        member_workflow_results(workflow_members)
      end

      def member_workflow_results(workflow_members)
        runner = CommandRunner.new(execute: execute, accept: accept)
        workflow_members.each_with_object([]) do |member, memo|
          if command == "template" && config.normalize_lockfiles?
            normalize_lockfiles(member: member, runner: runner, memo: memo, phase: "prepare_lockfiles")
            break memo unless memo.last.ok?
          end

          command_text = workflow_command(member)
          result = runner.call(member: member, phase: command, command: command_text, env: workflow_env)
          memo << result
          break memo unless result.ok?

          normalize_lockfiles(member: member, runner: runner, memo: memo, phase: "normalize_lockfiles") if command == "template"
          commit_gha_sha_pins(member: member, runner: runner, memo: memo) if command == "gha-sha-pins"
        end
      end

      def check_results(workflow_members)
        results = []
        results.concat(BranchLaneAudit.new(config: config, members: workflow_members).results) unless config.branch_lanes.empty?
        results.concat(workflow_members.map { |member| ReadinessCheck.call(member: member, config: config) })
        results
      end

      def branch_target_results
        runner = command_runner
        selected_names = members.map(&:name)
        branch_targets.each_with_object([]) do |branch, memo|
          memo << checkout_branch_result(branch: branch, runner: runner)
          break memo unless memo.last.ok?

          branch_members = rediscovered_selected_members(selected_names)
          branch_members = members if branch_members.empty?
          memo.concat(current_branch_results(branch_members))
          break memo unless memo.last&.ok?

          commit_normalized_lockfiles(branch_members: branch_members, runner: runner, memo: memo)
          break memo unless memo.last&.ok?
        end
      end

      def member_local_branch_target_results
        return release_member_local_branch_target_results if command == "release"

        members.each_with_object([]) do |member, memo|
          member_config = member_local_release_config(member)
          if member_config
            memo.concat(member_local_workflow(member: member, member_config: member_config).results)
          else
            memo.concat(current_branch_results([member]))
          end
          break memo unless memo.last&.ok?
        end
      end

      def release_member_local_branch_target_results
        runner = command_runner
        results = []
        append_family_changelog_result(runner: runner, memo: results)
        return results unless results.all?(&:ok?)

        members.each_with_object(results) do |member, memo|
          member_config = member_local_release_config(member)
          if member_config
            memo.concat(member_local_workflow(member: member, member_config: member_config).results)
          else
            memo.concat(release_member_results([member], include_family_changelog: false))
          end
          break memo unless memo.last&.ok?
        end
      end

      def member_local_workflow(member:, member_config:)
        self.class.new(
          command: command,
          config: member_config,
          members: [member],
          execute: execute,
          accept: accept,
          commit: commit,
          allow_dirty: allow_dirty,
          publish: publish,
          push: push,
          tag: tag,
          start_step: start_step,
          local_ci: local_ci,
          continue_ci_failures: continue_ci_failures,
          gha_sha_pins_upgrade: gha_sha_pins_upgrade,
          gha_sha_pins_check: gha_sha_pins_check,
          env_overrides: env_overrides,
          gem_signing_password: @gem_signing_password
        )
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

          if config.release_normalize_lockfiles?
            normalize_release_lockfiles(member: member, runner: runner, memo: memo)
            break memo unless memo.last&.ok?

            commit_normalized_lockfiles(branch_members: [member], runner: runner, memo: memo, reason: "release")
            break memo unless memo.last&.ok?
          end

          append_release_internal_checks(member: member, memo: memo)
          break memo unless memo.last(2).all?(&:ok?)

          memo << runner.call(
            member: member,
            phase: release_phase,
            command: release_command,
            env: release_env,
            interactive: release_command_interactive?
          )
          break memo unless memo.last.ok?

          append_release_git_phases(member: member, runner: runner, memo: memo)
          break memo unless memo.last.ok?
        end
      end

      def git_sync_results(sync_members)
        runner = command_runner
        sync_members.each_with_object([]) do |member, memo|
          GIT_SYNC_COMMANDS.fetch(command).each do |phase, git_command|
            memo << runner.call(member: member, phase: phase, command: git_command)
            break unless memo.last.ok?
          end
          break memo unless memo.last.ok?
        end
      end

      def command_runner
        CommandRunner.new(execute: execute, accept: accept, gem_signing_password: @gem_signing_password)
      end

      def rediscovered_selected_members(selected_names)
        discovered = Discovery.new(config: config).members
        ordered = Orderer.new(members: discovered, mode: config.order_mode, hints: config.order_hints).ordered
        ordered.select { |member| selected_names.include?(member.name) }
      end

      def member_local_branch_targets?
        members.any? { |member| member_local_release_config(member) }
      end

      def branch_targets
        BranchTargetConfig.branch_targets_for(command, config.release_target_branches)
      end

      def member_local_release_config(member)
        BranchTargetConfig.member_local_release_config(member: member, config: config)
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

      def release_command_interactive?
        publish || !!@gem_signing_password
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

      def release_signing_prompt_required?
        return false unless gem_signing_required?
        return true if publish

        members.any? { |member| signed_gemspec?(member) }
      end

      def signed_gemspec?(member)
        return false unless member.gemspec_path && File.file?(member.gemspec_path)

        content = File.read(member.gemspec_path)
        content.include?("signing_key") || content.include?("cert_chain")
      end

      def prompt_for_gem_signing_password
        return if @gem_signing_password

        print("Gem signing key password (cached for this family release; MFA prompts still remain interactive): ")
        @gem_signing_password = if $stdin.respond_to?(:noecho) && $stdin.tty?
          $stdin.noecho(&:gets)&.chomp
        else
          $stdin.gets&.chomp
        end
        puts
        raise Error, "gem signing password is required" if @gem_signing_password.to_s.empty?
      end

      def workflow_command(member = nil)
        return template_command(member) if command == "template"
        return gha_sha_pins_command if command == "gha-sha-pins"

        command_for(command)
      end

      def gha_sha_pins_command
        command_text = command_for(command)
        args = []
        args << (gha_sha_pins_check ? "--check" : "--write") unless command_includes_any?(command_text, %w[--check --write])
        args.concat(["--upgrade", gha_sha_pins_upgrade]) unless command_includes_arg?(command_text, "--upgrade")
        append_command_args(command_text, args)
      end

      def append_command_args(command_text, args)
        return command_text if args.empty?
        return [*command_text, *args] if command_text.is_a?(Array)

        "#{command_text} #{args.join(" ")}"
      end

      def command_includes_any?(command_text, args)
        args.any? { |arg| command_includes_arg?(command_text, arg) }
      end

      def command_includes_arg?(command_text, arg)
        command_text.is_a?(Array) ? command_text.map(&:to_s).include?(arg) : command_text.to_s.include?(arg)
      end

      def command_for(name)
        configured = config.command_for(name)
        configured || DEFAULT_COMMANDS.fetch(name)
      end

      def template_command(member)
        command_text = config.template_command || default_template_command(member)
        return command_text if commit
        return command_text if command_text.is_a?(Array) && command_text.include?("--skip-commit")
        return [*command_text, "--skip-commit"] if command_text.is_a?(Array)
        return command_text if command_text.include?("--skip-commit")

        "#{command_text} --skip-commit"
      end

      def default_template_command(member)
        return DEFAULT_COMMANDS.fetch("template") if templating_bundle_wired?(member)

        "kettle-jem install"
      end

      def templating_bundle_wired?(member)
        gemfile = File.join(member.root, "Gemfile")
        return false unless File.file?(gemfile)

        content = File.read(gemfile)
        content.include?("K_JEM_TEMPLATING") || content.include?("gemfiles/modular/templating")
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

      def normalize_release_lockfiles(member:, runner:, memo:)
        result = runner.call(
          member: member,
          phase: "release_normalize_lockfiles",
          command: config.release_normalize_lockfiles_command,
          env: release_lockfile_env
        )
        memo << result
      end

      def release_lockfile_env
        release_env.merge(config.release_disable_local_path_env.to_h { |key| [key, "false"] })
      end

      def commit_normalized_lockfiles(branch_members:, runner:, memo:, reason: command)
        return unless commit
        return unless commit_normalized_lockfiles?(reason)

        branch_members.each do |member|
          result = runner.call(
            member: member,
            phase: "commit_normalized_lockfiles",
            command: [
              "sh",
              "-lc",
              "files=$(git ls-files --modified --others --exclude-standard -- Gemfile.lock '*.lock' '**/*.lock'); " \
                "if [ -n \"$files\" ]; then printf '%s\\n' \"$files\" | xargs git add -- && git commit -m '🔒 Normalize lockfiles after templating'; fi"
            ]
          )
          memo << result
          break unless result.ok?
        end
      end

      def commit_normalized_lockfiles?(reason)
        case reason
        when "template"
          config.normalize_lockfiles?
        when "release"
          config.release_normalize_lockfiles?
        else
          false
        end
      end

      def commit_gha_sha_pins(member:, runner:, memo:)
        return if gha_sha_pins_check || !commit

        result = runner.call(
          member: member,
          phase: "commit_gha_sha_pins",
          command: [
            "sh",
            "-lc",
            "if ! git diff --quiet -- .github/workflows; then git add -- .github/workflows && git commit -m '🔒 Pin GitHub Actions SHAs'; fi"
          ]
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
