# frozen_string_literal: true

require "io/console"
require "fileutils"
require "json"
require "etc"
require "open3"
require "pathname"
require "rbconfig"
require "shellwords"
require "yaml"
require "kettle/dev/ruby_gems_versions"

require_relative "workflow_progress"

module Kettle
  module Family
    class Workflow
      DEFAULT_COMMANDS = {
        "template" => "bundle exec kettle-jem install",
        "test" => "bundle exec kettle-test",
        "lint" => "bundle exec rake rubocop_gradual",
        "docs" => "bundle exec rake yard",
        "gha-sha-pins" => "bundle exec kettle-gha-sha-pins",
        "sync" => [
          "sh",
          "-lc",
          <<~SH
            set -e
            current_branch=$(git branch --show-current)
            if [ -z "$current_branch" ]; then
              echo "kettle-family sync requires a named branch checkout" >&2
              exit 1
            fi
            default_ref=$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
            default_branch=${default_ref#origin/}
            if [ -z "$default_branch" ] || [ "$default_branch" = "$default_ref" ]; then
              default_branch=$(git remote show origin | awk '/HEAD branch:/ { print $NF; exit }')
            fi
            if [ -z "$default_branch" ]; then
              echo "could not determine origin default branch" >&2
              exit 1
            fi
            git fetch origin "$default_branch"
            if [ "$current_branch" != "$default_branch" ]; then
              git switch "$default_branch"
            fi
            git rebase "origin/$default_branch"
            if [ "$current_branch" != "$default_branch" ]; then
              git switch "$current_branch"
              git rebase "$default_branch"
            fi
          SH
        ],
        "bupb" => %w[bundle update --bundler]
      }.freeze
      PRE_TEMPLATE_BOOTSTRAP_GEMS = %w[nomono kettle-dev].freeze
      GIT_SYNC_COMMANDS = {
        "push" => [["push", %w[git push]]],
        "pull" => [["pull", %w[git pull --rebase]]],
        "up" => [["pull", %w[git pull --rebase]], ["push", %w[git push]]]
      }.freeze
      TEMPLATE_QUIET_ENV = {
        "KETTLE_JEM_QUIET" => "true",
        "KETTLE_JEM_DEBUG" => "false",
        "KETTLE_DEV_DEBUG" => "false",
        "STRUCTUREDMERGE_DEBUG" => "false",
        "DEBUG" => nil,
        "BUNDLE_QUIET" => "true",
        "BUNDLE_DEBUG" => "false",
        "BUNDLER_DEBUG" => "false",
        "BUNDLE_VERBOSE" => "false",
        "DEBUG_RESOLVER" => nil,
        "DEBUG_RESOLVER_TREE" => nil,
        "BUNDLER_DEBUG_RESOLVER" => nil,
        "BUNDLER_DEBUG_RESOLVER_TREE" => nil,
        "DEBUG_COMPACT_INDEX" => nil,
        "MOLINILLO_DEBUG" => nil,
        "BUNDLE_SILENCE_DEPRECATIONS" => "true",
        "BUNDLE_SILENCE_ROOT_WARNING" => "true",
        "BUNDLE_SUPPRESS_INSTALL_USING_MESSAGES" => "true"
      }.freeze
      RESET_LOCKFILE_HELPER = <<~RUBY
        require "bundler/inline"

        source_url = ENV.fetch("KETTLE_FAMILY_RESET_GEM_SOURCE", "https://gem.coop")
        kettle_dev_version = ENV["KETTLE_FAMILY_RESET_KETTLE_DEV_VERSION"].to_s

        gemfile(true) do
          source source_url
          if kettle_dev_version.empty?
            gem "kettle-dev"
          else
            gem "kettle-dev", kettle_dev_version
          end
        end

        load Gem.bin_path("kettle-dev", "kettle-reset")
      RUBY
      REGISTRY_WAIT_ATTEMPTS = 15
      REGISTRY_WAIT_INTERVAL_SECONDS = 15

      def initialize(command:, config:, members:, execute: false, accept: true, commit: true, allow_dirty: false, publish: false, push: false, tag: false, start_step: nil, skip_steps: nil, local_ci: false, continue_ci_failures: false, ci_workflows: nil, skip_bundle_audit: false, skip_remotes: nil, auto_dependency_floors: nil, gha_sha_pins_upgrade: "patch", gha_sha_pins_check: false, env_overrides: {}, debug: false, verbose: false, gem_signing_password: nil, secrets_provider: nil, jobs: nil, progress_io: nil, reset_target: nil, bup_args: [], bex_args: [], start_member: nil, start_branch: nil, **options)
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
        @skip_steps = skip_steps
        @local_ci = local_ci
        @continue_ci_failures = continue_ci_failures
        @ci_workflows = validate_ci_workflows(ci_workflows)
        @skip_bundle_audit = skip_bundle_audit
        @skip_remotes = validate_skip_remotes(skip_remotes)
        @auto_dependency_floors = auto_dependency_floors.nil? ? config.release_auto_dependency_floors? : auto_dependency_floors
        @gha_sha_pins_upgrade = gha_sha_pins_upgrade
        @gha_sha_pins_check = gha_sha_pins_check
        @env_overrides = env_overrides
        @debug = debug
        @verbose = verbose
        @gem_signing_password = gem_signing_password
        @secrets_provider = secrets_provider || Secrets::Provider.new
        @jobs = jobs
        @progress_io = progress_io
        @reset_target = reset_target
        @bup_args = bup_args
        @bex_args = bex_args
        @start_member = start_member
        @start_branch = start_branch
        @template_commit_mutex = Mutex.new
      end

      def results
        if command == "release" && execute
          release_preflight = release_preflight_results
          return release_preflight unless release_preflight.empty?

          return branch_target_results unless config.release_target_branches.empty?
          return member_local_branch_target_results if member_local_branch_targets?

          return current_branch_results(members)
        end

        preflight = branch_checkout_dirty_preflight_results
        return preflight unless preflight.empty?

        prompt_for_gem_signing_password if command == "release" && execute && release_signing_prompt_required?
        return branch_target_results unless config.release_target_branches.empty?
        return member_local_branch_target_results if member_local_branch_targets?

        current_branch_results(members)
      end

      private

      attr_reader :command, :config, :members, :execute, :accept, :commit, :allow_dirty, :publish, :push, :tag, :start_step, :skip_steps, :local_ci, :continue_ci_failures, :ci_workflows, :skip_bundle_audit, :skip_remotes, :auto_dependency_floors, :gha_sha_pins_upgrade, :gha_sha_pins_check, :env_overrides, :debug, :verbose, :jobs, :progress_io, :reset_target, :bup_args, :bex_args, :start_member, :start_branch

      def current_branch_results(workflow_members)
        return check_results(workflow_members) if command == "check"
        return reset_member_results(workflow_members) if command == "reset"
        return release_member_results(workflow_members, include_family_changelog: true) if command == "release"
        return git_sync_results(workflow_members) if GIT_SYNC_COMMANDS.key?(command)

        member_workflow_results(workflow_members)
      end

      def reset_member_results(workflow_members)
        target = normalized_reset_target
        runner = CommandRunner.new(execute: execute, accept: accept)
        workflow_members.each_with_object([]) do |member, memo|
          case target
          when "Gemfile.lock"
            reset_gemfile_lock(member: member, runner: runner, memo: memo)
          else
            raise Error, "reset target #{target.inspect} is not supported"
          end
          break memo unless memo.last&.ok?

          commit_normalized_lockfiles(branch_members: [member], runner: runner, memo: memo, reason: "reset", force: true)
          break memo unless memo.last&.ok?
        end
      end

      def normalized_reset_target
        target = reset_target.to_s.strip
        raise Error, "reset requires TARGET" if target.empty?
        return "Gemfile.lock" if target.casecmp("Gemfile.lock").zero?

        raise Error, "reset target #{target.inspect} is not supported; supported targets: Gemfile.lock"
      end

      def member_workflow_results(workflow_members)
        return template_member_workflow_results(workflow_members) if command == "template" && execute

        runner = CommandRunner.new(execute: execute, accept: accept)
        workflow_members.each_with_object([]) do |member, memo|
          if command == "template" && config.normalize_lockfiles?
            normalize_lockfiles(member: member, runner: runner, memo: memo, phase: "prepare_lockfiles")
            break memo unless memo.last.ok?
          end

          if command == "template"
            prepared = prepare_template_dependencies(member: member, runner: runner, memo: memo)
            break memo if prepared == false
          end

          command_text = workflow_command(member)
          result = runner.call(member: member, phase: command, command: command_text, env: command_env)
          memo << result
          break memo unless result.ok?

          normalize_lockfiles(member: member, runner: runner, memo: memo, phase: "normalize_lockfiles") if command == "template"
          commit_gha_sha_pins(member: member, runner: runner, memo: memo) if command == "gha-sha-pins"
          if %w[bup bupb].include?(command) && validate_bundle_update_lockfile(member: member, memo: memo)
            commit_bundle_update(member: member, runner: runner, memo: memo)
          end
          commit_bex_changes(member: member, runner: runner, memo: memo) if command == "bex"
        end
      end

      def template_member_workflow_results(workflow_members)
        queue = Queue.new
        workflow_members.each_with_index { |member, index| queue << [index, member] }
        ordered_results = Array.new(workflow_members.length)
        mutex = Mutex.new
        stop = false
        template_progress = start_template_progress(workflow_members)
        Array.new(template_jobs(workflow_members)) do
          Thread.new do # rubocop:disable ThreadSafety/NewThread -- family templating intentionally runs independent members concurrently.
            loop do
              break if mutex.synchronize { stop }
              index, member = queue.pop(true)
              member_results = template_results_for_member(member, progress: template_progress)
              mutex.synchronize do
                ordered_results[index] = member_results
                stop = true unless member_results.all?(&:ok?)
              end
            rescue ThreadError
              break
            end
          end
        end.each(&:join)
        flattened = ordered_results.compact.flatten
        emit_template_progress_summary(flattened, progress: template_progress)
        flattened
      end

      def template_results_for_member(member, progress: nil)
        progress&.start_member(member, total: template_phase_total(member), status: template_initial_status(member))
        runner = CommandRunner.new(execute: execute, accept: accept)
        [].tap do |memo|
          if config.normalize_lockfiles?
            normalize_lockfiles(member: member, runner: runner, memo: memo, phase: "prepare_lockfiles")
            emit_member_result_progress(member, memo.last, progress: progress)
            return memo unless memo.last.ok?
          end

          prepared = prepare_template_dependencies(member: member, runner: runner, memo: memo)
          emit_member_result_progress(member, memo.last, progress: progress) if memo.last&.phase == "prepare_template_dependencies"
          return memo if prepared == false

          memo << runner.call(
            member: member,
            phase: command,
            command: workflow_command(member),
            env: workflow_env,
            stdout_line_handler: template_event_line_handler(member, progress: progress)
          )
          emit_member_result_progress(member, memo.last, progress: progress)
          return memo unless memo.last.ok?

          normalize_lockfiles(member: member, runner: runner, memo: memo, phase: "normalize_lockfiles")
          emit_member_result_progress(member, memo.last, progress: progress)
          commit_template_changes(member: member, runner: runner, memo: memo)
          emit_member_result_progress(member, memo.last, progress: progress) if memo.last&.phase == "commit_template"
        ensure
          template_result = memo.find { |result| result.phase == "template" } || memo.last
          if template_result
            progress&.finish_member(
              member,
              success: memo.all?(&:ok?),
              status: template_member_finish_status(template_result)
            )
          end
        end
      end

      def template_jobs(workflow_members)
        requested = jobs || config.template_jobs
        count = requested ? requested.to_i : [Etc.nprocessors, 4].min
        count.clamp(1, workflow_members.length)
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
          branch_results = current_branch_results(branch_members)
          tag_branch_results(branch_results, branch)
          memo.concat(branch_results)
          break memo unless memo.last&.ok?

          commit_normalized_lockfiles(branch_members: branch_members, runner: runner, memo: memo)
          tag_branch_results(memo.last(1), branch)
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

      def release_preflight_results
        phases = release_preflight_phases
        emit_release_preflight_start(phases)
        phases.each_with_index do |phase, index|
          emit_release_preflight_phase(phase.fetch(:label), index: index, total: phases.length)
          result = send(phase.fetch(:method))
          emit_release_preflight_phase_finish(phase.fetch(:label), result)
          return result unless result.empty?
        end
        emit_release_preflight_summary(phases)
        []
      end

      def release_preflight_phases
        dirty_phase = {label: "branch checkout readiness", method: :release_preflight_branch_checkout_dirty_results}
        signing_phase = {label: "gem signing password", method: :release_preflight_signing_password_results}
        secrets_phase = release_secrets_authorization_required? ? {label: "secrets provider authorization", method: :release_preflight_secrets_authorization_results} : nil

        if secrets_phase
          [secrets_phase, dirty_phase, signing_phase]
        else
          [dirty_phase, signing_phase]
        end
      end

      def release_preflight_branch_checkout_dirty_results
        branch_checkout_dirty_preflight_results
      end

      def release_preflight_secrets_authorization_results
        authorize_release_secrets
        []
      rescue Error => error
        [release_preflight_error_result("secrets_provider_authorization", error.message)]
      end

      def release_preflight_signing_password_results
        prompt_for_gem_signing_password if release_signing_prompt_required?
        []
      rescue Error => error
        [release_preflight_error_result("gem_signing_password", error.message)]
      end

      def authorize_release_secrets
        secret = if @secrets_provider.respond_to?(:authorize!)
          @secrets_provider.authorize!
        else
          @secrets_provider.gem_signing_passphrase
        end
        @gem_signing_password = secret.to_s unless secret.to_s.empty?
        @gem_signing_password
      end

      def release_secrets_authorization_required?
        @secrets_provider.is_a?(Secrets::OnePassword)
      end

      def release_preflight_error_result(phase, message)
        CommandResult.new(
          member_name: family_member.name,
          phase: phase,
          command: ["internal", phase],
          workdir: config.root,
          status: 1,
          success: false,
          stdout: "",
          stderr: message,
          elapsed_seconds: 0.0,
          skipped: false,
          reason: "release preflight failed"
        )
      end

      def branch_checkout_dirty_preflight_results
        return [] unless execute
        return [] if allow_dirty
        return [] unless branch_checkout_preflight_required?

        branch_checkout_preflight_members.filter_map do |member|
          dirty_paths = GitStatus.dirty_paths(member.root)
          next if dirty_paths.empty?

          branch_checkout_dirty_result(member, dirty_paths)
        end
      end

      def branch_checkout_preflight_required?
        !config.release_target_branches.empty? || member_local_branch_targets?
      end

      def branch_checkout_preflight_members
        members_with_targets = members.select { |member| member_local_release_config(member) }
        members_with_targets = [family_member] if !config.release_target_branches.empty?
        members_with_targets
      end

      def branch_checkout_dirty_result(member, dirty_paths)
        CommandResult.new(
          member_name: member.name,
          phase: "release_checkout_preflight",
          command: ["git", "status", "--short"],
          workdir: member.root,
          status: 1,
          success: false,
          stdout: "",
          stderr: branch_checkout_dirty_message(dirty_paths),
          elapsed_seconds: 0.0,
          skipped: false,
          reason: "dirty worktree blocks release target branch checkout"
        )
      end

      def branch_checkout_dirty_message(dirty_paths)
        [
          "local changes would block release target branch checkout; commit or stash them before running kettle-family",
          *dirty_paths
        ].join("\n")
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
          skip_steps: skip_steps,
          local_ci: local_ci,
          continue_ci_failures: continue_ci_failures,
          ci_workflows: ci_workflows,
          skip_bundle_audit: skip_bundle_audit,
          auto_dependency_floors: auto_dependency_floors,
          gha_sha_pins_upgrade: gha_sha_pins_upgrade,
          gha_sha_pins_check: gha_sha_pins_check,
          env_overrides: env_overrides,
          gem_signing_password: @gem_signing_password,
          secrets_provider: @secrets_provider,
          jobs: jobs,
          progress_io: progress_io,
          bup_args: bup_args,
          bex_args: bex_args,
          start_member: start_member,
          start_branch: start_branch_for_member(member)
        )
      end

      def start_branch_for_member(member)
        return unless member.name == start_member

        start_branch
      end

      def release_member_results(release_members, include_family_changelog: false)
        runner = release_command_runner
        results = []
        append_family_changelog_result(runner: runner, memo: results) if include_family_changelog
        return results unless results.all?(&:ok?)
        return parallel_release_member_results(release_members, results) if parallel_release_members?(release_members)

        release_progress = start_release_progress(release_members)
        @release_progress = release_progress
        begin
          release_members.each_with_object(results) do |member, memo|
            memo.concat(release_results_for_member(member, runner: runner))
            break memo unless memo.last.ok?

            remaining_members = release_members.drop(release_members.index(member) + 1)
            append_dependency_floor_results(released_members: [member], dependent_members: remaining_members, runner: runner, memo: memo)
            break memo unless memo.last&.ok?
          end
        ensure
          emit_release_progress_summary(results, progress: release_progress)
          @release_progress = nil
        end
      end

      def parallel_release_member_results(release_members, initial_results)
        results = initial_results.dup
        waves = release_waves(release_members)
        completed_members = []
        release_progress = start_release_progress(release_members)
        @release_progress = release_progress
        begin
          waves.each_with_index do |wave, index|
            results << release_wave_result(wave, index: index, total: waves.length)
            wave_results = run_release_wave(wave)
            results.concat(wave_results.flatten)
            break unless wave_results.all? { |member_results| member_results.all?(&:ok?) }

            completed_members.concat(wave)
            remaining_members = release_members - completed_members
            append_dependency_floor_results(released_members: wave, dependent_members: remaining_members, runner: release_command_runner, memo: results)
            break unless results.last&.ok?
          end
        ensure
          emit_release_progress_summary(results, progress: release_progress)
          @release_progress = nil
        end
        results
      end

      def run_release_wave(wave)
        queue = Queue.new
        wave.each_with_index { |member, index| queue << [index, member] }
        ordered_results = Array.new(wave.length)
        wave_jobs = release_jobs(wave)
        mutex = Mutex.new
        stop = false
        release_otp_coordinator&.queue_total = wave_jobs
        Array.new(wave_jobs) do
          Thread.new do # rubocop:disable ThreadSafety/NewThread -- family release intentionally runs independent members concurrently.
            runner = release_command_runner
            loop do
              break if mutex.synchronize { stop }

              index, member = queue.pop(true)
              member_results = release_results_for_member(member, runner: runner)
              mutex.synchronize do
                ordered_results[index] = member_results
                stop = true unless member_results.all?(&:ok?)
              end
            rescue ThreadError
              break
            end
          end
        end.each(&:join)
        ordered_results.compact
      end

      def release_wave_result(wave, index:, total:)
        CommandResult.new(
          member_name: "wave #{index + 1}",
          phase: "release_wave",
          command: ["internal", "release-wave"],
          workdir: config.root,
          status: 0,
          success: true,
          stdout: wave.map(&:name).join(", "),
          stderr: "",
          elapsed_seconds: 0.0,
          skipped: false,
          reason: "jobs=#{release_jobs(wave)} total=#{total}"
        )
      end

      def release_results_for_member(member, runner:)
        progress = @release_progress
        progress&.start_member(member, total: release_phase_total, status: "check")
        [].tap do |memo|
          if skip_already_released?(member)
            memo << already_released_result(member)
            emit_member_result_progress(member, memo.last, progress: progress)
            return memo
          end

          if normalize_release_lockfiles?(member)
            normalize_release_lockfiles(member: member, runner: runner, memo: memo)
            emit_member_result_progress(member, memo.last, progress: progress)
            return memo unless memo.last&.ok?

            commit_normalized_lockfiles(branch_members: [member], runner: runner, memo: memo, reason: "release", force: true)
            emit_member_result_progress(member, memo.last, progress: progress)
            return memo unless memo.last&.ok?
          end

          append_release_internal_checks(member: member, memo: memo)
          memo.last(2).each { |result| emit_member_result_progress(member, result, progress: progress) }
          return memo unless memo.last(2).all?(&:ok?)

          memo << runner.call(
            member: member,
            phase: release_phase,
            command: release_command,
            env: release_env,
            interactive: release_command_interactive?,
            stdout_line_handler: release_event_line_handler(member, progress: progress)
          )
          emit_member_result_progress(member, memo.last, progress: progress)
          return memo unless memo.last.ok?

          before_git_phase_count = memo.length
          append_release_git_phases(member: member, runner: runner, memo: memo)
          memo.drop(before_git_phase_count).each { |result| emit_member_result_progress(member, result, progress: progress) }
        ensure
          finished_result = memo.find { |result| result.phase == release_phase } || memo.last
          if finished_result
            progress&.finish_member(
              member,
              success: memo.all?(&:ok?),
              status: release_member_finish_status(finished_result)
            )
          end
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

      def release_command_runner
        CommandRunner.new(
          execute: execute,
          accept: release_command_uses_kettle_release_yes? ? false : accept,
          gem_signing_password: release_command_uses_kettle_release_secrets? ? nil : @gem_signing_password,
          otp_coordinator: release_command_uses_kettle_release_secrets? ? nil : release_otp_coordinator
        )
      end

      def release_otp_coordinator
        return nil unless execute && release_command_interactive?

        @release_otp_coordinator ||= CommandRunner::OtpCoordinator.new(secrets_provider: @secrets_provider)
      end

      def parallel_release_members?(release_members)
        execute &&
          release_jobs(release_members) > 1 &&
          release_members.length > 1 &&
          distinct_git_roots?(release_members)
      end

      def release_jobs(release_members)
        # TruffleRuby issue: https://github.com/truffleruby/truffleruby/issues/4352
        return 1 if truffleruby?

        requested = jobs || config.release_jobs
        count = requested ? requested.to_i : [Etc.nprocessors, 4].min
        count.clamp(1, release_members.length)
      end

      def truffleruby?
        RUBY_ENGINE == "truffleruby"
      end

      def release_waves(release_members)
        ReleaseWaves.new(members: release_members).waves
      end

      def append_dependency_floor_results(released_members:, dependent_members:, runner:, memo:)
        return unless auto_dependency_floors
        return if dependent_members.empty?

        require_relative "dependency_floor"

        affected_dependent_members = dependent_members_depending_on(released_members: released_members, dependent_members: dependent_members)
        floor_results = DependencyFloor.new(
          released_members: released_members,
          dependent_members: dependent_members,
          mode: execute ? :execute : :dry_run
        ).results
        memo.concat(floor_results)
        return if floor_results.empty?
        return if floor_results.any? && !floor_results.all?(&:ok?)

        append_dependency_floor_lockfile_results(released_members: released_members, dependent_members: affected_dependent_members, runner: runner, memo: memo)
        return if memo.any? && !memo.last.ok?

        append_dependency_floor_ci_bundle_results(released_members: released_members, dependent_members: affected_dependent_members, runner: runner, memo: memo)
        return if memo.any? && !memo.last.ok?

        commit_dependency_floor_changes(dependent_members: floor_results.map(&:member_name), runner: runner, memo: memo) if floor_results.any? && execute && commit
      end

      def dependent_members_depending_on(released_members:, dependent_members:)
        released_names = released_members.map(&:name)
        dependent_members.select do |member|
          release_dependency_names(member).any? { |dependency| released_names.include?(dependency) }
        end
      end

      def release_dependency_names(member)
        Array(member.release_dependencies || member.dependencies).map(&:to_s)
      end

      def append_dependency_floor_lockfile_results(released_members:, dependent_members:, runner:, memo:)
        return unless execute && publish
        return if dependent_members.empty?

        dependent_members.each do |member|
          memo << wait_for_dependency_floor_lockfiles_result(member: member, released_members: released_members, runner: runner)
          break unless memo.last.ok?
        end
      end

      def append_dependency_floor_ci_bundle_results(released_members:, dependent_members:, runner:, memo:)
        return unless execute && publish
        return if dependent_members.empty?

        dependent_members.each do |member|
          dependency_floor_ci_bundle_gemfiles(member).each do |gemfile|
            memo << wait_for_dependency_floor_ci_bundle_result(member: member, gemfile: gemfile, released_members: released_members, runner: runner)
            break unless memo.last.ok?
          end
          break if memo.any? && !memo.last.ok?
        end
      end

      def wait_for_dependency_floor_lockfiles_result(member:, released_members:, runner:)
        result = nil
        REGISTRY_WAIT_ATTEMPTS.times do |index|
          emit_dependency_floor_lockfile_progress(member: member, attempt: index + 1)
          result = runner.call(
            member: member,
            phase: "dependency_floor_lockfiles",
            command: dependency_floor_lockfile_command(released_members),
            env: release_lockfile_env(member)
          )
          validate_dependency_floor_lockfile_result(result: result, member: member, released_members: released_members) if result.ok?
          annotate_dependency_floor_lockfile_result(result, index + 1)
          break if result.ok?

          sleep(REGISTRY_WAIT_INTERVAL_SECONDS) if index + 1 < REGISTRY_WAIT_ATTEMPTS
        end
        result
      end

      def wait_for_dependency_floor_ci_bundle_result(member:, gemfile:, released_members:, runner:)
        result = nil
        REGISTRY_WAIT_ATTEMPTS.times do |index|
          emit_dependency_floor_ci_bundle_progress(member: member, gemfile: gemfile, attempt: index + 1)
          FileUtils.mkdir_p(File.dirname(dependency_floor_ci_bundle_lockfile_path(member: member, gemfile: gemfile)))
          result = runner.call(
            member: member,
            phase: "dependency_floor_ci_bundle",
            command: dependency_floor_ci_bundle_command(released_members),
            env: dependency_floor_ci_bundle_env(member: member, gemfile: gemfile)
          )
          annotate_dependency_floor_ci_bundle_result(result, index + 1, gemfile: gemfile)
          break if result.ok?

          sleep(REGISTRY_WAIT_INTERVAL_SECONDS) if index + 1 < REGISTRY_WAIT_ATTEMPTS
        end
        result
      end

      def validate_dependency_floor_lockfile_result(result:, member:, released_members:)
        diagnostics = dependency_floor_lockfile_diagnostics(member: member, released_members: released_members)
        return if diagnostics.empty?

        result.status = 1
        result.success = false
        result.stderr = [result.stderr, *diagnostics].reject(&:empty?).join("\n")
      end

      def dependency_floor_lockfile_diagnostics(member:, released_members:)
        lockfile = File.join(member.root, "Gemfile.lock")
        return ["Gemfile.lock was not created by dependency floor lockfile refresh"] unless File.file?(lockfile)

        lockfile_source = File.read(lockfile)
        diagnostics = release_lockfile_local_path_remote_lines(lockfile_source).map do |line_number|
          "Gemfile.lock has local path remote at line #{line_number}"
        end
        diagnostics.concat(released_members.filter_map do |released_member|
          checksum_line = checksum_line_for(lockfile_source: lockfile_source, member: released_member)
          if checksum_line.nil?
            "Gemfile.lock CHECKSUMS is missing #{released_member.name} #{released_member.version}"
          elsif !checksum_line.include?("sha256=")
            "Gemfile.lock CHECKSUMS has no sha256 for #{released_member.name} #{released_member.version}"
          end
        end)
        diagnostics
      end

      def dependency_floor_lockfile_command(released_members)
        ["bundle", "lock", "--update", *released_members.map(&:name), "--add-checksums"]
      end

      def dependency_floor_ci_bundle_command(released_members)
        ["bundle", "lock", "--update", *released_members.map(&:name), "--add-checksums"]
      end

      def dependency_floor_ci_bundle_env(member:, gemfile:)
        release_lockfile_env(member).merge(
          "BUNDLE_GEMFILE" => gemfile,
          "BUNDLE_LOCKFILE" => dependency_floor_ci_bundle_lockfile_path(member: member, gemfile: gemfile)
        )
      end

      def dependency_floor_ci_bundle_lockfile_path(member:, gemfile:)
        relative = relative_path_from_member_root(member: member, path: gemfile)
        safe_name = relative.gsub(%r{[^A-Za-z0-9_.-]+}, "_")
        File.join(member.root, "tmp", "kettle-family", "dependency-floor-ci-bundles", "#{safe_name}.lock")
      end

      def dependency_floor_ci_bundle_gemfiles(member)
        workflow_bundle_gemfiles(member).select do |gemfile|
          File.file?(gemfile)
        end.uniq.sort
      end

      def workflow_bundle_gemfiles(member)
        Dir.glob(File.join(member.root, ".github", "workflows", "*.{yml,yaml}")).flat_map do |path|
          workflow_bundle_gemfile_entries(path).map do |entry|
            File.expand_path(entry, member.root)
          end
        end
      end

      def workflow_bundle_gemfile_entries(path)
        data = YAML.safe_load_file(path, permitted_classes: [], permitted_symbols: [], aliases: true) || {}
        recursive_values_for_key(data, "bundle_gemfile").map(&:to_s).reject(&:empty?)
      rescue Psych::Exception
        []
      end

      def recursive_values_for_key(value, key)
        case value
        when Hash
          value.flat_map do |entry_key, entry_value|
            matches = (entry_key.to_s == key) ? [entry_value] : []
            matches.concat(recursive_values_for_key(entry_value, key))
          end
        when Array
          value.flat_map { |entry| recursive_values_for_key(entry, key) }
        else
          []
        end
      end

      def relative_path_from_member_root(member:, path:)
        Pathname.new(path).relative_path_from(Pathname.new(member.root)).to_s
      rescue ArgumentError
        path.to_s
      end

      def reset_gemfile_lock(member:, runner:, memo:)
        result = runner.call(
          member: member,
          phase: "reset_gemfile_lock",
          command: reset_gemfile_lock_command(member),
          env: release_lockfile_env(member)
        )
        memo << result
        return unless result.ok? && execute

        validate_reset_gemfile_lock(member: member, memo: memo)
      end

      def reset_gemfile_lock_command(member)
        [
          "env",
          "-u",
          "BUNDLE_BIN_PATH",
          "-u",
          "BUNDLE_FROZEN",
          "-u",
          "BUNDLE_GEMFILE",
          "-u",
          "BUNDLER_VERSION",
          "-u",
          "RUBYOPT",
          reset_helper_ruby,
          "-e",
          RESET_LOCKFILE_HELPER,
          "release-lockfiles"
        ]
      end

      def reset_helper_ruby
        env_overrides["KETTLE_FAMILY_RESET_RUBY"].to_s.empty? ? RbConfig.ruby : env_overrides["KETTLE_FAMILY_RESET_RUBY"].to_s
      end

      def validate_reset_gemfile_lock(member:, memo:)
        diagnostics = reset_gemfile_lock_diagnostics(member)
        return if diagnostics.empty?

        memo << CommandResult.new(
          member.name,
          "reset_gemfile_lock_readiness",
          ["internal", "validate", "Gemfile.lock"],
          member.root,
          1,
          false,
          "",
          diagnostics.join("\n"),
          0.0,
          false,
          "Gemfile.lock reset validation failed"
        )
      end

      def reset_gemfile_lock_diagnostics(member)
        lockfiles = [
          File.join(member.root, "Gemfile.lock"),
          File.join(member.root, "Appraisal.root.gemfile.lock")
        ].select { |lockfile| File.file?(lockfile) }
        return ["Gemfile.lock was not created by reset"] if lockfiles.empty?

        lockfiles.flat_map do |lockfile|
          reset_lockfile_diagnostics(lockfile)
        end
      end

      def reset_lockfile_diagnostics(lockfile)
        lockfile_name = File.basename(lockfile)
        lockfile_source = File.read(lockfile)
        diagnostics = release_lockfile_local_path_remote_lines(lockfile_source).map do |line_number|
          "#{lockfile_name} has local path remote at line #{line_number}"
        end
        checksum_entries = lockfile_checksum_entries(lockfile_source)
        if checksum_entries.nil?
          diagnostics << "#{lockfile_name} CHECKSUMS section is missing"
          return diagnostics
        end

        lockfile_gem_specs(lockfile_source).each do |name, version|
          checksum = checksum_entries[[name, version]]
          if checksum.nil?
            diagnostics << "#{lockfile_name} CHECKSUMS is missing #{name} #{version}"
          elsif !checksum.include?("sha256=")
            diagnostics << "#{lockfile_name} CHECKSUMS has no sha256 for #{name} #{version}"
          end
        end
        diagnostics
      end

      def release_lockfile_local_path_remote_lines(lockfile_source)
        lockfile_source.each_line.with_index(1).filter_map do |line, line_number|
          next if line == "  remote: .\n"

          line_number if line.start_with?("  remote: /", "  remote: .", "  remote: ./", "  remote: ../")
        end
      end

      def checksum_line_for(lockfile_source:, member:)
        in_checksums = false
        lockfile_source.each_line do |line|
          stripped = line.chomp
          if stripped == "CHECKSUMS"
            in_checksums = true
            next
          end
          next unless in_checksums
          break if !stripped.empty? && stripped == stripped.upcase && !stripped.start_with?(" ")

          return stripped if stripped.start_with?("  #{member.name} (#{member.version})")
        end
        nil
      end

      def lockfile_checksum_entries(lockfile_source)
        in_checksums = false
        entries = {}
        lockfile_source.each_line do |line|
          stripped = line.chomp
          if stripped == "CHECKSUMS"
            in_checksums = true
            next
          end
          next unless in_checksums
          break if !stripped.empty? && stripped == stripped.upcase && !stripped.start_with?(" ")
          next unless stripped.start_with?("  ")

          parsed = parse_lockfile_spec_line(stripped)
          entries[[parsed.fetch(:name), parsed.fetch(:version)]] = parsed.fetch(:suffix) if parsed
        end
        in_checksums ? entries : nil
      end

      def lockfile_gem_specs(lockfile_source)
        in_gem = false
        in_specs = false
        specs = []
        lockfile_source.each_line do |line|
          stripped = line.chomp
          if stripped == "GEM"
            in_gem = true
            in_specs = false
            next
          end
          next unless in_gem
          break if !stripped.empty? && stripped == stripped.upcase && !stripped.start_with?(" ")

          if stripped == "  specs:"
            in_specs = true
            next
          end
          next unless in_specs
          next unless line.start_with?("    ") && !line.start_with?("      ")

          parsed = parse_lockfile_spec_line(stripped)
          specs << [parsed.fetch(:name), parsed.fetch(:version)] if parsed
        end
        specs.uniq
      end

      def parse_lockfile_spec_line(line)
        stripped = line.to_s.strip
        return nil if stripped.empty? || !stripped.include?(" (")

        name, remainder = stripped.split(" (", 2)
        version, suffix = remainder.to_s.split(")", 2)
        return nil if name.to_s.empty? || version.to_s.empty?

        {name: name, version: version, suffix: suffix.to_s.strip}
      end

      def annotate_dependency_floor_lockfile_result(result, attempts)
        return unless result

        if result.ok?
          message = "refreshed dependency floor lockfiles after #{attempts} attempt(s)"
          result.stdout = [result.stdout, message].reject(&:empty?).join("\n")
        else
          result.reason = "dependency floor lockfile refresh failed after #{attempts} attempt(s)"
        end
      end

      def annotate_dependency_floor_ci_bundle_result(result, attempts, gemfile:)
        return unless result

        relative = File.basename(gemfile)
        if result.ok?
          message = "validated CI bundle #{relative} after #{attempts} attempt(s)"
          result.stdout = [result.stdout, message].reject(&:empty?).join("\n")
        else
          result.reason = "dependency floor CI bundle validation failed for #{relative} after #{attempts} attempt(s)"
        end
      end

      def commit_dependency_floor_changes(dependent_members:, runner:, memo:)
        by_name = members.to_h { |member| [member.name, member] }
        dependent_members.each do |member_name|
          member = by_name.fetch(member_name)
          memo << runner.call(
            member: member,
            phase: "commit_dependency_floor",
            command: [
              "sh",
              "-lc",
              "files=$(git ls-files --modified --others --exclude-standard -- '*.gemspec' Gemfile.lock); " \
                "if [ -n \"$files\" ]; then git add -- $files && git commit -m '⬆️ Raise family dependency floors'; fi"
            ]
          )
          break unless memo.last.ok?
        end
      end

      def distinct_git_roots?(release_members)
        roots = release_members.map { |member| git_root_for(member) }
        roots.uniq.length == roots.length
      end

      def git_root_for(member)
        stdout, _stderr, status = Open3.capture3("git", "rev-parse", "--show-toplevel", chdir: member.root)
        status.success? ? stdout.strip : File.expand_path(member.root)
      end

      def rediscovered_selected_members(selected_names)
        discovered = Discovery.new(config: config).members
        ordered = Orderer.new(members: discovered, mode: config.order_mode, hints: config.order_hints).ordered
        ordered.select { |member| selected_names.include?(member.name) }
      rescue Error
        []
      end

      def member_local_branch_targets?
        members.any? { |member| member_local_release_config(member) }
      end

      def branch_targets
        targets = BranchTargetConfig.branch_targets_for(command, config.release_target_branches)
        slice_branch_targets(targets, start_branch)
      end

      def slice_branch_targets(targets, branch)
        return targets unless branch

        index = targets.index(branch)
        raise Error, "unknown branch target #{branch.inspect}" unless index

        targets.drop(index)
      end

      def member_local_release_config(member)
        BranchTargetConfig.member_release_config(member: member, config: config)
      end

      def checkout_branch_result(branch:, runner:)
        result = runner.call(
          member: family_member,
          phase: "release_checkout",
          command: ["git", "checkout", branch]
        )
        result.branch = branch
        result
      end

      def tag_branch_results(results, branch)
        results.each { |result| result.branch = branch if result.respond_to?(:branch=) }
      end

      def append_release_internal_checks(member:, memo:)
        memo << ReadinessCheck.call(member: member, config: config, allowed_local_path_roots: release_allowed_local_path_roots)
        memo << ChangelogCheck.call(member: member, config: config) if memo.last.ok?
      end

      def append_family_changelog_result(runner:, memo:)
        return unless config.release_family_changelog?

        member = family_changelog_member
        memo << runner.call(
          member: member,
          phase: "family_changelog",
          command: family_changelog_command,
          env: family_changelog_env
        )
      end

      def family_changelog_member
        return family_member unless config.shared_changelog?

        version_file = config.changelog_version_file.to_s
        raise Error, "shared root changelog release requires changelog.version_file" if version_file.empty?

        version_path = File.expand_path(version_file, config.root)
        member = members.find { |candidate| path_inside?(version_path, candidate.root) }
        return member if member

        raise Error, "shared root changelog version file #{version_file} is not inside any selected family member"
      end

      def family_changelog_env
        env = release_env.merge(config.changelog_env)
        return env unless config.shared_changelog?

        env.merge(
          "K_CHANGELOG_GEM_NAME" => config.family_name.to_s,
          "K_CHANGELOG_COVERAGE_ROOT" => File.expand_path(config.root),
          "K_CHANGELOG_PATH" => File.expand_path(config.changelog_path, config.root),
          "K_CHANGELOG_VERSION_FILE" => File.expand_path(config.changelog_version_file, config.root)
        )
      end

      def path_inside?(path, root)
        expanded_path = File.expand_path(path)
        expanded_root = File.expand_path(root)
        expanded_path == expanded_root || expanded_path.start_with?("#{expanded_root}#{File::SEPARATOR}")
      end

      def release_phase
        publish ? "release_publish" : "release_build"
      end

      def release_command
        command = raw_release_command
        kettle_release_command?(command) ? append_kettle_release_args(command) : command
      end

      def family_changelog_command
        command = config.release_family_changelog_command
        kettle_changelog_command?(command) ? append_kettle_changelog_args(command) : command
      end

      def raw_release_command
        publish ? config.release_publish_command : config.release_build_command
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

      def kettle_changelog_command?(command)
        case command
        when Array
          command.any? { |part| part.to_s.include?("kettle-changelog") }
        when String
          command.include?("kettle-changelog")
        else
          false
        end
      end

      def append_kettle_release_args(command)
        args = []
        args << "start_step=#{start_step}" if start_step
        args << "skip_steps=#{skip_steps}" if skip_steps && !skip_steps.to_s.empty?
        args << "--ci-workflows=#{ci_workflows}" if ci_workflows && !ci_workflows.to_s.empty?
        args << "--local-ci" if local_ci
        args << "--skip-bundle-audit" if skip_bundle_audit
        args << "--skip-remotes=#{skip_remotes}" if skip_remotes && !skip_remotes.to_s.empty?
        args << "--secrets-provider=1password" if release_command_uses_kettle_release_secrets? && !command_includes_arg?(command, "--secrets-provider")
        args << "--yes" if release_command_uses_kettle_release_yes? && !command_includes_arg?(command, "--yes")
        args << "--events" unless command_includes_arg?(command, "--events")
        return command if args.empty?

        command.is_a?(Array) ? [*command, *args] : "#{command} #{args.join(" ")}"
      end

      def release_command_uses_kettle_release_yes?
        accept && kettle_release_command?(raw_release_command)
      end

      def append_kettle_changelog_args(command)
        return command unless accept
        return command if command_includes_arg?(command, "--yes")

        command.is_a?(Array) ? [*command, "--yes"] : "#{command} --yes"
      end

      def validate_ci_workflows(value)
        return nil if value.nil? || value.to_s.empty?

        workflows = value.to_s.split(",").map(&:strip)
        invalid = workflows.find { |workflow| workflow.empty? || !workflow.match?(/\A[A-Za-z0-9_.\/-]+\z/) }
        raise Error, "invalid --ci-workflows value #{value.inspect}" if invalid

        workflows.join(",")
      end

      def validate_skip_remotes(value)
        return nil if value.nil? || value.to_s.empty?

        remotes = value.to_s.split(",").map(&:strip)
        invalid = remotes.find { |remote| remote.empty? || !remote.match?(/\A[A-Za-z0-9_.-]+\z/) }
        raise Error, "invalid --skip-remotes value #{value.inspect}" if invalid

        remotes.join(",")
      end

      def release_env
        env = base_release_env
        env.merge!(env_overrides)
        env
      end

      def base_release_env
        env = config.release_env
        env["KETTLE_FAMILY_CONFIG"] = config.path if config.path
        env.merge!(TEMPLATE_QUIET_ENV) unless debug
        env["K_RELEASE_CI_CONTINUE"] = "true" if continue_ci_failures
        env["K_RELEASE_CI_WORKFLOWS"] = ci_workflows if ci_workflows && !ci_workflows.to_s.empty?
        env["KETTLE_DEV_SKIP_BUNDLE_AUDIT"] = "true" if skip_bundle_audit
        env["K_RELEASE_SKIP_REMOTES"] = skip_remotes if skip_remotes && !skip_remotes.to_s.empty?
        env.merge!(kettle_release_secrets_env)
        env
      end

      def kettle_release_secrets_env
        return {} unless release_command_uses_kettle_release_secrets?

        secrets_config = config.release_secrets
        env = {
          "KETTLE_RELEASE_SECRETS_PROVIDER" => "1password",
          "KETTLE_RELEASE_GEM_SIGNING_PASSPHRASE_SOURCE" => "cached",
          "KETTLE_RELEASE_GEM_SIGNING_PASSPHRASE" => @gem_signing_password.to_s
        }
        {
          "account" => "KETTLE_RELEASE_1PASSWORD_ACCOUNT",
          "cli" => "KETTLE_RELEASE_1PASSWORD_CLI",
          "item" => "KETTLE_RELEASE_1PASSWORD_ITEM",
          "gem_signing_passphrase_field" => "KETTLE_RELEASE_1PASSWORD_GEM_SIGNING_PASSPHRASE_FIELD",
          "rubygems_otp_field" => "KETTLE_RELEASE_1PASSWORD_RUBYGEMS_OTP_FIELD",
          "gem_signing_passphrase_reference" => "KETTLE_RELEASE_1PASSWORD_GEM_SIGNING_PASSPHRASE_REFERENCE",
          "rubygems_otp_reference" => "KETTLE_RELEASE_1PASSWORD_RUBYGEMS_OTP_REFERENCE"
        }.each do |key, env_key|
          value = secrets_config.fetch(key, "").to_s
          env[env_key] = value unless value.empty?
        end
        env
      end

      def release_command_uses_kettle_release_secrets?
        kettle_release_supports_direct_secrets? &&
          kettle_release_command?(raw_release_command) &&
          release_secrets_provider_one_password?
      end

      def release_secrets_provider_one_password?
        if defined?(Kettle::Dev::ReleaseSecrets::OnePassword) && @secrets_provider.is_a?(Kettle::Dev::ReleaseSecrets::OnePassword)
          return true
        end

        defined?(Kettle::Family::Secrets::OnePassword) &&
          @secrets_provider.is_a?(Kettle::Family::Secrets::OnePassword)
      end

      def kettle_release_supports_direct_secrets?
        defined?(Kettle::Dev::ReleaseSecrets)
      end

      def append_release_git_phases(member:, runner:, memo:)
        append_pre_push_lockfile_normalization(member: member, runner: runner, memo: memo) if tag || push
        return if memo.any? && !memo.last.ok?

        memo << runner.call(member: member, phase: "release_tag", command: config.release_tag_command) if tag
        return if memo.any? && !memo.last.ok?

        memo << runner.call(member: member, phase: "release_push", command: config.release_push_command) if push
      end

      def append_pre_push_lockfile_normalization(member:, runner:, memo:)
        return unless normalize_release_lockfiles?(member)

        normalize_release_lockfiles(member: member, runner: runner, memo: memo)
        return unless memo.last&.ok?

        commit_normalized_lockfiles(branch_members: [member], runner: runner, memo: memo, reason: "release", force: true)
      end

      def skip_already_released?(member)
        publish && execute && released_version?(member.name, member.version)
      end

      def released_version?(gem_name, version)
        data = Kettle::Dev::RubyGemsVersions.fetch(gem_name, version_hint: version)
        raise Error, "could not check published versions for #{gem_name}" unless data.is_a?(Array)

        data.any? { |entry| entry["number"].to_s == version.to_s }
      rescue JSON::ParserError => error
        raise Error, "could not parse published versions for #{gem_name}: #{error.message}"
      rescue => error
        raise Error, "could not check published versions for #{gem_name}: #{error.message}"
      end

      def emit_dependency_floor_lockfile_progress(member:, attempt:)
        @release_progress&.update(member, status: "lockfiles #{attempt}/#{REGISTRY_WAIT_ATTEMPTS}", mark: ">")
      end

      def emit_dependency_floor_ci_bundle_progress(member:, gemfile:, attempt:)
        relative = relative_path_from_member_root(member: member, path: gemfile)
        @release_progress&.update(member, status: "ci bundle #{relative} #{attempt}/#{REGISTRY_WAIT_ATTEMPTS}", mark: ">")
      end

      def already_released_result(member)
        tag = release_tag_name(member.version)
        current_release_head = released_version_current_head?(member, tag)
        if current_release_head
          stdout = "#{member.name} #{member.version} is already published and current HEAD matches #{tag}; skipping release"
          reason = "already released"
          skipped = true
        elsif unreleased_changes_pending?(member)
          stdout = "#{member.name} #{member.version} is already published, but release-state reports unreleased changes. " \
            "Bump the version with `kettle-family bump patch --execute --only #{member.name}` before releasing."
          reason = "published version has unreleased changes"
          skipped = false
        else
          stdout = "#{member.name} #{member.version} is already published, current HEAD is newer than #{tag}, " \
            "and release-state reports no unreleased changes; skipping release"
          reason = "already released; no unreleased changes"
          skipped = true
        end

        CommandResult.new(
          member_name: member.name,
          phase: "release_skip",
          command: ["internal", "released-version-check", member.version],
          workdir: member.root,
          status: skipped ? 0 : 1,
          success: skipped,
          stdout: stdout,
          stderr: "",
          elapsed_seconds: 0.0,
          skipped: skipped,
          reason: reason
        )
      end

      def unreleased_changes_pending?(member)
        results = ReleaseStateCheck.new(members: [member], config: config).results
        return true unless results.all?(&:ok?)

        results.any? { |result| result.state.fetch("unreleased_entries", true) }
      end

      def release_tag_name(version)
        "v#{version}"
      end

      def released_version_current_head?(member, tag)
        return true unless git_work_tree?(member.root)

        tag_sha = git_rev_parse(member.root, "refs/tags/#{tag}^{}")
        head_sha = git_rev_parse(member.root, "HEAD")
        !tag_sha.to_s.empty? && tag_sha == head_sha
      end

      def git_work_tree?(root)
        _stdout, _stderr, status = Open3.capture3("git", "rev-parse", "--is-inside-work-tree", chdir: root)
        status.success?
      end

      def git_rev_parse(root, ref)
        stdout, _stderr, status = Open3.capture3("git", "rev-parse", "--verify", ref, chdir: root)
        status.success? ? stdout.strip : nil
      end

      def gem_signing_required?
        !ENV.fetch("SKIP_GEM_SIGNING", "").casecmp("true").zero?
      end

      def release_signing_prompt_required?
        return false unless gem_signing_required?
        return false if @gem_signing_password && !@gem_signing_password.to_s.empty?
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

        @gem_signing_password = @secrets_provider.gem_signing_passphrase.to_s
        return unless @gem_signing_password.empty?

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
        return bup_command if command == "bup"
        return bex_command if command == "bex"

        command_for(command)
      end

      def bup_command
        args = Array(bup_args).map(&:to_s).reject(&:empty?)
        return ["bundle", "update", "--all"] if args.empty?

        ["bundle", "update", *args]
      end

      def bex_command
        ["bundle", "exec", *Array(bex_args).map(&:to_s)]
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
        command_text = localize_kettle_jem_template_command(command_text)
        command_text = append_template_family_args(command_text) if kettle_jem_template_command?(command_text)
        append_template_skip_commit(command_text)
      end

      def template_prepare_command(member)
        command_text = template_prepare_command_from(config.template_command || default_template_command(member))
        command_text = localize_kettle_jem_template_command(command_text)
        command_text = append_template_family_args(command_text)
        append_template_skip_commit(command_text)
      end

      def template_prepare_command_from(command_text)
        if command_text.is_a?(Array)
          argv = command_text.map(&:to_s)
          index = argv.index("install")
          return argv unless index

          argv[index] = "prepare"
          argv
        else
          command_text.to_s.sub(/\bkettle-jem\s+install\b/, "kettle-jem prepare")
        end
      end

      def append_template_skip_commit(command_text)
        return command_text unless template_skip_commit?(command_text)
        return command_text if command_text.is_a?(Array) && command_text.include?("--skip-commit")
        return [*command_text, "--skip-commit"] if command_text.is_a?(Array)
        return command_text if command_text.include?("--skip-commit")

        "#{command_text} --skip-commit"
      end

      def template_skip_commit?(command_text)
        !commit || deferred_monorepo_template_commit?(command_text: command_text)
      end

      def deferred_monorepo_template_commit?(member = nil, command_text: nil)
        command_text ||= config.template_command || (member ? default_template_command(member) : DEFAULT_COMMANDS.fetch("template"))
        execute && commit && monorepo_template? && kettle_jem_template_command?(command_text)
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
          env.merge!(workflow_family_local_path_env)
          if command == "template"
            env["KETTLE_JEM_TEMPLATE_PROFILE"] = config.template_profile if config.template_profile
            env["KJ_REPOSITORY_TOPOLOGY"] = config.template_repository_topology if config.template_repository_topology
            if monorepo_template?
              template_git_lock_path = template_git_commit_lock_path
              env["KETTLE_JEM_GIT_LOCK"] = template_git_lock_path
              env["KETTLE_JEM_GIT_COMMIT_LOCK"] = template_git_lock_path
            end
            corporate_sponsors = config.readme_corporate_sponsors
            unless corporate_sponsors.empty?
              env["KETTLE_JEM_CORPORATE_SPONSORS_JSON"] = JSON.generate(corporate_sponsors)
            end
          end
          env.merge!(env_overrides)
          if command == "template" && verbose
            env["KETTLE_JEM_VERBOSE"] = "true"
          elsif command == "template" && !debug
            env.merge!(TEMPLATE_QUIET_ENV)
          end
        end
      end

      def workflow_family_local_path_env
        return {} if implicit_single_member_template_root?

        config.family_local_path_env
      end

      def implicit_single_member_template_root?
        return false unless command == "template"
        return false if config.path
        return false unless config.family_mode == "monorepo"
        return false unless members.one?
        return false unless File.expand_path(config.members_root) == File.expand_path(config.root)
        return false unless File.expand_path(members.first.root) == File.expand_path(config.root)

        family_env_name = config.family_local_path_env_name
        family_env_name && !env_overrides.key?(family_env_name)
      end

      def command_env
        return bundle_update_env if %w[bup bupb].include?(command)

        workflow_env
      end

      def bundle_update_env
        workflow_env.merge(release_lockfile_local_path_env_overrides)
      end

      def monorepo_template?
        command == "template" && config.family_mode == "monorepo"
      end

      def template_git_commit_lock_path
        File.join(git_common_dir(config.root), "kettle-family-template-commit.lock")
      end

      def git_common_dir(root)
        stdout, _stderr, status = Open3.capture3("git", "rev-parse", "--git-common-dir", chdir: root)
        return File.expand_path(stdout.strip, root) if status.success? && !stdout.strip.empty?

        File.join(root, ".git")
      end

      def kettle_jem_template_command?(command_text)
        if command_text.is_a?(Array)
          command_text.map(&:to_s).any? { |token| token == "kettle-jem" || File.basename(token) == "kettle-jem" }
        else
          command_text.to_s.include?("kettle-jem")
        end
      end

      def localize_kettle_jem_template_command(command_text)
        executable = local_kettle_jem_executable
        return command_text unless executable

        if command_text.is_a?(Array)
          argv = command_text.map(&:to_s)
          index = argv.index("kettle-jem")
          return command_text unless index

          argv[0...index] + [RbConfig.ruby, executable] + argv[(index + 1)..]
        else
          command_text.to_s.sub(/\bkettle-jem\b/, "#{Shellwords.escape(RbConfig.ruby)} #{Shellwords.escape(executable)}")
        end
      end

      def local_kettle_jem_executable
        root = template_local_kettle_jem_root
        return nil unless root

        candidate = File.join(root, "kettle-jem", "exe", "kettle-jem")
        File.file?(candidate) ? candidate : nil
      end

      def template_local_kettle_jem_root
        values = [
          env_overrides["STRUCTUREDMERGE_DEV"],
          workflow_family_local_path_env["STRUCTUREDMERGE_DEV"],
          ENV["STRUCTUREDMERGE_DEV"]
        ].compact.map(&:to_s).map(&:strip)
        values.find do |value|
          !value.empty? &&
            !%w[false 0 no off].include?(value.downcase) &&
            File.directory?(File.join(value, "kettle-jem"))
        end
      end

      def append_template_family_args(command_text)
        args = []
        if verbose
          args << "--verbose" unless command_includes_arg?(command_text, "--verbose")
        else
          args << "--quiet" unless command_includes_arg?(command_text, "--quiet")
        end
        args << "--events" unless command_includes_arg?(command_text, "--events")
        append_command_args(command_text, args)
      end

      def start_template_progress(workflow_members)
        progress = WorkflowProgress.new(
          io: progress_io,
          label: "templating",
          total: workflow_members.length,
          jobs: template_jobs(workflow_members),
          members: workflow_members
        )
        progress.start
        progress
      end

      def start_release_progress(release_members)
        progress = WorkflowProgress.new(
          io: progress_io,
          label: release_progress_label,
          total: release_members.length,
          jobs: release_jobs(release_members),
          members: release_members
        )
        progress.start
        progress
      end

      def template_phase_total(member = nil)
        total = 1
        total += 2 if config.normalize_lockfiles?
        total += 1 if member.nil? || template_prepares_dependencies?(member)
        total += 1 if deferred_monorepo_template_commit?(member)
        total
      end

      def release_phase_total
        total = 3
        total += 2 if config.release_normalize_lockfiles?
        total += 1 if tag
        total += 1 if push
        total
      end

      def release_progress_label
        if release_phase == "release_publish"
          "publishing"
        else
          "releasing"
        end
      end

      def template_initial_status(member = nil)
        return "prepare_lockfiles" if config.normalize_lockfiles?
        return "prepare_template_dependencies" if member.nil? || template_prepares_dependencies?(member)

        "template"
      end

      def template_prepares_dependencies?(member)
        command_text = config.template_command || default_template_command(member)
        kettle_jem_template_command?(command_text)
      end

      def emit_member_result_progress(member, result, progress:)
        return unless result

        progress&.advance(member, status: result.phase, success: result.ok?, mark: command_result_progress_mark(result))
      end

      def command_result_progress_mark(result)
        return "S" if result.skipped

        result.ok? ? "." : "F"
      end

      def template_member_finish_status(result)
        changed_files = template_changed_file_count(result)
        "#{changed_files} file#{"s" unless changed_files == 1} changed"
      end

      def release_member_finish_status(result)
        result.skipped ? "skipped #{result.phase}" : result.phase
      end

      def emit_template_progress_summary(results, progress:)
        return unless progress

        template_results = results.select { |result| result.phase == "template" }
        changed_files = template_results.sum { |result| template_changed_file_count(result) }
        progress.stop
        progress.summary("template summary: #{template_results.count(&:ok?)}/#{template_results.length} members ok, #{changed_files} file#{"s" unless changed_files == 1} changed")
      end

      def emit_release_progress_summary(results, progress:)
        return unless progress

        release_results = results.select { |result| result.phase == release_phase || result.phase == "release_skip" }
        progress.stop
        progress.summary("release summary: #{release_results.count(&:ok?)}/#{release_results.length} members ok")
      end

      def emit_release_preflight_start(phases)
        return unless progress_io

        phase_label = (phases.length == 1) ? "phase" : "phases"
        progress_io.puts("release preflight #{phases.length} #{phase_label}:")
        progress_io.flush
      end

      def emit_release_preflight_phase(label, index:, total:)
        return unless progress_io

        progress_io.puts("[release preflight] (#{index + 1}/#{total}) > #{label}")
        progress_io.flush
      end

      def emit_release_preflight_phase_finish(label, results)
        return unless progress_io

        mark = results.empty? ? "." : "F"
        progress_io.puts("[release preflight] #{mark} #{label}")
        progress_io.flush
      end

      def emit_release_preflight_summary(phases)
        return unless progress_io

        progress_io.puts("release preflight summary: #{phases.length}/#{phases.length} phases ok")
        progress_io.flush
      end

      def template_event_line_handler(member, progress: nil)
        lambda do |line|
          event = parse_template_event(line)
          next false unless event

          if progress_io
            if verbose || debug
              emit_template_event_progress(member, event)
            elsif progress&.tty?
              emit_template_event_status(member, event, progress: progress)
            end
          end
          true
        end
      end

      def release_event_line_handler(member, progress: nil)
        lambda do |line|
          event = parse_template_event(line)
          next false unless event

          if progress_io
            if verbose || debug
              emit_release_event_progress(member, event)
            elsif progress&.tty?
              emit_release_event_status(member, event, progress: progress)
            end
          end
          true
        end
      end

      def parse_template_event(line)
        payload = JSON.parse(line.to_s)
        (payload.is_a?(Hash) && payload["event_version"]) ? payload : nil
      rescue JSON::ParserError
        nil
      end

      def emit_template_event_progress(member, event)
        case event["type"]
        when "phase_start"
          emit_template_event_line(member, ">", event["phase"].to_s)
        when "phase_finish"
          emit_template_event_line(member, phase_finish_event_mark(event), event["phase"].to_s)
        when "recipe"
          path = event["path"].to_s
          emit_template_event_line(member, template_event_mark(event, changed_mark: "*"), path)
        when "post_apply_step", "command_step"
          label = [event["phase"], event["name"]].map(&:to_s).reject(&:empty?).join(":")
          emit_template_event_line(member, template_event_mark(event), label)
        when "diagnostic"
          emit_template_event_line(member, "!", diagnostic_event_label(event))
        when "summary"
          emit_template_event_line(member, "done", "#{event["changed_count"].to_i} file#{"s" unless event["changed_count"].to_i == 1} changed")
        end
      end

      def emit_template_event_status(member, event, progress:)
        status = case event["type"]
        when "phase_start", "phase_finish"
          event["phase"].to_s
        when "recipe"
          event["path"].to_s
        when "post_apply_step", "command_step"
          [event["phase"], event["name"]].map(&:to_s).reject(&:empty?).join(":")
        when "diagnostic"
          diagnostic_event_label(event)
        when "summary"
          "#{event["changed_count"].to_i} file#{"s" unless event["changed_count"].to_i == 1} changed"
        end
        mark = template_event_status_mark(event)
        progress&.update(member, status: status, mark: mark) if status && !status.empty?
      end

      def emit_release_event_progress(member, event)
        case event["type"]
        when "run_start"
          emit_template_event_line(member, ">", "release")
        when "command_step"
          label = [event["phase"], event["name"]].map(&:to_s).reject(&:empty?).join(":")
          emit_template_event_line(member, template_event_mark(event), label)
        when "diagnostic"
          emit_template_event_line(member, "!", diagnostic_event_label(event))
        when "summary"
          emit_template_event_line(member, phase_finish_event_mark(event), event["status"].to_s)
        end
      end

      def emit_release_event_status(member, event, progress:)
        status = case event["type"]
        when "run_start"
          "release"
        when "command_step"
          [event["phase"], event["name"]].map(&:to_s).reject(&:empty?).join(":")
        when "diagnostic"
          diagnostic_event_label(event)
        when "summary"
          event["status"].to_s
        end
        mark = release_event_status_mark(event)
        progress&.update(member, status: status, mark: mark) if status && !status.empty?
      end

      def release_event_status_mark(event)
        case event["type"]
        when "run_start"
          ">"
        when "command_step"
          template_event_mark(event)
        when "diagnostic"
          "!"
        when "summary"
          phase_finish_event_mark(event)
        end
      end

      def template_event_status_mark(event)
        case event["type"]
        when "phase_start"
          ">"
        when "phase_finish"
          phase_finish_event_mark(event)
        when "recipe"
          template_event_mark(event, changed_mark: "*")
        when "post_apply_step", "command_step"
          template_event_mark(event)
        when "diagnostic"
          "!"
        end
      end

      def diagnostic_event_label(event)
        message = event["message"]
        return message.to_s unless message.to_s.empty? || message.is_a?(Hash)

        kind = event["kind"].to_s
        return kind unless kind.empty?
        return "diagnostic" unless message.is_a?(Hash)

        nested_kind = message["kind"].to_s
        nested_kind.empty? ? "diagnostic" : nested_kind
      end

      def emit_template_event_line(member, mark, label)
        return if label.to_s.empty?

        synchronize_template_progress do
          progress_io.puts("[#{member.name}] #{mark} #{label}")
          progress_io.flush if progress_io.respond_to?(:flush)
        end
      end

      def template_event_mark(event, changed_mark: ".")
        mark = event["mark"].to_s
        return mark unless mark.empty?

        event["changed"] ? changed_mark : "."
      end

      def phase_finish_event_mark(event)
        return "F" if event["status"].to_s == "failed"

        "."
      end

      def synchronize_template_progress(&block)
        @template_progress_mutex ||= Mutex.new
        @template_progress_mutex.synchronize(&block)
      end

      def template_changed_file_count(result)
        event_count = template_changed_file_count_from_events(result.stdout)
        return event_count if event_count

        payload = JSON.parse(result.stdout.to_s)
        Array(payload["changed_files"] || payload[:changed_files]).length if payload.is_a?(Hash)
      rescue JSON::ParserError
        match = result.stdout.to_s.match(/(?:install|apply|prepare|template):\s+(\d+)\s+changed file/)
        return match[1].to_i if match

        0
      end

      def template_changed_file_count_from_events(output)
        summaries = output.to_s.lines.filter_map do |line|
          event = parse_template_event(line)
          event if event && event["type"] == "summary"
        end
        return nil if summaries.empty?

        changed_files = summaries.flat_map { |event| Array(event["changed_files"] || event[:changed_files]) }
        changed_files = changed_files.map(&:to_s).reject(&:empty?).uniq
        return changed_files.length unless changed_files.empty?

        summary = summaries.reverse.find { |event| event.key?("changed_count") }
        summary&.fetch("changed_count")&.to_i
      end

      def normalize_lockfiles(member:, runner:, memo:, phase:)
        return unless config.normalize_lockfiles?

        result = runner.call(
          member: member,
          phase: phase,
          command: normalize_lockfiles_command(member: member, phase: phase),
          env: workflow_env
        )
        if template_prepare_lockfiles_phase?(phase) && repair_checksum_mismatches(member, result)
          result = runner.call(
            member: member,
            phase: phase,
            command: normalize_lockfiles_command(member: member, phase: phase),
            env: workflow_env
          )
        end
        memo << result
      end

      def normalize_lockfiles_command(member:, phase:)
        configured = config.normalize_lockfiles_command
        return configured unless template_prepare_lockfiles_phase?(phase)
        return %w[bundle install] if bundle_update_command?(configured) && !File.file?(File.join(member.root, "Gemfile.lock"))

        PRE_TEMPLATE_BOOTSTRAP_GEMS.select { |gem_name| member_lockfile_contains_gem?(member, gem_name) }.reduce(configured) do |command_text, gem_name|
          append_command_arg(command_text, gem_name)
        end
      end

      def bundle_update_command?(command_text)
        argv = command_text.is_a?(Array) ? command_text.map(&:to_s) : Shellwords.split(command_text.to_s)
        bundle_index = argv.index("bundle")
        bundle_index && argv[bundle_index + 1] == "update"
      rescue ArgumentError
        false
      end

      def append_command_arg(command_text, arg)
        return command_text if normalize_command_includes_arg?(command_text, arg)

        argv = command_text.is_a?(Array) ? command_text.map(&:to_s) : Shellwords.split(command_text.to_s)
        update_index = argv.index("update")
        if update_index
          option_index = argv[(update_index + 1)..]&.index { |token| token.start_with?("-") }
          insert_index = option_index ? update_index + 1 + option_index : argv.length
          argv.insert(insert_index, arg)
        else
          argv << arg
        end
        return argv if command_text.is_a?(Array)

        argv.shelljoin
      rescue ArgumentError
        "#{command_text} #{Shellwords.escape(arg)}"
      end

      def normalize_command_includes_arg?(command_text, arg)
        argv = if command_text.is_a?(Array)
          command_text.map(&:to_s)
        else
          Shellwords.split(command_text.to_s)
        end
        argv.include?(arg)
      rescue ArgumentError
        false
      end

      def member_lockfile_contains_gem?(member, gem_name)
        lockfile = File.join(member.root, "Gemfile.lock")
        return false unless File.file?(lockfile)

        File.readlines(lockfile).any? { |line| line.match?(/\A    #{Regexp.escape(gem_name)} \(/) }
      end

      def template_prepare_lockfiles_phase?(phase)
        command == "template" && phase == "prepare_lockfiles"
      end

      def repair_checksum_mismatches(member, result)
        return false unless execute
        return false if result.ok?

        line_numbers = checksum_mismatch_lockfile_lines(result.stderr)
        return false if line_numbers.empty?

        lockfile = File.join(member.root, "Gemfile.lock")
        return false unless File.file?(lockfile)

        lines = File.readlines(lockfile)
        line_numbers.sort.reverse_each do |line_number|
          index = line_number - 1
          lines.delete_at(index) if index >= 0 && index < lines.length
        end
        File.write(lockfile, lines.join)
        true
      end

      def checksum_mismatch_lockfile_lines(output)
        output.to_s.scan(/from the lockfile CHECKSUMS at Gemfile\.lock:(\d+):\d+/).flatten.map(&:to_i).uniq
      end

      def prepare_template_dependencies(member:, runner:, memo:)
        command_text = config.template_command || default_template_command(member)
        return true unless kettle_jem_template_command?(command_text)

        result = runner.call(
          member: member,
          phase: "prepare_template_dependencies",
          command: template_prepare_command(member),
          env: template_prepare_env
        )
        memo << result
        result.ok?
      end

      def commit_template_changes(member:, runner:, memo:)
        return unless deferred_monorepo_template_commit?(member)
        return unless memo.all?(&:ok?)

        synchronize_template_commit do
          memo << runner.call(
            member: member,
            phase: "commit_template",
            command: [
              "sh",
              "-lc",
              "if [ -n \"$(git status --porcelain -- .)\" ]; then " \
                "git add -A -- . && git commit -m #{Shellwords.escape(template_commit_message(member))}; " \
                "fi"
            ],
            env: workflow_env
          )
        end
      end

      def template_commit_message(member)
        "🎨 Template #{member.name} by kettle-family"
      end

      def synchronize_template_commit(&block)
        @template_commit_mutex.synchronize do
          lock_path = monorepo_template? ? template_git_commit_lock_path : nil
          if lock_path
            FileUtils.mkdir_p(File.dirname(lock_path))
            File.open(lock_path, File::RDWR | File::CREAT, 0o644) do |lock|
              lock.flock(File::LOCK_EX)
              block.call
            ensure
              lock&.flock(File::LOCK_UN)
            end
          else
            block.call
          end
        end
      end

      def template_prepare_env
        env = workflow_env
        family_env_name = config.family_local_path_env_name
        env[family_env_name] = "false" if family_env_name && !env_overrides.key?(family_env_name)
        env
      end

      def normalize_release_lockfiles(member:, runner:, memo:)
        result = runner.call(
          member: member,
          phase: "release_normalize_lockfiles",
          command: config.release_normalize_lockfiles_command,
          env: release_lockfile_env(member)
        )
        memo << result
      end

      def normalize_release_lockfiles?(member)
        config.release_normalize_lockfiles? || release_lockfile_has_local_path_remote?(member)
      end

      def release_lockfile_has_local_path_remote?(member)
        lockfile = File.join(member.root, "Gemfile.lock")
        return false unless File.file?(lockfile)

        File.readlines(lockfile).any? do |line|
          line.start_with?("  remote: /", "  remote: ./", "  remote: ../")
        end
      end

      def release_lockfile_env(member = nil)
        base_release_env
          .merge(release_lockfile_bundler_env_resets)
          .merge(env_overrides)
          .merge(release_lockfile_local_path_env_overrides(member))
      end

      def release_lockfile_bundler_env_resets
        {
          "BUNDLE_GEMFILE" => nil,
          "BUNDLE_LOCKFILE" => nil
        }
      end

      def release_allowed_local_path_roots
        release_local_path_env_sources.filter_map do |key, value|
          next unless key.end_with?("_LOCAL", "_DEV")
          next unless local_path_env_value?(value)
          next unless value.to_s.strip.start_with?("/", "./", "../", "~")

          value
        end
      end

      def release_lockfile_local_path_env_overrides(member = nil)
        explicit = config.release_disable_local_path_env.to_h { |key| [key.to_s, "false"] }
        derived = release_local_path_env_detection_sources.each_with_object({}) do |(key, value), memo|
          key = key.to_s
          next unless key.end_with?("_LOCAL", "_DEV")
          next unless local_path_env_value?(value)

          memo[key] = "false"
        end
        inferred = member ? release_lockfile_inferred_local_path_env(member).to_h { |key| [key, "false"] } : {}
        explicit.merge(derived).merge(inferred)
      end

      def release_lockfile_inferred_local_path_env(member)
        release_lockfile_local_path_remotes(member).filter_map do |path|
          root = nearest_kettle_family_root(path)
          next unless root

          inferred_family_local_path_env_name(root)
        end.uniq
      end

      def release_lockfile_local_path_remotes(member)
        lockfile = File.join(member.root, "Gemfile.lock")
        return [] unless File.file?(lockfile)

        File.readlines(lockfile).filter_map do |line|
          next unless line.start_with?("  remote: /", "  remote: ./", "  remote: ../")

          remote = line.split("remote:", 2).last.to_s.strip
          expanded = File.expand_path(remote, member.root)
          File.realpath(expanded)
        rescue Errno::ENOENT
          expanded
        end
      end

      def nearest_kettle_family_root(path)
        current = File.directory?(path) ? path : File.dirname(path)
        loop do
          return current if File.file?(File.join(current, ".kettle-family.yml"))

          parent = File.dirname(current)
          return nil if parent == current

          current = parent
        end
      end

      def inferred_family_local_path_env_name(root)
        data = YAML.load_file(File.join(root, ".kettle-family.yml")) || {}
        family = data.fetch("family", {}) || {}
        configured = family["local_path_env"]
        return nil if configured == false
        return configured.to_s unless configured.to_s.empty?

        name = family["name"].to_s
        return nil if name.empty?

        "#{name.gsub(/[^A-Za-z0-9]+/, "_").upcase}_DEV"
      rescue Psych::SyntaxError, Errno::ENOENT
        nil
      end

      def release_local_path_env_sources
        ENV.to_h
          .merge(config.family_local_path_env)
          .merge(config.release_env)
          .merge(env_overrides)
      end

      def release_local_path_env_detection_sources
        ENV.to_h
          .merge(config.family_local_path_env)
          .merge(env_overrides)
      end

      def local_path_env_value?(value)
        text = value.to_s.strip
        return false if text.empty? || text.casecmp("false").zero?
        return true if %w[true yes 1 on enabled].include?(text.downcase)
        return true if text.start_with?("/", "./", "../", "~")

        text.include?(File::SEPARATOR)
      end

      def commit_normalized_lockfiles(branch_members:, runner:, memo:, reason: command, force: false)
        return unless commit
        return unless force || commit_normalized_lockfiles?(reason)

        branch_members.each do |member|
          result = runner.call(
            member: member,
            phase: "commit_normalized_lockfiles",
            command: [
              "sh",
              "-lc",
              "files=$(git ls-files --modified --others --exclude-standard -- Gemfile.lock '*.lock' '**/*.lock'); " \
                "if [ -n \"$files\" ]; then printf '%s\\n' \"$files\" | xargs git add -- && git commit -m " \
                "#{Shellwords.escape(normalized_lockfiles_commit_message(reason))}; fi"
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

      def normalized_lockfiles_commit_message(reason)
        case reason
        when "release"
          "🔒️ Normalize lockfiles before release"
        when "reset"
          "🔒️ Reset lockfiles"
        else
          "🔒️ Normalize lockfiles after templating"
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
            "if ! git diff --quiet -- .github/workflows; then git add -- .github/workflows && git commit -m '🔒️ Pin GitHub Actions SHAs'; fi"
          ]
        )
        memo << result
      end

      def commit_bundle_update(member:, runner:, memo:)
        return unless commit

        result = runner.call(
          member: member,
          phase: "commit_bundle_update",
          command: [
            "sh",
            "-lc",
            "files=$(git ls-files --modified --others --exclude-standard -- Gemfile.lock '*.lock' '**/*.lock'); " \
              "if [ -n \"$files\" ]; then printf '%s\\n' \"$files\" | xargs git add -- && git commit -m '🔒️ Update bundle'; fi"
          ]
        )
        memo << result
      end

      def validate_bundle_update_lockfile(member:, memo:)
        return true unless execute && commit

        diagnostics = bundle_update_lockfile_diagnostics(member)
        result = CommandResult.new(
          member.name,
          "bundle_update_readiness",
          ["internal", "bundle-update-readiness"],
          member.root,
          diagnostics.empty? ? 0 : 1,
          diagnostics.empty?,
          diagnostics.join("\n"),
          "",
          0.0,
          false,
          diagnostics.empty? ? nil : "bundle update produced release-invalid lockfile"
        )
        memo << result
        result.ok?
      end

      def bundle_update_lockfile_diagnostics(member)
        lockfile = File.join(member.root, "Gemfile.lock")
        return [] unless File.file?(lockfile)

        File.readlines(lockfile).filter_map.with_index(1) do |line, index|
          next unless line.start_with?("  remote: /", "  remote: ./", "  remote: ../")

          "release lockfile has local path remote at Gemfile.lock:#{index}"
        end
      end

      def commit_bex_changes(member:, runner:, memo:)
        return unless commit

        result = runner.call(
          member: member,
          phase: "commit_bex",
          command: [
            "sh",
            "-lc",
            "files=$(git ls-files --modified --others --exclude-standard); " \
              "if [ -n \"$files\" ]; then printf '%s\\n' \"$files\" | xargs git add -- && git commit -m '🔧 Run bundle exec command'; fi"
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
