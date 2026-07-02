# frozen_string_literal: true

require "io/console"
require "json"
require "net/http"
require "etc"
require "open3"
require "uri"

module Kettle
  module Family
    class Workflow
      DEFAULT_COMMANDS = {
        "template" => "bundle exec kettle-jem install",
        "test" => "bundle exec kettle-test",
        "lint" => "bundle exec rake rubocop_gradual",
        "docs" => "bundle exec rake yard",
        "gha-sha-pins" => "bundle exec kettle-gha-sha-pins",
        "bupb" => %w[bundle update --bundler]
      }.freeze
      GIT_SYNC_COMMANDS = {
        "push" => [["push", %w[git push]]],
        "pull" => [["pull", %w[git pull --rebase]]],
        "up" => [["pull", %w[git pull --rebase]], ["push", %w[git push]]]
      }.freeze
      TEMPLATE_QUIET_ENV = {
        "KETTLE_JEM_QUIET" => "true",
        "KETTLE_JEM_DEBUG" => "false",
        "KETTLE_DEV_DEBUG" => "false",
        "SMORG_RB_DEBUG" => "false",
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

      def initialize(command:, config:, members:, execute: false, accept: true, commit: true, allow_dirty: false, publish: false, push: false, tag: false, start_step: nil, skip_steps: nil, local_ci: false, continue_ci_failures: false, gha_sha_pins_upgrade: "patch", gha_sha_pins_check: false, env_overrides: {}, debug: false, gem_signing_password: nil, jobs: nil, progress_io: nil, bup_args: [], bex_args: [], start_member: nil, start_branch: nil)
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
        @gha_sha_pins_upgrade = gha_sha_pins_upgrade
        @gha_sha_pins_check = gha_sha_pins_check
        @env_overrides = env_overrides
        @debug = debug
        @gem_signing_password = gem_signing_password
        @jobs = jobs
        @progress_io = progress_io
        @bup_args = bup_args
        @bex_args = bex_args
        @start_member = start_member
        @start_branch = start_branch
      end

      def results
        preflight = branch_checkout_dirty_preflight_results
        return preflight unless preflight.empty?

        prompt_for_gem_signing_password if command == "release" && execute && release_signing_prompt_required?
        return branch_target_results unless config.release_target_branches.empty?
        return member_local_branch_target_results if member_local_branch_targets?

        current_branch_results(members)
      end

      private

      attr_reader :command, :config, :members, :execute, :accept, :commit, :allow_dirty, :publish, :push, :tag, :start_step, :skip_steps, :local_ci, :continue_ci_failures, :gha_sha_pins_upgrade, :gha_sha_pins_check, :env_overrides, :debug, :jobs, :progress_io, :bup_args, :bex_args, :start_member, :start_branch

      def current_branch_results(workflow_members)
        return check_results(workflow_members) if command == "check"
        return release_member_results(workflow_members, include_family_changelog: true) if command == "release"
        return git_sync_results(workflow_members) if GIT_SYNC_COMMANDS.key?(command)

        member_workflow_results(workflow_members)
      end

      def member_workflow_results(workflow_members)
        return template_member_workflow_results(workflow_members) if command == "template" && execute && template_jobs(workflow_members) > 1

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
          commit_bundle_update(member: member, runner: runner, memo: memo) if %w[bup bupb].include?(command)
          commit_bex_changes(member: member, runner: runner, memo: memo) if command == "bex"
        end
      end

      def template_member_workflow_results(workflow_members)
        queue = Queue.new
        workflow_members.each_with_index { |member, index| queue << [index, member] }
        ordered_results = Array.new(workflow_members.length)
        mutex = Mutex.new
        stop = false
        emit_template_progress_start(workflow_members)
        Array.new(template_jobs(workflow_members)) do
          Thread.new do # rubocop:disable ThreadSafety/NewThread -- family templating intentionally runs independent members concurrently.
            loop do
              break if mutex.synchronize { stop }
              index, member = queue.pop(true)
              member_results = template_results_for_member(member)
              mutex.synchronize do
                ordered_results[index] = member_results
                stop = true unless member_results.all?(&:ok?)
                emit_template_progress_mark(member_results)
              end
            rescue ThreadError
              break
            end
          end
        end.each(&:join)
        flattened = ordered_results.compact.flatten
        emit_template_progress_summary(flattened)
        flattened
      end

      def template_results_for_member(member)
        runner = CommandRunner.new(execute: execute, accept: accept)
        [].tap do |memo|
          if config.normalize_lockfiles?
            normalize_lockfiles(member: member, runner: runner, memo: memo, phase: "prepare_lockfiles")
            return memo unless memo.last.ok?
          end

          memo << runner.call(member: member, phase: command, command: workflow_command(member), env: workflow_env)
          return memo unless memo.last.ok?

          normalize_lockfiles(member: member, runner: runner, memo: memo, phase: "normalize_lockfiles")
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
          gha_sha_pins_upgrade: gha_sha_pins_upgrade,
          gha_sha_pins_check: gha_sha_pins_check,
          env_overrides: env_overrides,
          gem_signing_password: @gem_signing_password,
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

        release_members.each_with_object(results) do |member, memo|
          memo.concat(release_results_for_member(member, runner: runner))
          break memo unless memo.last.ok?
        end
      end

      def parallel_release_member_results(release_members, initial_results)
        results = initial_results.dup
        waves = release_waves(release_members)
        waves.each_with_index do |wave, index|
          results << release_wave_result(wave, index: index, total: waves.length)
          wave_results = run_release_wave(wave)
          results.concat(wave_results.flatten)
          break unless wave_results.all? { |member_results| member_results.all?(&:ok?) }
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
        [].tap do |memo|
          if skip_already_released?(member)
            memo << already_released_result(member)
            return memo
          end

          if config.release_normalize_lockfiles?
            normalize_release_lockfiles(member: member, runner: runner, memo: memo)
            return memo unless memo.last&.ok?

            commit_normalized_lockfiles(branch_members: [member], runner: runner, memo: memo, reason: "release")
            return memo unless memo.last&.ok?
          end

          append_release_internal_checks(member: member, memo: memo)
          return memo unless memo.last(2).all?(&:ok?)

          memo << runner.call(
            member: member,
            phase: release_phase,
            command: release_command,
            env: release_env,
            interactive: release_command_interactive?
          )
          return memo unless memo.last.ok?

          append_release_git_phases(member: member, runner: runner, memo: memo)
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
          accept: accept,
          gem_signing_password: @gem_signing_password,
          otp_coordinator: release_otp_coordinator
        )
      end

      def release_otp_coordinator
        return nil unless execute && release_command_interactive?

        @release_otp_coordinator ||= CommandRunner::OtpCoordinator.new
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
        by_name = release_members.to_h { |member| [member.name, member] }
        pending = by_name.keys
        completed = []
        waves = []
        until pending.empty?
          wave_names = pending.select do |name|
            selected_dependencies_for(by_name.fetch(name), by_name).all? { |dependency| completed.include?(dependency) }
          end
          raise Error, "cyclic release dependency order: #{pending.join(", ")}" if wave_names.empty?

          waves << wave_names.map { |name| by_name.fetch(name) }
          completed.concat(wave_names)
          pending -= wave_names
        end
        waves
      end

      def selected_dependencies_for(member, by_name)
        Array(member.dependencies).map(&:to_s).select { |dependency| by_name.key?(dependency) }
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
        args << "skip_steps=#{skip_steps}" if skip_steps && !skip_steps.to_s.empty?
        args << "--local-ci" if local_ci
        return command if args.empty?

        command.is_a?(Array) ? [*command, *args] : "#{command} #{args.join(" ")}"
      end

      def release_env
        env = base_release_env
        env.merge!(env_overrides)
        env
      end

      def base_release_env
        env = config.release_env.dup
        env.merge!(TEMPLATE_QUIET_ENV) unless debug
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
        tag = release_tag_name(member.version)
        current_release_head = released_version_current_head?(member, tag)
        if current_release_head
          stdout = "#{member.name} #{member.version} is already published and current HEAD matches #{tag}; skipping release"
          reason = "already released"
          skipped = true
        elsif release_pending?(member)
          stdout = "#{member.name} #{member.version} is already published, but current HEAD is not #{tag}. " \
            "Bump the version with `kettle-family bump-version patch --execute --only #{member.name}` before releasing."
          reason = "published version does not match current HEAD"
          skipped = false
        else
          stdout = "#{member.name} #{member.version} is already published and release-state reports no pending release; skipping release"
          reason = "already released; no pending release"
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

      def release_pending?(member)
        results = ReleaseStateCheck.new(members: [member], config: config).results
        return true unless results.all?(&:ok?)

        results.any? { |result| result.state.fetch("pending_release", true) }
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
        command_text = append_template_family_args(command_text) if kettle_jem_template_command?(command_text)
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
          env.merge!(TEMPLATE_QUIET_ENV) if command == "template" && !debug
        end
      end

      def kettle_jem_template_command?(command_text)
        command_text.is_a?(Array) ? command_text.map(&:to_s).include?("kettle-jem") : command_text.to_s.include?("kettle-jem")
      end

      def append_template_family_args(command_text)
        args = []
        args << "--quiet" unless command_includes_arg?(command_text, "--quiet")
        args << "--json" unless command_includes_arg?(command_text, "--json")
        append_command_args(command_text, args)
      end

      def emit_template_progress_start(workflow_members)
        return unless progress_io

        progress_io.puts("templating #{workflow_members.length} member#{"s" unless workflow_members.length == 1} with #{template_jobs(workflow_members)} job#{"s" unless template_jobs(workflow_members) == 1}:")
        progress_io.flush if progress_io.respond_to?(:flush)
      end

      def emit_template_progress_mark(member_results)
        return unless progress_io

        template_result = member_results.find { |result| result.phase == "template" } || member_results.last
        progress_io.print(template_result.ok? ? "." : "F")
        progress_io.flush if progress_io.respond_to?(:flush)
      end

      def emit_template_progress_summary(results)
        return unless progress_io

        template_results = results.select { |result| result.phase == "template" }
        changed_files = template_results.sum { |result| template_changed_file_count(result) }
        progress_io.puts
        progress_io.puts("template summary: #{template_results.count(&:ok?)}/#{template_results.length} members ok, #{changed_files} file#{"s" unless changed_files == 1} changed")
        progress_io.flush if progress_io.respond_to?(:flush)
      end

      def template_changed_file_count(result)
        payload = JSON.parse(result.stdout.to_s)
        Array(payload["changed_files"] || payload[:changed_files]).length if payload.is_a?(Hash)
      rescue JSON::ParserError
        match = result.stdout.to_s.match(/(?:install|apply|prepare|template):\s+(\d+)\s+changed file/)
        return match[1].to_i if match

        0
      end

      def normalize_lockfiles(member:, runner:, memo:, phase:)
        return unless config.normalize_lockfiles?

        result = runner.call(
          member: member,
          phase: phase,
          command: config.normalize_lockfiles_command,
          env: workflow_env
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
        base_release_env
          .merge(config.release_disable_local_path_env.to_h { |key| [key, "false"] })
          .merge(env_overrides)
      end

      def release_allowed_local_path_roots
        env_overrides.filter_map do |key, value|
          next unless key.end_with?("_LOCAL", "_DEV")
          next if value.to_s.empty? || value.to_s.casecmp("false").zero?

          value
        end
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

      def commit_bundle_update(member:, runner:, memo:)
        return unless commit

        result = runner.call(
          member: member,
          phase: "commit_bundle_update",
          command: [
            "sh",
            "-lc",
            "files=$(git ls-files --modified --others --exclude-standard -- Gemfile.lock '*.lock' '**/*.lock'); " \
              "if [ -n \"$files\" ]; then printf '%s\\n' \"$files\" | xargs git add -- && git commit -m '🔒 Update bundle'; fi"
          ]
        )
        memo << result
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
