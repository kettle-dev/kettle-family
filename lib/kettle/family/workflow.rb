# frozen_string_literal: true

require "io/console"
require "fileutils"
require "json"
require "etc"
require "open3"
require "pathname" # rubocop:disable Lint/RedundantRequireStatement -- Workflow uses Pathname directly and must load it when required standalone.
require "rbconfig"
require "shellwords"
require "yaml"
require "kettle/dev"

require_relative "workflow_progress"

module Kettle
  module Family
    class Workflow
      PreflightProgressMember = Struct.new(:name)

      DEFAULT_COMMANDS = {
        # kettle-jem owns the member bundle bootstrap, so it must not be
        # launched through that bundle. The standalone executable prepares the
        # templating dependencies before the member bundle can include them.
        "template" => "kettle-jem install",
        "test" => "bundle exec kettle-test",
        "lint" => "bundle exec rake rubocop_gradual",
        "docs" => "bundle exec rake yard",
        "gha-sha-pins" => "bundle exec kettle-gha-pins",
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
      TEMPLATE_AUTOSTASH_ALLOWED_DIRECTORIES = %w[lib spec test].freeze
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

      def initialize(command:, config:, members:, family_members: nil, execute: false, accept: true, commit: true, allow_dirty: false, autostash: true, template_cleanup: true, publish: false, push: false, tag: false, start_step: nil, skip_steps: nil, fast_recovery: nil, fast_recovery_members: nil, skip_ci: false, skip_changelog: false, local_ci: false, continue_ci_failures: false, ci_workflows: nil, skip_bundle_audit: false, skip_remotes: nil, required_remotes: nil, auto_dependency_floors: nil, validate_ci_bundles: nil, gha_sha_pins_upgrade: "patch", gha_sha_pins_check: false, gha_sha_pins_ttl_days: nil, env_overrides: {}, debug: false, verbose: false, gem_signing_password: nil, secrets_provider: nil, jobs: nil, progress_io: nil, reset_target: nil, bup_args: [], bex_args: [], start_member: nil, start_branch: nil, **options)
        @command = command
        @config = config
        @members = members
        @family_members = family_members || members
        @execute = execute
        @accept = accept
        @commit = commit
        @allow_dirty = allow_dirty
        @autostash = autostash
        @template_cleanup = template_cleanup
        @publish = publish
        @push = push
        @tag = tag
        @start_step = start_step
        @skip_steps = skip_steps
        @fast_recovery = normalize_fast_recovery(fast_recovery, publish: publish)
        if (@fast_recovery || skip_ci) && !kettle_release_command?(raw_release_command)
          raise Error, "named CI recovery requires a kettle-release publish command"
        end
        raise Error, "--skip-ci requires --publish" if skip_ci && !publish
        if @fast_recovery && (start_step || (skip_steps && !skip_steps.to_s.empty?) || skip_ci)
          raise Error, "--fast-recovery cannot be combined with --start-step, --skip-steps, or --skip-ci"
        end
        if fast_recovery_members_given?(fast_recovery_members) && !@fast_recovery
          raise Error, "--fast-recovery-members requires --fast-recovery"
        end
        @fast_recovery_members = normalize_fast_recovery_members(fast_recovery_members)
        @skip_ci = !!skip_ci
        @skip_changelog = !!skip_changelog
        @local_ci = local_ci
        @continue_ci_failures = continue_ci_failures
        @ci_workflows = validate_ci_workflows(ci_workflows)
        @skip_bundle_audit = skip_bundle_audit
        @skip_remotes = validate_remote_list(skip_remotes, "--skip-remotes")
        @required_remotes = validate_remote_list(required_remotes.nil? ? config.release_required_remotes : required_remotes, "--required-remotes")
        @auto_dependency_floors = auto_dependency_floors.nil? ? config.release_auto_dependency_floors? : auto_dependency_floors
        @validate_ci_bundles = validate_ci_bundles.nil? ? config.release_validate_ci_bundles? : validate_ci_bundles
        @gha_sha_pins_upgrade = gha_sha_pins_upgrade
        @gha_sha_pins_check = gha_sha_pins_check
        @gha_sha_pins_ttl_days = gha_sha_pins_ttl_days.nil? ? 1.0 : gha_sha_pins_ttl_days.to_f
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
          return with_release_secrets_broker { release_results }
        end

        return template_with_worktree_sync_results if command == "template" && execute

        preflight = branch_checkout_dirty_preflight_results
        return preflight if preflight.any? { |result| !result.ok? }

        prompt_for_gem_signing_password if command == "release" && execute && release_signing_prompt_required?
        return preflight + branch_target_results unless config.release_target_branches.empty?
        return preflight + member_local_branch_target_results if member_local_branch_targets?

        preflight + current_branch_results(members)
      end

      private

      def release_results
        release_preflight = release_preflight_results
        return release_preflight unless release_preflight.empty?

        return branch_target_results unless config.release_target_branches.empty?
        return member_local_branch_target_results if member_local_branch_targets?

        current_branch_results(members)
      end

      def with_release_secrets_broker
        return yield unless release_secrets_broker_required?

        @release_secrets_broker = Secrets::Broker.new(provider: @secrets_provider, root: config.root).start
        yield
      ensure
        @release_secrets_broker&.close
        @release_secrets_broker = nil
      end

      def release_secrets_broker_required?
        execute && release_command_delegates_secrets_to_kettle_release?
      end

      attr_reader :command, :config, :members, :family_members, :execute, :accept, :commit, :allow_dirty, :autostash, :template_cleanup, :publish, :push, :tag, :start_step, :skip_steps, :fast_recovery, :fast_recovery_members, :skip_ci, :skip_changelog, :local_ci, :continue_ci_failures, :ci_workflows, :skip_bundle_audit, :skip_remotes, :required_remotes, :auto_dependency_floors, :validate_ci_bundles, :gha_sha_pins_upgrade, :gha_sha_pins_check, :gha_sha_pins_ttl_days, :env_overrides, :debug, :verbose, :jobs, :progress_io, :reset_target, :bup_args, :bex_args, :start_member, :start_branch

      def template_with_worktree_sync_results
        runner = command_runner
        checkout_preflight = branch_checkout_dirty_preflight_results
        if checkout_preflight.any? { |result| !result.ok? } && !autostash
          return checkout_preflight
        end
        checkout_preflight = [] unless checkout_preflight.all?(&:ok?)

        dirty_preflight = template_dirty_worktree_preflight_results
        return checkout_preflight + dirty_preflight unless dirty_preflight.all?(&:ok?)

        sync_results, stashes = template_worktree_sync_results(runner: runner)
        unless sync_results.all?(&:ok?)
          return checkout_preflight + sync_results + restore_template_autostashes(
            stashes,
            runner: runner,
            preserve_members: template_cleanup ? [] : failed_template_members(sync_results)
          )
        end

        workflow_results = branch_checkout_dirty_preflight_results
        if workflow_results.all?(&:ok?)
          workflow_results += if !config.release_target_branches.empty?
            branch_target_results
          elsif member_local_branch_targets?
            member_local_branch_target_results
          else
            current_branch_results(members)
          end
        end

        failed_members = failed_template_members(workflow_results)
        rollback_results = if template_cleanup
          rollback_failed_template_worktrees(stashes, workflow_results, runner: runner)
        else
          []
        end
        restore_results = restore_template_autostashes(
          stashes,
          runner: runner,
          preserve_members: template_cleanup ? [] : failed_members
        )
        checkout_preflight + sync_results + workflow_results + rollback_results + restore_results
      end

      def template_worktree_sync_results(runner:)
        stashes = []
        results = []
        template_sync_members.each do |member|
          dirty_paths = GitStatus.dirty_paths(member.root)
          if dirty_paths.any?
            blocked_paths = template_blocking_dirty_paths(dirty_paths)
            if blocked_paths.any?
              results << template_dirty_worktree_result(member, blocked_paths)
              break
            end

            stash_result = runner.call(
              member: member,
              phase: "template_autostash",
              command: ["sh", "-lc", template_autostash_command(member)]
            )
            results << stash_result
            break unless stash_result.ok?

            stash_ref = stash_result.stdout.to_s.lines.last.to_s.strip
            if stash_ref.empty?
              results << template_sync_failure_result(member, "could not determine the temporary template autostash reference")
              break
            end
            stashes << {member: member, ref: stash_ref}
          end

          upstream = git_upstream_for(member)
          next unless upstream

          results << runner.call(member: member, phase: "template_sync", command: ["git", "pull", "--rebase"])
          break unless results.last.ok?
        end
        [results, stashes]
      end

      def template_dirty_worktree_preflight_results
        template_sync_members.filter_map do |member|
          dirty_paths = GitStatus.dirty_paths(member.root)
          blocked_paths = template_blocking_dirty_paths(dirty_paths)
          next if blocked_paths.empty?

          template_dirty_worktree_result(member, blocked_paths)
        end
      end

      def template_blocking_dirty_paths(dirty_paths)
        return dirty_paths unless autostash

        dirty_paths.reject { |path| template_autostash_allowed_path?(path) }
      end

      def template_autostash_allowed_path?(status_line)
        path = GitStatus.path_from_status_line(status_line)
        TEMPLATE_AUTOSTASH_ALLOWED_DIRECTORIES.include?(path.split("/", 2).first)
      end

      def restore_template_autostashes(stashes, runner:, preserve_members: [])
        preserve_members = Array(preserve_members).map(&:to_s)
        stashes.reverse_each.map do |stash|
          member = stash.fetch(:member)
          if preserve_members.include?(member.name.to_s)
            next template_autostash_preserved_result(member: member, ref: stash.fetch(:ref))
          end

          restore = runner.call(
            member: member,
            phase: "template_autostash_restore",
            command: ["git", "stash", "pop", stash.fetch(:ref)]
          )
          next restore if restore.ok?

          if template_generated_lockfile_restore_refusal?(member, restore)
            next runner.call(
              member: member,
              phase: "template_autostash_generated_lockfile_recovery",
              command: template_generated_lockfile_restore_command(stash)
            )
          end

          next restore if !template_generated_lockfile_only_conflict?(member)

          runner.call(
            member: member,
            phase: "template_autostash_generated_lockfile_recovery",
            command: [
              "sh", "-lc",
              "set -eu; cd \"$(git rev-parse --show-toplevel)\"; " \
                "paths=$(git diff --name-only --diff-filter=U); " \
                "for path in $paths; do " \
                "case \"$path\" in " \
                "Gemfile.lock|*/Gemfile.lock|Appraisal.root.gemfile.lock|*/Appraisal.root.gemfile.lock|.structuredmerge/kettle-jem.lock|*/.structuredmerge/kettle-jem.lock) " \
                "git restore --ours -- \"$path\"; git add -- \"$path\" ;; " \
                "*) printf 'unresolved non-generated conflict: %s\\n' \"$path\" >&2; exit 1 ;; " \
                "esac; " \
                "done; " \
                "test -z \"$(git diff --name-only --diff-filter=U)\"; " \
                "git stash drop #{Shellwords.escape(stash.fetch(:ref))}"
            ]
          )
        end
      end

      def failed_template_members(results)
        results.reject(&:ok?).filter_map(&:member_name).uniq
      end

      def template_autostash_preserved_result(member:, ref:)
        CommandResult.new(
          member.name,
          "template_autostash_preserved",
          ["internal", "template-autostash-preserved"],
          member.root,
          0,
          true,
          "preserved failed template output and autostash #{ref} for debugging",
          "",
          0.0,
          true,
          "template cleanup disabled"
        )
      end

      def template_generated_lockfile_restore_refusal?(member, restore)
        output = [restore.stdout, restore.stderr].compact.join("\n")
        return false unless output.include?("would be overwritten by merge")

        dirty_paths = GitStatus.dirty_paths(member.root)
        dirty_paths.any? && dirty_paths.all? { |path| template_generated_lockfile_path?(path) }
      end

      def template_generated_lockfile_restore_command(stash)
        member = stash.fetch(:member)
        generated_paths = GitStatus.dirty_paths(member.root).filter_map do |status_line|
          path = status_line.to_s.sub(/\A.../, "").strip
          path if template_generated_lockfile_path?(status_line)
        end.uniq
        reset_commands = generated_paths.map do |path|
          escaped_path = Shellwords.escape(path)
          "if git ls-files --error-unmatch #{escaped_path} >/dev/null 2>&1; then " \
            "git restore --source=HEAD --staged --worktree -- #{escaped_path}; " \
            "else rm -f -- #{escaped_path}; fi"
        end

        [
          "sh",
          "-lc",
          "set -eu; cd \"$(git rev-parse --show-toplevel)\"; " \
            "#{reset_commands.join("; ")}; git stash pop #{Shellwords.escape(stash.fetch(:ref))}"
        ]
      end

      def template_generated_lockfile_path?(status_line)
        path = GitStatus.path_from_status_line(status_line)
        [
          "Gemfile.lock",
          "Appraisal.root.gemfile.lock",
          ".structuredmerge/kettle-jem.lock"
        ].include?(path) ||
          path.end_with?("/Gemfile.lock", "/Appraisal.root.gemfile.lock", "/.structuredmerge/kettle-jem.lock")
      end

      def rollback_failed_template_worktrees(stashes, workflow_results, runner:)
        failed_members = workflow_results.reject(&:ok?).map(&:member_name).compact.uniq
        stashes.filter_map do |stash|
          member = stash.fetch(:member)
          next unless failed_members.include?(member.name)

          runner.call(
            member: member,
            phase: "template_autostash_rollback",
            command: [
              "sh", "-lc",
              "paths=$(git diff --name-only; git diff --cached --name-only); " \
                "paths=$(printf '%s\\n' \"$paths\" | sed '/^\\.structuredmerge\\/kettle-jem\\.yml$/d; /^\\.kettle-jem\\.yml$/d' | sort -u); " \
                "if [ -n \"$paths\" ]; then git restore --source=HEAD --staged --worktree -- $paths; fi; " \
                "git clean -fd -e .structuredmerge/kettle-jem.yml -e .kettle-jem.yml"
            ]
          )
        end
      end

      def template_generated_lockfile_only_conflict?(member)
        stdout, _stderr, status = Open3.capture3("git", "diff", "--name-only", "--diff-filter=U", chdir: member.root)
        conflicts = stdout.lines.map(&:strip).reject(&:empty?).sort
        status.success? && !conflicts.empty? && conflicts.all? { |path| template_generated_lockfile_path?(" M #{path}") }
      end

      def template_branch_sync_results(branch_members, runner:)
        template_sync_members_for(branch_members).each_with_object([]) do |member, memo|
          next unless git_upstream_for(member)

          memo << runner.call(member: member, phase: "template_sync", command: ["git", "pull", "--rebase"])
          break memo unless memo.last.ok?
        end
      end

      def template_sync_members
        template_sync_members_for(members)
      end

      def template_sync_members_for(candidates)
        candidates.each_with_object([]) do |member, unique_members|
          unique_members << member unless unique_members.any? { |candidate| git_root_for(candidate) == git_root_for(member) }
        end
      end

      def git_upstream_for(member)
        stdout, _stderr, status = Open3.capture3("git", "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}", chdir: member.root)
        status.success? ? stdout.strip : nil
      end

      def template_autostash_command(member)
        label = "kettle-family-template-#{member.name}-#{Process.pid}-#{Time.now.to_i}"
        "git stash push --include-untracked --message #{Shellwords.escape(label)} && " \
          "ref=$(git stash list -1 --format=%gd) && " \
          "git checkout \"$ref\" -- .tool-versions 2>/dev/null || true; " \
          "for path in mise.toml .mise.toml; do " \
          "if git cat-file -e \"$ref^3:$path\" 2>/dev/null; then git show \"$ref^3:$path\" > \"$path\"; fi; " \
          "done; printf '%s\\n' \"$ref\""
      end

      def template_dirty_worktree_result(member, dirty_paths)
        stash_guidance = if autostash
          "automatic template autostash is limited to lib/, spec/, and test/ files"
        else
          "automatic template autostash is disabled"
        end
        template_sync_failure_result(
          member,
          [
            "dirty worktree blocks template sync; clean these files before retrying:",
            *dirty_paths.map { |path| "  #{GitStatus.path_from_status_line(path)}" },
            stash_guidance
          ].join("\n"),
          reason: "dirty worktree blocks template sync"
        )
      end

      def template_sync_failure_result(member, message, reason: "template sync failed")
        CommandResult.new(
          member_name: member.name,
          phase: "template_sync_preflight",
          command: ["internal", "template-sync"],
          workdir: member.root,
          status: 1,
          success: false,
          stdout: "",
          stderr: message,
          elapsed_seconds: 0.0,
          skipped: false,
          reason: reason
        )
      end

      def current_branch_results(workflow_members)
        return check_results(workflow_members) if command == "check"
        return reset_member_results(workflow_members) if command == "reset"
        if command == "release"
          results = release_dependency_floor_reconciliation_results(workflow_members)
          return results unless results.all?(&:ok?)

          results.concat(release_member_results(workflow_members, include_family_changelog: !skip_changelog))
          return results unless explicit_monorepo_mode? && results.all?(&:ok?)

          results << aggregate_monorepo_github_release(workflow_members)
          return results
        end
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
        results = []
        if command == "gha-sha-pins" && execute
          return results unless review_gha_sha_pins(workflow_members, runner: runner, memo: results)
        end
        gha_progress = (command == "gha-sha-pins") ? start_gha_sha_pins_progress(workflow_members) : nil
        workflow_members.each_with_object(results) do |member, memo|
          if command == "template" && config.normalize_lockfiles?
            normalize_lockfiles(member: member, runner: runner, memo: memo, phase: "prepare_lockfiles")
            break memo unless memo.last.ok?
          end

          if command == "template"
            prepared = prepare_template_dependencies(member: member, runner: runner, memo: memo)
            break memo if prepared == false
          end

          command_text = workflow_command(member)
          gha_progress&.start_member(member, total: 1, status: "starting")
          result = runner.call(
            member: member,
            phase: command,
            command: command_text,
            env: command_env,
            stdout_line_handler: (command == "gha-sha-pins") ? gha_sha_pins_event_line_handler(member) : nil
          )
          memo << result
          gha_progress&.finish_member(member, success: result.ok?, status: result.ok? ? "complete" : "failed")
          break memo unless result.ok?

          normalize_lockfiles(member: member, runner: runner, memo: memo, phase: "normalize_lockfiles") if command == "template"
          commit_gha_sha_pins(member: member, runner: runner, memo: memo) if command == "gha-sha-pins"
          if command == "bupb"
            bupb_appraisal_results(member: member, runner: runner, memo: memo)
          end
          if %w[bup bupb].include?(command) && memo.last&.ok? && validate_bundle_update_lockfile(member: member, memo: memo)
            commit_bundle_update(member: member, runner: runner, memo: memo)
          end
          commit_bex_changes(member: member, runner: runner, memo: memo) if command == "bex"
        end
        gha_progress&.finish
        results
      end

      def review_gha_sha_pins(workflow_members, runner:, memo:, env: command_env)
        return true if workflow_members.empty?

        repositories = []
        command_text = standalone_gha_sha_pins_command(command_for("gha-sha-pins"))
        workflow_members.each do |member|
          result = runner.call(
            member: member,
            phase: "gha_sha_pins_list",
            command: gha_sha_pins_command(mode: :list, command_text: command_text),
            env: env,
            log_path: gha_sha_pins_log_path(member, phase: "list")
          )
          memo << result
          return false unless result.ok?

          payload = JSON.parse(result.stdout.to_s)
          repositories.concat(Array(payload["repositories"]))
        rescue JSON::ParserError => error
          memo << CommandResult.new(
            member_name: member.name,
            phase: "gha_sha_pins_list",
            command: gha_sha_pins_command(mode: :list, command_text: command_text),
            workdir: member.root,
            status: 1,
            success: false,
            stdout: result&.stdout.to_s,
            stderr: "invalid kettle-gha-pins list JSON: #{error.message}",
            elapsed_seconds: 0.0,
            skipped: false,
            reason: "invalid list output",
            log_path: result&.log_path
          )
          return false
        end

        review_dir = File.join(config.root, "tmp", "kettle-family")
        FileUtils.mkdir_p(review_dir)
        review_path = File.join(
          review_dir,
          "gha-sha-pins-review-#{Process.pid}-#{object_id}.json"
        )
        File.write(review_path, JSON.pretty_generate("schema_version" => 1, "repositories" => repositories.uniq.sort))
        review_result = runner.call(
          member: workflow_members.first,
          phase: "gha_sha_pins_review",
          command: gha_sha_pins_command(mode: :review, input: review_path, command_text: command_text),
          env: env,
          log_path: gha_sha_pins_log_path(workflow_members.first, phase: "review")
        )
        memo << review_result
        review_result.ok?
      ensure
        File.delete(review_path) if review_path && File.file?(review_path)
      end

      def gha_sha_pins_log_path(member, phase:)
        safe_name = member.name.to_s.gsub(/[^A-Za-z0-9_.-]+/, "_")
        File.join(
          config.root,
          "tmp",
          "kettle-family",
          "gha-sha-pins-#{Process.pid}-#{object_id}-#{safe_name}-#{phase}.log"
        )
      end

      def template_member_workflow_results(workflow_members)
        debugger_results = template_debugger_bootstrap_results(workflow_members)
        return debugger_results unless debugger_results.all?(&:ok?)

        appraisal_results = template_appraisal_bootstrap_results(workflow_members)
        return debugger_results + appraisal_results unless appraisal_results.all?(&:ok?)

        bootstrap_results = template_bootstrap_dependency_results(workflow_members)
        return debugger_results + appraisal_results + bootstrap_results unless bootstrap_results.all?(&:ok?)

        template_progress = start_template_progress(workflow_members)
        results = template_dependency_waves(workflow_members).each_with_object([]) do |wave, memo|
          wave_results = template_results_for_wave(wave, progress: template_progress)
          memo.concat(wave_results)
          break memo unless wave_results.all?(&:ok?)
        end
        emit_template_progress_summary(results, progress: template_progress)
        debugger_results + appraisal_results + bootstrap_results + results
      end

      def template_debugger_bootstrap_results(workflow_members)
        bootstrap = DebuggerBootstrap.new(mode: :execute)
        workflow_members.filter_map do |member|
          bootstrap.bootstrap_member(member) if bootstrap.member_needs_bootstrap?(member)
        end
      rescue => error
        [template_bootstrap_failure_result(workflow_members.first, error.message)]
      end

      def template_appraisal_bootstrap_results(workflow_members)
        bootstrap = AppraisalBootstrap.new(mode: :execute)
        workflow_members.filter_map do |member|
          bootstrap.bootstrap_member(member) if bootstrap.member_needs_bootstrap?(member)
        end
      rescue => error
        [template_bootstrap_failure_result(workflow_members.first, error.message)]
      end

      def template_results_for_wave(wave, progress:)
        queue = Queue.new
        wave.each_with_index { |member, index| queue << [index, member] }
        ordered_results = Array.new(wave.length)
        mutex = Mutex.new
        stop = false
        Array.new([template_jobs(wave), wave.length].min) do
          Thread.new do # rubocop:disable ThreadSafety/NewThread -- family templating intentionally runs independent members concurrently.
            loop do
              break if mutex.synchronize { stop }
              index, member = queue.pop(true)
              member_results = template_results_for_member(member, progress: progress)
              mutex.synchronize do
                ordered_results[index] = member_results
                stop = true unless member_results.all?(&:ok?)
              end
            rescue ThreadError
              break
            end
          end
        end.each(&:join)
        ordered_results.compact.flatten
      end

      def template_dependency_waves(workflow_members)
        by_name = workflow_members.to_h { |member| [member.name, member] }
        remaining = workflow_members.dup
        completed = Set.new
        [].tap do |waves|
          until remaining.empty?
            ready = remaining.select do |member|
              (member.dependencies & by_name.keys).all? { |name| completed.include?(name) }
            end
            # A Git checkout is a shared mutable transaction boundary. Nested
            # gems in one checkout must not run kettle-jem concurrently, even
            # when their dependency graph would otherwise place them together.
            wave = ready.group_by { |member| git_root_for(member) }.values.map(&:first)
            raise Error, "template dependency wave could not resolve: #{remaining.map(&:name).join(", ")}" if wave.empty?

            waves << wave
            completed.merge(wave.map(&:name))
            remaining -= wave
          end
        end
      end

      def template_bootstrap_dependency_results(workflow_members)
        return [] if workflow_members.empty?

        candidate_members = workflow_members.select { |member| nomono_bootstrap_candidate?(member) }
        return [] if candidate_members.empty?

        latest_nomono_version = latest_released_nomono_version
        active_nomono_version = Gem.loaded_specs["nomono"]&.version
        if active_nomono_version && active_nomono_version < latest_nomono_version
          return [template_bootstrap_failure_result(
            candidate_members.first,
            "activated nomono #{active_nomono_version} is older than latest released #{latest_nomono_version}"
          )]
        end

        bootstrap = NomonoBootstrap.new(latest_version: latest_nomono_version, mode: :execute)
        runner = CommandRunner.new(execute: execute, accept: accept)
        candidate_members.each_with_object([]) do |member, memo|
          next unless bootstrap.member_needs_bootstrap?(member)

          memo << bootstrap.bootstrap_member(member)
          break memo unless memo.last.ok?

          memo << runner.call(
            member: member,
            phase: "template_bootstrap_dependencies",
            command: %w[bundle update nomono --bundler],
            env: template_bootstrap_dependency_env(member)
          )
          break memo unless memo.last.ok?
        end
      rescue => error
        [template_bootstrap_failure_result(workflow_members.first, error.message)]
      end

      def nomono_bootstrap_candidate?(member)
        %w[Gemfile Gemfile.lock].any? do |basename|
          path = File.join(member.root, basename)
          File.file?(path) && File.read(path).include?(NomonoBootstrap::GEM_NAME)
        end
      end

      def template_bootstrap_failure_result(member, message)
        CommandResult.new(
          member.name,
          "template_bootstrap_dependencies",
          ["internal", "nomono-bootstrap"],
          member.root,
          1,
          false,
          "",
          message,
          0.0,
          false,
          "command failed"
        )
      end

      def latest_released_nomono_version
        versions = Kettle::Dev::RubyGemsVersions.fetch(NomonoBootstrap::GEM_NAME).filter_map do |entry|
          number = entry["number"] || entry[:number]
          next if number.to_s.empty?

          version = Gem::Version.new(number)
          version unless version.prerelease?
        end
        raise Error, "could not determine latest released nomono version" if versions.empty?

        versions.max
      end

      def template_bootstrap_dependency_env(member)
        env = release_lockfile_local_path_env_overrides(member).merge(workflow_env)
        env.each_key do |key|
          env[key] = "false" if key.end_with?("_DEV") && !local_path_env_requested?(key)
        end
        env["K_JEM_TEMPLATING"] = "false"
        env["BUNDLE_DISABLE_CHECKSUM_VALIDATION"] = "true"
        family_env_name = config.family_local_path_env_name
        env[family_env_name] = "false" if family_env_name && !local_path_env_requested?(family_env_name)
        env
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
          dirty_paths_before = branch_generated_lockfile_dirt(branch_members)
          if command == "template" && execute
            memo.concat(template_branch_sync_results(branch_members, runner: runner))
            break memo unless memo.last&.ok?
          end
          branch_results = current_branch_results(branch_members)
          tag_branch_results(branch_results, branch)
          memo.concat(branch_results)

          if branch_generated_lockfile_cleanup_required?
            cleanup_branch_generated_lockfiles(
              branch_members: branch_members,
              dirty_paths_before: dirty_paths_before,
              runner: runner,
              memo: memo,
              branch: branch
            )
          end
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

      def branch_generated_lockfile_cleanup_required?
        execute && %w[test lint].include?(command)
      end

      def branch_generated_lockfile_dirt(branch_members)
        branch_members.each_with_object({}) do |member, memo|
          root = git_root_for(member)
          memo[root] ||= GitStatus.dirty_paths(root)
        end
      end

      def cleanup_branch_generated_lockfiles(branch_members:, dirty_paths_before:, runner:, memo:, branch:)
        processed_roots = []
        branch_members.each do |member|
          root = git_root_for(member)
          next if processed_roots.include?(root)

          processed_roots << root
          before = dirty_paths_before.fetch(root, []).map { |path| normalized_dirty_path(path) }
          generated_paths = GitStatus.dirty_paths(root).filter_map do |status_line|
            path = normalized_dirty_path(status_line)
            path unless before.include?(path) || !template_generated_lockfile_path?(status_line)
          end.uniq
          next if generated_paths.empty?

          result = runner.call(
            member: member,
            phase: "branch_generated_lockfile_recovery",
            command: branch_generated_lockfile_restore_command(generated_paths)
          )
          result.branch = branch if result.respond_to?(:branch=)
          memo << result
          break unless result.ok?
        end
      end

      def normalized_dirty_path(status_line)
        status_line.to_s.sub(/\A.../, "").strip
      end

      def branch_generated_lockfile_restore_command(paths)
        reset_commands = paths.map do |path|
          escaped_path = Shellwords.escape(path)
          "if git ls-files --error-unmatch #{escaped_path} >/dev/null 2>&1; then " \
            "git restore --source=HEAD --staged --worktree -- #{escaped_path}; " \
            "else rm -f -- #{escaped_path}; fi"
        end

        ["sh", "-lc", "set -eu; #{reset_commands.join("; ")}"]
      end

      def release_preflight_results
        phases = release_preflight_phases
        progress = start_release_preflight_progress(phases)
        progress&.start
        preflight_member = release_preflight_progress_member
        progress&.start_member(preflight_member, total: phases.length, status: phases.first.fetch(:label))
        phases.each_with_index do |phase, index|
          label = phase.fetch(:label)
          progress&.update(preflight_member, status: label, mark: ">")
          result = send(phase.fetch(:method))
          failed = result.any? { |entry| !entry.ok? }
          progress&.advance(preflight_member, status: label, success: !failed, mark: failed ? "F" : ".")
          if failed
            progress&.finish_member(preflight_member, success: false, status: label)
            progress&.stop
            return result
          end
        end
        progress&.finish_member(preflight_member, success: true, status: "ok")
        progress&.stop
        []
      end

      def release_preflight_phases
        dirty_phase = {label: "branch checkout readiness", method: :release_preflight_branch_checkout_dirty_results}
        signing_phase = {label: "gem signing password", method: :release_preflight_signing_password_results}
        secrets_phase = release_secrets_authorization_required? ? {label: "secrets provider authorization", method: :release_preflight_secrets_authorization_results} : nil
        gha_sha_pins_phase = release_gha_sha_pins_review_required? ? {label: "GitHub Actions SHA pins", method: :release_preflight_gha_sha_pins_results} : nil

        [secrets_phase, gha_sha_pins_phase, dirty_phase, signing_phase].compact
      end

      def release_preflight_gha_sha_pins_results
        results = []
        review_gha_sha_pins(members, runner: command_runner, memo: results, env: command_env)
        results
      end

      def release_gha_sha_pins_review_required?
        execute && kettle_release_command?(raw_release_command) && !release_gha_sha_pins_offline_requested?
      end

      def release_gha_sha_pins_offline_requested?
        value = env_overrides.fetch(
          "KETTLE_PRE_RELEASE_GHA_SHA_PINS_OFFLINE",
          ENV.fetch("KETTLE_PRE_RELEASE_GHA_SHA_PINS_OFFLINE", "")
        )
        %w[true yes 1 on enabled].include?(value.to_s.strip.downcase)
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

        branch_checkout_preflight_members.each_with_object([]) do |member, results|
          dirty_paths = GitStatus.dirty_paths(member.root)
          next if dirty_paths.empty?

          if recoverable_template_lockfile_dirt?(dirty_paths)
            recover_dirty_template_lockfile_before_branch_checkout(member: member, runner: command_runner, memo: results)
            next if results.last&.ok? && GitStatus.dirty_paths(member.root).empty?
          end

          results << branch_checkout_dirty_result(member, GitStatus.dirty_paths(member.root))
        end
      end

      def recoverable_template_lockfile_dirt?(dirty_paths)
        return false unless command == "template" && config.normalize_lockfiles?
        return false unless dirty_paths.length == 1 && dirty_paths.first.end_with?(" Gemfile.lock")

        true
      end

      def recover_dirty_template_lockfile_before_branch_checkout(member:, runner:, memo:)
        if release_lockfile_has_local_path_remote?(member)
          recover_template_lockfiles(member: member, runner: runner, memo: memo, phase: "template_lockfile_recovery")
        else
          commit_normalized_lockfiles(
            branch_members: [member],
            runner: runner,
            memo: memo,
            reason: "template",
            force: true
          )
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
        append_family_changelog_result(runner: runner, memo: results) unless skip_changelog
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
          family_members: family_members,
          execute: execute,
          accept: accept,
          commit: commit,
          allow_dirty: allow_dirty,
          publish: publish,
          push: push,
          tag: tag,
          start_step: start_step,
          skip_steps: skip_steps,
          fast_recovery: fast_recovery,
          fast_recovery_members: fast_recovery_members,
          skip_ci: skip_ci,
          skip_changelog: skip_changelog,
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
        @release_completed_member_names = []
        append_family_changelog_result(runner: runner, memo: results) if include_family_changelog
        return results unless results.all?(&:ok?)
        return parallel_release_member_results(release_members, results) if parallel_release_members?(release_members)

        sequential_release_member_results(release_members, results, runner: runner)
      end

      def sequential_release_member_results(release_members, initial_results, runner:)
        results = initial_results
        waves = release_waves(release_members)
        ordered_members = waves.flatten
        show_wave_markers = config.release_waves.any? && waves.length > 1
        release_progress = start_release_progress(release_members)
        @release_progress = release_progress
        begin
          waves.each_with_index do |wave, index|
            results << release_wave_result(wave, index: index, total: waves.length, jobs: 1) if show_wave_markers
            wave.each do |member|
              results.concat(release_results_for_member(member, runner: runner))
              break unless results.last.ok?

              remaining_members = ordered_members.drop(ordered_members.index(member) + 1)
              @release_completed_member_names << member.name
              append_dependency_floor_results(released_members: [member], dependent_members: remaining_members, runner: runner, memo: results)
              break unless results.last&.ok?
            end
            break unless results.last&.ok?
          end
        ensure
          emit_release_progress_summary(results, progress: release_progress)
          @release_progress = nil
        end
        results
      end

      def parallel_release_member_results(release_members, initial_results)
        results = initial_results.dup
        waves = release_waves(release_members)
        completed_members = []
        @release_completed_member_names = []
        release_progress = start_release_progress(release_members)
        @release_progress = release_progress
        begin
          waves.each_with_index do |wave, index|
            results << release_wave_result(wave, index: index, total: waves.length)
            wave_results = run_release_wave(wave)
            results.concat(wave_results.flatten)
            break unless wave_results.all? { |member_results| member_results.all?(&:ok?) }

            completed_members.concat(wave)
            @release_completed_member_names.concat(wave.map(&:name))
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
            rescue => error
              mutex.synchronize do
                ordered_results[index] = [release_worker_error_result(member, error)]
                stop = true
              end
              break
            end
          end
        end.each(&:join)
        ordered_results.compact
      end

      def release_wave_result(wave, index:, total:, jobs: nil)
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
          reason: "jobs=#{jobs || release_jobs(wave)} total=#{total}"
        )
      end

      def release_worker_error_result(member, error)
        CommandResult.new(
          member_name: member.name,
          phase: release_phase,
          command: ["internal", "release-worker"],
          workdir: member.root,
          status: 1,
          success: false,
          stdout: "",
          stderr: "#{error.class}: #{error.message}\n",
          elapsed_seconds: 0.0,
          skipped: false,
          reason: error.message
        )
      end

      def release_results_for_member(member, runner:)
        progress = @release_progress
        progress&.start_member(member, total: release_phase_total(member), status: "check")
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

            if !execute && release_lockfile_readiness_would_fail?(member)
              memo << release_skipped_after_lockfile_normalization_result(member)
              emit_member_result_progress(member, memo.last, progress: progress)
              return memo
            end
          end

          append_release_internal_checks(member: member, memo: memo)
          memo.last(2).each { |result| emit_member_result_progress(member, result, progress: progress) }
          return memo unless memo.last(2).all?(&:ok?)

          release_result = runner.call(
            member: member,
            phase: release_phase,
            command: release_command_for(member),
            env: release_env_for_member(member),
            interactive: release_command_interactive?,
            stdout_line_handler: release_event_line_handler(member, progress: progress),
            log_path: release_command_log_path(member, release_phase),
            passthrough_output: release_command_passthrough_output?
          )
          memo << release_result
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
          gem_signing_password: release_command_delegates_secrets_to_kettle_release? ? nil : @gem_signing_password,
          # RubyGems MFA belongs to the child release command. Keeping an OTP
          # coordinator here can make a family-level gem retry look successful
          # while skipping the child's checksums and GitHub release steps.
          otp_coordinator: nil
        )
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
        ReleaseWaves.new(members: release_members, configured_waves: config.release_waves, strict_cycles: true).waves
      end

      def release_dependency_floor_reconciliation_results(release_members)
        return [] unless execute && auto_dependency_floors

        published_members = published_family_dependencies_for(release_members)
        return [] if published_members.empty?

        with_dependency_floor_progress(release_members) do
          results = []
          append_dependency_floor_results(
            released_members: published_members,
            dependent_members: release_members,
            runner: release_command_runner,
            memo: results
          )
          results
        end
      end

      # Startup reconciliation happens before release waves initialize their
      # progress renderer. Give its retrying Bundler work a dedicated renderer
      # so registry propagation is visible instead of appearing hung.
      def with_dependency_floor_progress(release_members)
        return yield if @release_progress

        progress = start_dependency_floor_progress(release_members)
        @release_progress = progress
        yield
      ensure
        progress&.finish
        @release_progress = nil if progress
      end

      def start_dependency_floor_progress(release_members)
        progress = WorkflowProgress.new(
          io: progress_io,
          label: "reconciling dependency floors for",
          total: release_members.length,
          jobs: 1,
          members: release_members
        )
        progress.start
        release_members.each { |member| progress.start_member(member, total: 0, status: "dependency floors") }
        progress
      end

      # A resumed --only pend release no longer includes members that finished
      # in an earlier invocation. Reconcile against the registry before the
      # next release wave so those already-published versions still update
      # sibling floors and lockfiles.
      def published_family_dependencies_for(release_members)
        dependency_names = release_members.flat_map do |member|
          publish ? active_release_dependency_names(member) : release_dependency_names(member)
        end.uniq
        family_members_by_name = family_members.to_h { |member| [member.name, member] }
        dependency_names.filter_map do |dependency_name|
          member = family_members_by_name[dependency_name]
          next unless member
          next unless released_version?(member.name, member.version)

          member
        end
      end

      def append_dependency_floor_results(released_members:, dependent_members:, runner:, memo:)
        return unless auto_dependency_floors
        return if dependent_members.empty?

        require_relative "dependency_floor"

        affected_dependent_members = dependent_members_depending_on(released_members: released_members, dependent_members: dependent_members)
        lockfile_ready_dependent_members = affected_dependent_members.select do |member|
          dependency_floor_refresh_ready?(member, released_members: released_members)
        end
        lockfile_refresh_members = if execute && publish
          lockfile_ready_dependent_members.filter_map do |member|
            active_released_members = active_release_dependencies_for(member, released_members)
            [member, active_released_members] unless active_released_members.empty?
          end
        else
          []
        end
        floor_results = DependencyFloor.new(
          released_members: released_members,
          dependent_members: dependent_members,
          mode: execute ? :execute : :dry_run
        ).results
        memo.concat(floor_results)
        return if floor_results.any? && !floor_results.all?(&:ok?)

        append_dependency_floor_lockfile_results(dependent_members: lockfile_refresh_members, runner: runner, memo: memo)
        return if memo.any? && !memo.last.ok?

        append_dependency_floor_bundle_install_results(dependent_members: lockfile_refresh_members.map(&:first), runner: runner, memo: memo)
        return if memo.any? && !memo.last.ok?

        if validate_ci_bundles
          append_dependency_floor_ci_bundle_results(dependent_members: lockfile_refresh_members, runner: runner, memo: memo)
          return if memo.any? && !memo.last.ok?
        end

        reconciled_members = (floor_results.map(&:member_name) + lockfile_refresh_members.map { |member, _released_members| member.name }).uniq
        commit_dependency_floor_changes(dependent_members: reconciled_members, runner: runner, memo: memo) if reconciled_members.any? && execute && commit
      end

      def dependent_members_depending_on(released_members:, dependent_members:)
        released_names = released_members.map(&:name)
        dependent_members.select do |member|
          release_dependency_names(member).any? { |dependency| released_names.include?(dependency) }
        end
      end

      # A release-valid lockfile must resolve every selected sibling dependency
      # from the registry. Defer refreshes for dependents that still require a
      # selected sibling from a later release wave; their gemspec floors can be
      # updated now, but Bundler cannot resolve the future sibling remotely yet.
      def dependency_floor_refresh_ready?(member, released_members:)
        selected_names = members.map(&:name)
        selected_dependencies = release_dependency_names(member).select { |dependency| selected_names.include?(dependency) }
        completed_names = Array(@release_completed_member_names) + released_members.map(&:name)
        selected_dependencies.all? { |dependency| completed_names.include?(dependency) }
      end

      def release_dependency_names(member)
        Array(member.release_dependencies || member.dependencies).map(&:to_s)
      end

      # Prism-based discovery intentionally includes every literal Gemfile
      # declaration so release ordering is conservative. Lockfile refreshes
      # must instead use the Gemfile as evaluated in the release environment:
      # optional local/template declarations are not valid --update targets.
      def active_release_dependencies_for(member, released_members)
        runtime_names = Array(member.dependencies).map(&:to_s)
        gemfile_candidates = released_members.reject { |released_member| runtime_names.include?(released_member.name) }
        return released_members if gemfile_candidates.empty?

        active_names = active_release_dependency_names(member)
        released_members.select { |released_member| active_names.include?(released_member.name) }
      end

      def active_release_dependency_names(member)
        active_release_dependency_names_for_gemfile(member, File.join(member.root, "Gemfile"))
      end

      def active_release_dependency_names_for_gemfile(member, gemfile)
        (Array(member.dependencies).map(&:to_s) + active_release_gemfile_dependency_names(member, gemfile)).reject do |name|
          name == member.name
        end
      end

      def active_release_gemfile_dependency_names(member, gemfile = File.join(member.root, "Gemfile"))
        return [] unless File.file?(gemfile)

        script = <<~RUBY
          require "bundler"
          dsl = Bundler::Dsl.evaluate(ARGV.fetch(0), nil, {})
          puts dsl.dependencies.map(&:name)
        RUBY
        stdout, stderr, status = Open3.capture3(
          release_lockfile_env(member).compact,
          RbConfig.ruby,
          "-e",
          script,
          gemfile,
          chdir: member.root
        )
        unless status.success?
          raise Error, "could not evaluate release Gemfile for #{member.name}: #{stderr.strip}"
        end

        stdout.lines.map(&:strip).reject(&:empty?).uniq
      end

      def append_dependency_floor_lockfile_results(dependent_members:, runner:, memo:)
        return unless execute && publish
        return if dependent_members.empty?

        dependent_members.each do |member, released_members|
          memo << wait_for_dependency_floor_lockfiles_result(member: member, released_members: released_members, runner: runner)
          break unless memo.last.ok?
        end
      end

      def append_dependency_floor_ci_bundle_results(dependent_members:, runner:, memo:)
        return unless execute && publish
        return if dependent_members.empty?

        dependent_members.each do |member, released_members|
          dependency_floor_ci_bundle_gemfiles(member).each do |gemfile|
            gemfile_released_members = active_release_dependencies_for_gemfile(member, gemfile, released_members)
            next if gemfile_released_members.empty?

            memo << wait_for_dependency_floor_ci_bundle_result(member: member, gemfile: gemfile, released_members: gemfile_released_members, runner: runner)
            break unless memo.last.ok?
          end
          break if memo.any? && !memo.last.ok?
        end
      end

      # `bundle lock` deliberately updates only resolution metadata. Install the
      # resulting locked bundle before invoking the dependent's `bundle exec
      # kettle-release`, otherwise a just-published family gem can be absent
      # from the local RubyGems installation.
      def append_dependency_floor_bundle_install_results(dependent_members:, runner:, memo:)
        return unless execute && publish
        return if dependent_members.empty?

        dependent_members.each do |member|
          memo << runner.call(
            member: member,
            phase: "dependency_floor_bundle_install",
            command: ["bundle", "install"],
            env: release_lockfile_env(member)
          )
          break unless memo.last.ok?
        end
      end

      def wait_for_dependency_floor_lockfiles_result(member:, released_members:, runner:)
        result = nil
        REGISTRY_WAIT_ATTEMPTS.times do |index|
          attempts = index + 1
          emit_dependency_floor_lockfile_progress(member: member, attempt: index + 1)
          result = runner.call(
            member: member,
            phase: "dependency_floor_lockfiles",
            command: dependency_floor_lockfile_command(released_members),
            env: release_lockfile_env(member)
          )
          if repair_checksum_mismatches(member, result)
            attempts += 1
            result = runner.call(
              member: member,
              phase: "dependency_floor_lockfiles",
              command: dependency_floor_lockfile_command(released_members),
              env: release_lockfile_env(member)
            )
          end
          validate_dependency_floor_lockfile_result(result: result, member: member, released_members: released_members) if result.ok?
          annotate_dependency_floor_lockfile_result(result, attempts)
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
        diagnostics = Kettle::Dev::LockfileReset.local_path_remote_lines_from_source(lockfile_source).map do |line_number|
          "Gemfile.lock has local path remote at line #{line_number}"
        end
        checksum_entries = Kettle::Dev::LockfileReset.checksum_entries_from_source(lockfile_source) || {}
        diagnostics.concat(released_members.filter_map do |released_member|
          checksum = checksum_entries[[released_member.name, released_member.version]]
          if checksum.nil?
            "Gemfile.lock CHECKSUMS is missing #{released_member.name} #{released_member.version}"
          elsif !checksum.include?("sha256=")
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

      def active_release_dependencies_for_gemfile(member, gemfile, released_members)
        active_names = active_release_dependency_names_for_gemfile(member, gemfile)
        released_members.select { |released_member| active_names.include?(released_member.name) }
      end

      def workflow_bundle_gemfiles(member)
        Dir.glob(File.join(member.root, ".github", "workflows", "*.{yml,yaml}")).flat_map do |path|
          workflow_bundle_gemfile_entries(path).map do |entry|
            File.expand_path(normalize_workflow_workspace_path(entry), member.root)
          end
        end
      end

      def workflow_bundle_gemfile_entries(path)
        data = YAML.safe_load_file(path, permitted_classes: [], permitted_symbols: [], aliases: true) || {}
        [
          *recursive_values_for_key(data, "bundle_gemfile"),
          *recursive_env_values_for_key(data, "BUNDLE_GEMFILE")
        ].map(&:to_s).reject(&:empty?)
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

      def recursive_env_values_for_key(value, key)
        case value
        when Hash
          matches = value.fetch("env", nil).is_a?(Hash) ? [value["env"][key]] : []
          matches.concat(value.flat_map { |_entry_key, entry_value| recursive_env_values_for_key(entry_value, key) })
        when Array
          value.flat_map { |entry| recursive_env_values_for_key(entry, key) }
        else
          []
        end
      end

      def normalize_workflow_workspace_path(path)
        path.to_s.sub(%r{\A\$\{\{\s*github\.workspace\s*\}\}/?}, "").sub(%r{\A\$GITHUB_WORKSPACE/?}, "")
      end

      def relative_path_from_member_root(member:, path:)
        Pathname.new(path).relative_path_from(Pathname.new(member.root)).to_s
      rescue ArgumentError
        path.to_s
      end

      def reset_gemfile_lock(member:, runner:, memo:, phase: "reset_gemfile_lock", env: release_lockfile_env(member))
        result = runner.call(
          member: member,
          phase: phase,
          command: reset_gemfile_lock_command(member),
          env: env
        )
        memo << result
        return unless result.ok? && execute

        validate_reset_gemfile_lock(member: member, memo: memo, phase: phase)
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

      def validate_reset_gemfile_lock(member:, memo:, phase: "reset_gemfile_lock")
        diagnostics = reset_gemfile_lock_diagnostics(member)
        return if diagnostics.empty?

        memo << CommandResult.new(
          member.name,
          "#{phase}_readiness",
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
        diagnostics = Kettle::Dev::LockfileReset.local_path_remote_lines_from_source(lockfile_source).map do |line_number|
          "#{lockfile_name} has local path remote at line #{line_number}"
        end
        checksum_entries = Kettle::Dev::LockfileReset.checksum_entries_from_source(lockfile_source)
        if checksum_entries.nil?
          diagnostics << "#{lockfile_name} CHECKSUMS section is missing"
          return diagnostics
        end

        Kettle::Dev::LockfileReset.gem_specs_from_source(lockfile_source).each do |name, version|
          checksum = checksum_entries[[name, version]]
          if checksum.nil?
            diagnostics << "#{lockfile_name} CHECKSUMS is missing #{name} #{version}"
          elsif !checksum.include?("sha256=")
            diagnostics << "#{lockfile_name} CHECKSUMS has no sha256 for #{name} #{version}"
          end
        end
        diagnostics
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
                "if [ -n \"$files\" ]; then git add -- $files && git commit -m '⬆️ Reconcile family dependencies'; fi"
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
        memo << ReadinessCheck.call(
          member: member,
          config: config,
          allowed_local_path_roots: release_readiness_allowed_local_path_roots(member)
        )
        memo << ChangelogCheck.call(member: member, config: config) if memo.last.ok?
      end

      def release_readiness_allowed_local_path_roots(member)
        roots = release_allowed_local_path_roots
        return roots unless kettle_release_command?(raw_release_command)

        # kettle-release resets local path remotes before running its own
        # readiness checks. Let the child own that transition rather than
        # rejecting the lockfile one step before it can normalize it.
        (roots + release_lockfile_local_path_remotes(member)).uniq
      end

      def release_skipped_after_lockfile_normalization_result(member)
        CommandResult.new(
          member_name: member.name,
          phase: release_phase,
          command: release_command_for(member),
          workdir: member.root,
          status: nil,
          success: true,
          stdout: "",
          stderr: "",
          elapsed_seconds: 0.0,
          skipped: true,
          reason: "dry-run; release readiness requires lockfile normalization"
        )
      end

      def append_family_changelog_result(runner:, memo:)
        return unless config.release_family_changelog?
        return unless family_changelog_applies_to_selected_members?

        member = family_changelog_member
        memo << runner.call(
          member: member,
          phase: "family_changelog",
          command: family_changelog_command,
          env: family_changelog_env
        )
      end

      def family_changelog_applies_to_selected_members?
        return true unless config.shared_changelog?

        # A member-local changelog is an independent release lane. Do not
        # prepare the shared root changelog when that is the only lane selected.
        members.any? { |member| !config.member_local_changelog?(member) }
      end

      # simplecov:disable
      # This adapter selects a version file across repository boundaries. Its
      # filesystem/layout behavior is covered by release integration tests;
      # the sibling-repository unit suite cannot execute a monorepo release.
      def family_changelog_member
        return family_member unless config.shared_changelog?

        version_file = family_changelog_version_file
        if version_file.empty?
          return members.first if members.first&.version_file

          raise Error, "shared root changelog release requires changelog.version_file"
        end

        version_path = File.expand_path(version_file, config.root)
        # The root anchor may belong to an earlier wave, so partial releases
        # must not fall back to a selected member's independent version.
        known_members = family_members.empty? ? members : family_members
        member = known_members.find { |candidate| path_inside?(version_path, candidate.root) }
        return member if member

        fallback = members.first
        return fallback if fallback&.version_file

        raise Error, "shared root changelog version file #{version_file} is not inside any family member"
      end

      def family_changelog_env
        env = release_env.merge(config.changelog_env)
        # A shared monorepo changelog runs the aggregate suite before each
        # member release. Keep that suite on the family-local dependency graph;
        # the member release's lockfile reset still disables local paths before
        # building and publishing each gem.
        family_env_name = config.family_local_path_env_name
        if config.family_mode == "monorepo" && family_env_name
          env[family_env_name] = family_changelog_family_path(family_env_name)
        end
        family_changelog_tooling_env.each { |name, value| env[name] = value }
        return env unless config.shared_changelog?

        env.merge(
          "K_CHANGELOG_GEM_NAME" => config.family_name.to_s,
          "K_CHANGELOG_COVERAGE_ROOT" => File.expand_path(config.root),
          "K_CHANGELOG_PATH" => File.expand_path(config.changelog_path, config.root),
          "K_CHANGELOG_VERSION_FILE" => File.expand_path(family_changelog_version_file, config.root)
        )
      end

      def family_changelog_family_path(name)
        configured = config.changelog_env.fetch(name, nil)
        return configured if local_path_env_value?(configured)

        override = env_overrides.fetch(name, nil)
        return override if local_path_env_value?(override)

        ambient = ENV.fetch(name, nil)
        return ambient if local_path_env_value?(ambient)

        config.family_local_path_root
      end

      def family_changelog_tooling_env
        %w[KETTLE_DEV_DEV].each_with_object({}) do |name, env|
          value = env_overrides.fetch(name, ENV[name])
          env[name] = value if value && local_path_env_value?(value)
        end
      end

      def family_changelog_version_file
        configured = config.changelog_version_file.to_s
        known_members = family_members.empty? ? members : family_members
        return configured if !configured.empty? && known_members.any? { |member| path_inside?(File.expand_path(configured, config.root), member.root) }

        members.first&.version_file.to_s
      end
      # simplecov:enable

      def path_inside?(path, root)
        expanded_path = File.expand_path(path)
        expanded_root = File.expand_path(root)
        expanded_path == expanded_root || expanded_path.start_with?("#{expanded_root}#{File::SEPARATOR}")
      end

      def release_phase
        publish ? "release_publish" : "release_build"
      end

      def release_command
        release_command_for(nil)
      end

      def release_command_for(member)
        command = raw_release_command
        kettle_release_command?(command) ? append_kettle_release_args(command, member: member) : command
      end

      def family_changelog_command
        command = config.release_family_changelog_command
        return command unless kettle_changelog_command?(command)

        append_kettle_changelog_args(standalone_kettle_changelog_command(command))
      end

      def raw_release_command
        publish ? config.release_publish_command : config.release_build_command
      end

      def release_command_interactive?
        publish || !!@gem_signing_password
      end

      def release_command_passthrough_output?
        verbose || debug
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

      def append_kettle_release_args(command, member: nil)
        command = replace_kettle_release_provider(command) if @release_secrets_broker
        args = []
        effective_start_step = release_start_step_for(member)
        effective_skip_steps = release_skip_steps_for(member)
        args << "start_step=#{effective_start_step}" if effective_start_step
        args << "skip_steps=#{effective_skip_steps}" unless effective_skip_steps.empty?
        args << "--skip-changelog" if skip_changelog
        args << "--ci-workflows=#{ci_workflows}" if ci_workflows && !ci_workflows.to_s.empty?
        args << "--local-ci" if local_ci
        args << "--skip-bundle-audit" if skip_bundle_audit
        args << "--skip-remotes=#{skip_remotes}" if skip_remotes && !skip_remotes.to_s.empty?
        args << "--required-remotes=#{required_remotes}" if required_remotes && !required_remotes.to_s.empty?
        if release_command_delegates_secrets_to_kettle_release? && !command_includes_arg?(command, "--secrets-provider")
          args << "--secrets-provider=family" if @release_secrets_broker
          args << "--secrets-provider=1password" unless @release_secrets_broker
        end
        args << "--yes" if release_command_uses_kettle_release_yes? && !command_includes_arg?(command, "--yes")
        args << "--events" unless command_includes_arg?(command, "--events")
        return command if args.empty?

        command.is_a?(Array) ? [*command, *args] : "#{command} #{args.join(" ")}"
      end

      def release_start_step_for(member)
        return start_step unless fast_recovery_for?(member)

        (fast_recovery == "retry-ci") ? 10 : 11
      end

      def release_skip_steps_for(_member)
        steps = Array(skip_steps).flat_map { |entry| entry.to_s.split(",") }.map(&:strip).reject(&:empty?)
        steps << "10" if skip_ci
        steps.uniq.join(",")
      end

      def fast_recovery_for?(member)
        return false unless fast_recovery
        return false unless member

        fast_recovery_members.include?(member.name)
      end

      def replace_kettle_release_provider(command)
        case command
        when Array
          command.map { |part| part.to_s.gsub(/--secrets-provider(?:=|\s+)\S+/, "--secrets-provider=family") }
        else
          command.to_s.gsub(/--secrets-provider(?:=|\s+)\S+/, "--secrets-provider=family")
        end
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

      def normalize_fast_recovery(value, publish:)
        return nil if value.nil? || value.to_s.strip.empty?
        raise Error, "--fast-recovery requires --publish" unless publish

        mode = value.to_s.strip.downcase.tr("_", "-")
        return mode if %w[retry-ci skip-ci].include?(mode)

        raise Error, "invalid --fast-recovery value #{value.inspect}; use retry-ci or skip-ci"
      end

      def normalize_fast_recovery_members(value)
        return [] unless fast_recovery

        names = if value.nil? || value.to_s.strip.empty?
          members.map(&:name)
        else
          value.to_s.split(",").map(&:strip).reject(&:empty?).uniq
        end
        raise Error, "--fast-recovery-members requires at least one member" if names.empty?

        known = family_members.map(&:name)
        unknown = names - known
        raise Error, "unknown fast recovery member(s): #{unknown.join(", ")}" unless unknown.empty?

        selected = members.map(&:name)
        unselected = names - selected
        unless unselected.empty?
          raise Error, "fast recovery member(s) must be selected: #{unselected.join(", ")}"
        end

        names
      end

      def fast_recovery_members_given?(value)
        Array(value).flat_map { |entry| entry.to_s.split(",") }.map(&:strip).reject(&:empty?).any?
      end

      def validate_remote_list(value, option_name)
        return nil if value.nil?

        remotes = Array(value).flat_map { |entry| entry.to_s.split(",") }.map(&:strip)
        return nil if remotes.all?(&:empty?)

        invalid = remotes.find { |remote| remote.empty? || !remote.match?(/\A[A-Za-z0-9_.-]+\z/) }
        raise Error, "invalid #{option_name} value #{value.inspect}" if invalid

        remotes.join(",")
      end

      def release_env
        env = base_release_env
        env.merge!(env_overrides)
        env
      end

      # A monorepo member runs kettle-release from its own checkout, while its
      # changelog may live at the family root. Pass the shared paths to the
      # member release phase as well as to the separate family phase.
      def release_env_for_member(member)
        env = release_env
        env.merge!(release_wave_local_path_env_for(member))
        # Family release performs one live pin review before member releases.
        # Child kettle-release must consume that reviewed cache instead of
        # repeating the GitHub API lookup for every member.
        if release_gha_sha_pins_review_required? || release_gha_sha_pins_offline_requested?
          env["KETTLE_PRE_RELEASE_GHA_SHA_PINS_OFFLINE"] = "true"
        end
        # Run the member's kettle-release from the local kettle-dev checkout
        # when the family workflow itself is using local release tooling. The
        # child release commands disable local dependency paths explicitly;
        # hiding kettle-dev here would execute an older released tool instead.
        local_kettle_dev = ENV.fetch("KETTLE_DEV_DEV", "").to_s.strip
        env["KETTLE_DEV_DEV"] = local_kettle_dev if kettle_release_command?(raw_release_command) && local_path_env_value?(local_kettle_dev)
        if kettle_release_command?(raw_release_command)
          local_kettle_dev_gemfile = local_kettle_dev_gemfile_path(local_kettle_dev)
          env["BUNDLE_GEMFILE"] = local_kettle_dev_gemfile if local_kettle_dev_gemfile
        end
        if config.family_mode == "monorepo"
          # Monorepo members release from subdirectories, while CI workflows
          # live at the shared repository root.
          env["K_RELEASE_CI_ROOT"] = config.root
          env["K_RELEASE_CI_WORKFLOWS"] ||= "current.yml"
          # Explicit multi-gem monorepos publish one aggregate GitHub Release
          # after their member gems. A standalone gem uses the default
          # monorepo mode too, but must let kettle-release create its own
          # GitHub Release.
          env["KETTLE_RELEASE_SKIP_GITHUB_RELEASE"] = "true" if aggregate_monorepo_github_release?
        end
        return env unless config.shared_changelog?
        if config.member_local_changelog?(member)
          return env.merge(
            "K_CHANGELOG_GEM_NAME" => member.name.to_s,
            "K_CHANGELOG_PATH" => File.join(member.root, "CHANGELOG.md"),
            "K_CHANGELOG_VERSION_FILE" => member.version_file.to_s
          )
        end

        env.merge(
          "K_CHANGELOG_GEM_NAME" => member.name.to_s,
          "K_CHANGELOG_PATH" => File.expand_path(config.changelog_path, config.root),
          "K_CHANGELOG_VERSION_FILE" => File.expand_path(config.changelog_version_file, config.root),
          # Each subgem runs a narrow suite; the aggregate root release owns
          # the family-wide coverage threshold.
          "K_CHANGELOG_COVERAGE_HARD" => "false"
        )
      end

      def local_kettle_dev_gemfile_path(local_kettle_dev)
        return nil unless local_path_env_value?(local_kettle_dev)

        candidates = [
          File.join(local_kettle_dev, "kettle-dev", "Gemfile"),
          File.join(local_kettle_dev, "Gemfile")
        ]
        candidates.find { |path| File.file?(path) }
      end

      # A release task may start with local sibling paths so a member can
      # consume a selected dependency that has not been published yet. Once
      # that dependency is complete in an earlier wave, use its registry
      # release for the next member. Dependencies outside the selected set are
      # already treated as registry dependencies; this is what makes resume
      # runs work after an earlier wave has been published.
      def release_wave_local_path_env_for(member)
        return {} unless config.release_local_path_strategy == "waves"

        env_name = config.family_local_path_env_name
        return {} if env_name.to_s.empty?

        local_value = release_env[env_name]
        return {} unless local_path_env_value?(local_value)

        selected_names = members.map(&:name)
        completed_names = Array(@release_completed_member_names)
        unresolved_selected_dependency = release_dependency_names(member).any? do |dependency|
          selected_names.include?(dependency) && !completed_names.include?(dependency)
        end
        {env_name => unresolved_selected_dependency ? local_value : "false"}
      end

      # simplecov:disable Covered by monorepo release integration, not sibling-repository suite.
      def aggregate_monorepo_github_release(members)
        version = members.map { |member| member.version.to_s }.uniq
        return aggregate_release_result("all selected members must have the same version") unless version.length == 1

        assets = members.flat_map do |member|
          gem_path = Dir[File.join(member.root, "pkg", "*.gem")].select { |path| File.basename(path).end_with?("-#{version.first}.gem") }
          checksum_path = File.join(member.root, "checksums", "#{member.name}-#{version.first}.gem.sha256")
          gem_path + (File.file?(checksum_path) ? [checksum_path] : [])
        end
        command = ["bundle", "exec", "kettle-gh-release", "--allow-unpublished", "--release-version", version.first]
        assets.each { |asset| command.concat(["--asset", asset]) }
        return aggregate_release_dry_run_result(command) unless execute

        env = release_env.merge(
          "K_CHANGELOG_GEM_NAME" => config.family_name.to_s,
          "K_CHANGELOG_PATH" => File.expand_path(config.changelog_path, config.root),
          "K_CHANGELOG_VERSION_FILE" => File.expand_path(config.changelog_version_file, config.root)
        )
        # Keep aggregate release tooling on the same local kettle-dev checkout
        # when the family release itself is running in local development mode.
        # The release config disables sibling paths for member dependency
        # resolution, but that must not hide the unreleased kettle-gh-release
        # implementation needed by this aggregate step.
        local_kettle_dev = ENV.fetch("KETTLE_DEV_DEV", "").to_s.strip
        env["KETTLE_DEV_DEV"] = local_kettle_dev if local_path_env_value?(local_kettle_dev)
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        stdout, stderr, status = Open3.capture3(env, *command, chdir: config.root)
        CommandResult.new(
          member_name: config.family_name,
          phase: "aggregate_github_release",
          command: command,
          workdir: config.root,
          status: status.exitstatus,
          success: status.success?,
          stdout: stdout,
          stderr: stderr,
          elapsed_seconds: Process.clock_gettime(Process::CLOCK_MONOTONIC) - started,
          skipped: false,
          reason: status.success? ? nil : "aggregate GitHub release failed"
        )
      rescue => error
        aggregate_release_result("#{error.class}: #{error.message}")
      end

      def explicit_monorepo_mode?
        config.data.dig("family", "mode").to_s == "monorepo"
      end

      def aggregate_monorepo_github_release?
        explicit_monorepo_mode? && family_members.length > 1
      end
      # simplecov:enable

      def aggregate_release_result(reason)
        CommandResult.new(
          member_name: config.family_name,
          phase: "aggregate_github_release",
          command: ["bundle", "exec", "kettle-gh-release"],
          workdir: config.root,
          status: 1,
          success: false,
          stdout: "",
          stderr: reason,
          elapsed_seconds: 0.0,
          skipped: false,
          reason: reason
        )
      end

      def aggregate_release_dry_run_result(command)
        CommandResult.new(
          member_name: config.family_name,
          phase: "aggregate_github_release",
          command: command,
          workdir: config.root,
          status: 0,
          success: true,
          stdout: "aggregate GitHub release dry-run; pass --execute to run\n",
          stderr: "",
          elapsed_seconds: 0.0,
          skipped: true,
          reason: "dry-run; pass --execute to run"
        )
      end

      def base_release_env
        env = config.release_env
        # kettle-family transports family policy to the standalone kettle-dev
        # release command. It does not interpret pre-release URL patterns;
        # kettle-pre-release owns validation for both release entry points.
        env["KETTLE_FAMILY_CONFIG"] = config.path if config.path
        env.merge!(TEMPLATE_QUIET_ENV) unless debug
        env["K_RELEASE_CI_CONTINUE"] = "true" if continue_ci_failures
        env["K_RELEASE_CI_WORKFLOWS"] = ci_workflows if ci_workflows && !ci_workflows.to_s.empty?
        env["KETTLE_DEV_SKIP_BUNDLE_AUDIT"] = "true" if skip_bundle_audit
        env["K_RELEASE_SKIP_REMOTES"] = skip_remotes if skip_remotes && !skip_remotes.to_s.empty?
        env["K_RELEASE_REQUIRED_REMOTES"] = required_remotes if required_remotes && !required_remotes.to_s.empty?
        env.merge!(kettle_release_secrets_env)
        env
      end

      def kettle_release_secrets_env
        return {} unless release_command_delegates_secrets_to_kettle_release?

        secrets_config = config.release_secrets
        env = {
          "KETTLE_RELEASE_SECRETS_PROVIDER" => @release_secrets_broker ? "family" : "1password",
          "KETTLE_RELEASE_GEM_SIGNING_PASSPHRASE_SOURCE" => "cached",
          "KETTLE_RELEASE_GEM_SIGNING_PASSPHRASE" => @gem_signing_password.to_s
        }
        env["KETTLE_RELEASE_SECRETS_BROKER"] = @release_secrets_broker.path if @release_secrets_broker
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

      def release_command_delegates_secrets_to_kettle_release?
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
        if command == "gha-sha-pins"
          command_text = standalone_gha_sha_pins_command(command_for("gha-sha-pins"))
          return gha_sha_pins_command(command_text: command_text)
        end
        return bup_command if command == "bup"
        return bex_command if command == "bex"

        command_for(command)
      end

      def bup_command
        args = Array(bup_args).map(&:to_s).reject(&:empty?)
        return ["bundle", "update", "--all"] if args.empty?

        ["bundle", "update", *args]
      end

      def bupb_appraisal_results(member:, runner:, memo:)
        return unless File.file?(File.join(member.root, "Appraisal.root.gemfile"))

        memo << runner.call(
          member: member,
          phase: "bupb_appraisal_root",
          command: DEFAULT_COMMANDS.fetch("bupb"),
          env: bundle_update_env.merge(
            "BUNDLE_GEMFILE" => "Appraisal.root.gemfile",
            "BUNDLE_LOCKFILE" => "Appraisal.root.gemfile.lock"
          )
        )
        return unless memo.last.ok?

        memo << runner.call(
          member: member,
          phase: "bupb_appraisal_reset",
          command: %w[bundle exec rake appraisal:reset],
          env: bundle_update_env
        )
      end

      def bex_command
        ["bundle", "exec", *Array(bex_args).map(&:to_s)]
      end

      def gha_sha_pins_command(mode: nil, input: nil, command_text: nil)
        command_text ||= command_for(command)
        args = []
        if mode == :list
          return append_command_args(command_text, ["--list", "--json"])
        end
        if mode == :review
          return append_command_args(command_text, ["--review", "--input", input.to_s, "--ttl", gha_sha_pins_ttl_days.to_s, "--json"])
        end
        args << (gha_sha_pins_check ? "--check" : "--write") unless command_includes_any?(command_text, %w[--check --write])
        args.concat(["--upgrade", gha_sha_pins_upgrade]) unless command_includes_arg?(command_text, "--upgrade")
        args << "--offline" if execute && !command_includes_arg?(command_text, "--offline")
        args << "--events" unless command_includes_arg?(command_text, "--events")
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

      # GHA pin inventory is a workspace-level release preflight, not a member
      # bundle operation. The installed RubyGems wrapper calls Gem.use_gemdeps,
      # which can load the member's Gemfile and make an otherwise independent
      # pin scan fail on unpublished sibling gems. Run the gem's actual
      # executable so this phase uses the shared installed tool and cache.
      def standalone_gha_sha_pins_command(command_text)
        argv = command_text.is_a?(Array) ? command_text.map(&:to_s) : Shellwords.split(command_text.to_s)
        executable_index = argv.index { |token| File.basename(token) == "kettle-gha-pins" }
        return command_text unless executable_index

        executable = installed_gem_executable("kettle-gha-pins", "kettle-gha-pins")
        return command_text unless executable

        [RbConfig.ruby, executable, *argv[(executable_index + 1)..]]
      rescue Gem::LoadError
        command_text
      end

      # The family changelog phase must run the standalone published tool. A
      # member's generated bin/kettle-changelog wrapper belongs to kettle-dev
      # and can no longer resolve the executable after kettle-changelog moved
      # into its own gem. Calling the gem's executable directly also avoids
      # Gem.use_gemdeps loading an unrelated member Gemfile.
      def standalone_kettle_changelog_command(command_text)
        argv = command_text.is_a?(Array) ? command_text.map(&:to_s) : Shellwords.split(command_text.to_s)
        executable_index = argv.index { |token| File.basename(token) == "kettle-changelog" }
        return command_text unless executable_index

        executable = installed_gem_executable("kettle-changelog", "kettle-changelog")
        return command_text unless executable

        [RbConfig.ruby, executable, *argv[(executable_index + 1)..]]
      rescue Gem::LoadError
        command_text
      end

      def installed_gem_executable(gem_name, executable_name)
        spec_executable = begin
          spec = Gem::Specification.find_by_name(gem_name)
          File.join(spec.full_gem_path, "exe", executable_name)
        rescue Gem::LoadError
          nil
        end
        return spec_executable if spec_executable && File.file?(spec_executable)

        candidates = Gem.path.flat_map do |gem_path|
          Dir[File.join(gem_path, "gems", "#{gem_name}-*", "exe", executable_name)]
        end
        candidates.max_by do |candidate|
          directory = File.basename(File.dirname(candidate, 2))
          version = directory.delete_prefix("#{gem_name}-")
          Gem::Version.new(version)
        rescue ArgumentError
          Gem::Version.new("0")
        end
      end

      def template_command(member)
        command_text = config.template_command || default_template_command(member)
        command_text = localize_kettle_jem_template_command(command_text)
        command_text = append_template_family_args(command_text) if kettle_jem_template_command?(command_text)
        append_template_skip_commit(command_text)
      end

      def template_prepare_command(member)
        command_text = template_prepare_command_from(config.template_command || default_template_command(member))
        command_text = standalone_kettle_jem_prepare_command(command_text)
        command_text = append_template_family_args(command_text)
        append_template_skip_commit(command_text)
      end

      # Preparation and installation invoke kettle-jem outside the member
      # bundle by default. Explicit local executable handling remains
      # available for development stacks. kettle-jem owns the member bundle
      # bootstrap, so invoking it with `bundle exec` would require the
      # dependency it is responsible for installing.
      def standalone_kettle_jem_prepare_command(command_text)
        local_executable = local_kettle_jem_executable
        executable = local_executable || installed_gem_executable("kettle-jem", "kettle-jem")
        return command_text unless executable

        array_command = command_text.is_a?(Array)
        argv = array_command ? command_text.map(&:to_s) : Shellwords.split(command_text.to_s)
        executable_index = argv.index { |token| File.basename(token) == "kettle-jem" }
        return command_text unless executable_index
        return command_text if !array_command && argv.any? { |token| %w[&& || ; |].include?(token) }

        prefix = argv[0...executable_index]
        bundle_exec = prefix.last(2) == %w[bundle exec]
        return command_text unless local_executable || bundle_exec

        prefix = prefix[0...-2] if bundle_exec
        prefix + [RbConfig.ruby, executable] + argv[(executable_index + 1)..]
      rescue ArgumentError
        command_text
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

      def default_template_command(_member)
        DEFAULT_COMMANDS.fetch("template")
      end

      def workflow_env
        {}.tap do |env|
          env.merge!(workflow_family_local_path_env)
          if command == "template"
            env["BUNDLE_DISABLE_CHECKSUM_VALIDATION"] = "true"
            env["KETTLE_JEM_TEMPLATE_PROFILE"] = config.template_profile if config.template_profile
            env["KJ_REPOSITORY_TOPOLOGY"] = config.template_repository_topology if config.template_repository_topology
            env["KETTLE_JEM_THREAD_WORKERS"] ||= template_thread_worker_budget.to_s
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

        config.family_local_path_env.each_with_object({}) do |(name, default), env|
          env[name] = ENV.key?(name) ? ENV.fetch(name) : default
        end
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
        env = workflow_env.merge(release_lockfile_local_path_env_overrides)
        explicit_local_path_env_overrides.each { |key, value| env[key] = value }
        env
      end

      def explicit_local_path_env_overrides
        ENV.to_h.merge(env_overrides).each_with_object({}) do |(key, value), overrides|
          next unless key.end_with?("_DEV", "_LOCAL") || config.release_disable_local_path_env.include?(key)
          next unless local_path_env_requested?(key)

          overrides[key] = value
        end
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

        array_command = command_text.is_a?(Array)
        argv = array_command ? command_text.map(&:to_s) : Shellwords.split(command_text.to_s)
        index = argv.index("kettle-jem")
        return command_text unless index
        return command_text if !array_command && argv.any? { |token| %w[&& || ; |].include?(token) }

        prefix = argv[0...index]
        prefix = prefix[0...-2] if prefix.last(2) == %w[bundle exec]
        prefix + [RbConfig.ruby, executable] + argv[(index + 1)..]
      rescue ArgumentError
        command_text
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

      def start_gha_sha_pins_progress(workflow_members)
        @gha_sha_pins_progress = WorkflowProgress.new(
          io: progress_io,
          label: "pinning GitHub Actions",
          total: workflow_members.length,
          jobs: jobs || 1,
          members: workflow_members
        )
        @gha_sha_pins_progress.start
        @gha_sha_pins_progress
      end

      def start_release_preflight_progress(phases)
        return nil unless progress_io

        phase_label = (phases.length == 1) ? "phase" : "phases"
        WorkflowProgress.new(
          io: progress_io,
          label: "release preflight",
          total: phases.length,
          jobs: 1,
          members: [release_preflight_progress_member],
          heading: "release preflight #{phases.length} #{phase_label}:"
        )
      end

      def release_preflight_progress_member
        @release_preflight_progress_member ||= PreflightProgressMember.new("preflight")
      end

      def template_phase_total(member = nil)
        total = 1
        total += 2 if config.normalize_lockfiles?
        total += 1 if member.nil? || template_prepares_dependencies?(member)
        total += 1 if deferred_monorepo_template_commit?(member)
        total
      end

      def release_phase_total(member = nil)
        total = 3
        if member
          normalize = normalize_release_lockfiles?(member)
          total += 2 if normalize
          total += 1 if execute && normalize
        elsif config.release_normalize_lockfiles?
          total += 2
        end
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

      def release_command_log_path(member, phase)
        return nil unless execute

        File.join(release_log_dir, "#{safe_log_name(member.name)}-#{safe_log_name(phase)}.log")
      end

      def release_log_dir
        @release_log_dir ||= File.join(config.root, "tmp", "kettle-family", "release-#{Time.now.strftime("%Y%m%d-%H%M%S")}-#{$$}")
      end

      def safe_log_name(value)
        value.to_s.gsub(/[^A-Za-z0-9_.-]+/, "_")
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
        template_summary_label(template_changed_file_count(result), template_file_outcomes(result))
      end

      def release_member_finish_status(result)
        result.skipped ? "skipped #{result.phase}" : result.phase
      end

      def emit_template_progress_summary(results, progress:)
        return unless progress

        template_results = results.select { |result| result.phase == "template" }
        changed_files = template_results.sum { |result| template_changed_file_count(result) }
        outcome_counts = template_results.map { |result| template_file_outcomes(result) }
        progress.stop
        progress.summary(template_progress_summary_label(template_results, changed_files, outcome_counts))
      end

      def emit_release_progress_summary(results, progress:)
        return unless progress

        release_results = results.select { |result| result.phase == release_phase || result.phase == "release_skip" }
        progress.stop
        progress.summary("release summary: #{release_results.count(&:ok?)}/#{release_results.length} members ok")
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
            if suppress_release_secret_provider_event?(event, progress: progress)
              next true
            elsif verbose || debug
              emit_release_event_progress(member, event)
            elsif progress&.tty?
              emit_release_event_status(member, event, progress: progress)
            end
          end
          true
        end
      end

      def gha_sha_pins_event_line_handler(member)
        return nil unless progress_io

        lambda do |line|
          event = parse_template_event(line)
          next false unless event && event["type"].to_s.start_with?("gha_sha_pins")

          if progress_io
            if verbose || debug
              emit_gha_sha_pins_event_progress(member, event)
            elsif @gha_sha_pins_progress
              emit_gha_sha_pins_event_status(member, event, progress: @gha_sha_pins_progress)
            end
          end
          true
        end
      end

      def emit_gha_sha_pins_event_progress(member, event)
        action = event["action"].to_s
        mark = (event["status"].to_s == "failed") ? "F" : "."
        label = [action, event["path"], event["action_ref"]].map(&:to_s).reject(&:empty?).join(":")
        emit_template_event_line(member, mark, label)
      end

      def emit_gha_sha_pins_event_status(member, event, progress:)
        action = event["action"].to_s
        status = case event["type"].to_s
        when "gha_sha_pins_start"
          "discovering workflows"
        when "gha_sha_pins_action"
          completed = event["completed"].to_i
          total = event["total"].to_i
          "actions: #{completed}/#{total} #{(event["cache"] == "hit") ? "cached" : "live"}"
        when "gha_sha_pins_summary"
          "#{event["changed_files"].to_i} files, #{event["updates"].to_i} updates"
        else
          action.empty? ? "processing" : action
        end
        mark = (event["status"].to_s == "failed") ? "F" : nil
        progress.update(member, status: status, mark: mark)
      end

      def suppress_release_secret_provider_event?(event, progress:)
        return false unless event["type"] == "secret_provider"
        return false unless progress

        case event["action"].to_s
        when "prompt_request", "manual_prompt"
          progress.notification(secret_provider_notification_label(event))
        when "prompt_response"
          progress.notification("")
        end

        # Prompt and provider status are transient operator notifications, not
        # tape events. Keeping them out of the member row prevents external
        # prompt output from competing with the fixed-width event tape.
        # A TTY always has a dedicated notification line. Prompt/provider
        # events must never fall through to the member-row event tape, even
        # when verbose or debug output is enabled.
        progress.tty?
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
          emit_template_event_line(member, "done", template_event_summary_label(event))
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
          template_event_summary_label(event)
        end
        mark = template_event_status_mark(event)
        progress&.update(member, status: status, mark: mark) if status && !status.empty?
      end

      def emit_release_event_progress(member, event)
        case event["type"]
        when "run_start"
          emit_template_event_line(member, ">", "release")
        when "command_step"
          emit_template_event_line(member, template_event_mark(event), command_step_event_label(event))
        when "secret_provider"
          emit_template_event_line(member, release_event_status_mark(event), secret_provider_event_label(event))
        when "remote_parity"
          emit_template_event_line(member, release_event_status_mark(event), remote_parity_event_label(event))
        when "ci_monitor"
          emit_template_event_line(member, release_event_status_mark(event), ci_monitor_event_label(event))
        when "pre_release"
          emit_template_event_line(member, release_event_status_mark(event), pre_release_event_label(event))
        when "changelog"
          emit_template_event_line(member, release_event_status_mark(event), changelog_event_label(event))
        when "release_lockfile"
          emit_template_event_line(member, release_event_status_mark(event), release_lockfile_event_label(event))
        when "release_probe"
          emit_template_event_line(member, release_event_status_mark(event), release_probe_event_label(event))
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
          command_step_event_label(event)
        when "secret_provider"
          secret_provider_event_label(event)
        when "remote_parity"
          remote_parity_event_label(event)
        when "ci_monitor"
          ci_monitor_event_label(event)
        when "pre_release"
          pre_release_event_label(event)
        when "changelog"
          changelog_event_label(event)
        when "release_lockfile"
          release_lockfile_event_label(event)
        when "release_probe"
          release_probe_event_label(event)
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
        when "secret_provider"
          template_event_mark(event)
        when "remote_parity"
          template_event_mark(event)
        when "ci_monitor"
          template_event_mark(event)
        when "pre_release"
          template_event_mark(event)
        when "changelog"
          template_event_mark(event)
        when "release_lockfile"
          template_event_mark(event)
        when "release_probe"
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

      def secret_provider_event_label(event)
        action = event["action"].to_s
        purpose = event["purpose"].to_s
        label = event["label"].to_s
        source = event["source"].to_s
        parts = ["secret"]
        parts << action unless action.empty?
        parts << purpose unless purpose.empty?
        parts << label unless label.empty?
        parts << source if purpose.empty? && label.empty? && !source.empty?
        parts << "#{event["queued"]}/#{event["total"]}" if event["queued"] && event["total"]
        parts.join(":")
      end

      def secret_provider_notification_label(event)
        action = event["action"].to_s
        return "👀 🔒 watch for authorization prompt" if action == "prompt_request"

        event["label"].to_s
      end

      def command_step_event_label(event)
        parts = [event["phase"], event["name"]].map(&:to_s).reject(&:empty?)
        summary = event["summary"].to_s
        parts << summary unless summary.empty?
        parts.join(":")
      end

      def remote_parity_event_label(event)
        action = event["action"].to_s
        remote = event["remote"].to_s
        trunk = event["trunk"].to_s
        parts = ["remote"]
        parts << action unless action.empty?
        parts << remote unless remote.empty?
        parts << trunk if remote.empty? && !trunk.empty?
        parts.join(":")
      end

      def ci_monitor_event_label(event)
        action = event["action"].to_s
        provider = event["provider"].to_s
        target = event["workflow"].to_s
        target = "pipeline" if target.empty? && provider == "gitlab"
        parts = ["ci"]
        parts << action unless action.empty?
        parts << provider unless provider.empty?
        parts << target unless target.empty?
        if %w[github_wait github_started github_tick].include?(action) && event["completed"] && event["total"]
          parts << "#{event["completed"]}/#{event["total"]}"
        end
        completed_workflow = event["completed_workflow"].to_s
        parts << completed_workflow unless completed_workflow.empty? || completed_workflow == target
        parts.join(":")
      end

      def pre_release_event_label(event)
        action = event["action"].to_s
        check = event["check"].to_s
        parts = ["pre"]
        parts << action unless action.empty?
        parts << check unless check.empty?
        parts.join(":")
      end

      def changelog_event_label(event)
        action = event["action"].to_s
        plan = event["plan"].to_s
        parts = ["changelog"]
        parts << action unless action.empty?
        parts << plan unless plan.empty? || action == "coverage"
        parts.join(":")
      end

      def release_lockfile_event_label(event)
        action = event["action"].to_s
        stage = event["stage"].to_s
        stage = stage.tr(" ", "_")
        parts = ["lockfile"]
        parts << action unless action.empty?
        parts << stage unless stage.empty?
        parts << "#{event["attempt"]}/#{event["attempts"]}" if event["attempt"] && event["attempts"]
        parts.join(":")
      end

      def release_probe_event_label(event)
        action = event["action"].to_s
        gem_name = event["gem"].to_s
        version = event["version"].to_s
        parts = ["probe"]
        parts << action unless action.empty?
        parts << [gem_name, version].reject(&:empty?).join("-")
        parts << "#{event["attempt"]}/#{event["attempts"]}" if event["attempt"] && event["attempts"]
        parts.reject(&:empty?).join(":")
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

      def template_file_outcomes(result)
        summaries = result.stdout.to_s.lines.filter_map do |line|
          event = parse_template_event(line)
          event if event && event["type"] == "summary"
        end
        summary = summaries.reverse.find { |event| template_file_outcome_event?(event) }
        return unless summary

        {
          checksum_hits: summary.fetch("checksum_hit_count").to_i,
          checksum_protected: summary.fetch("checksum_protected_count").to_i,
          unchanged: summary.fetch("unchanged_count").to_i
        }
      end

      def template_file_outcome_event?(event)
        event.key?("checksum_hit_count") && event.key?("checksum_protected_count") && event.key?("unchanged_count")
      end

      def template_event_summary_label(event)
        template_summary_label(
          event["changed_count"].to_i,
          template_file_outcome_event?(event) ? {
            checksum_hits: event.fetch("checksum_hit_count").to_i,
            checksum_protected: event.fetch("checksum_protected_count").to_i,
            unchanged: event.fetch("unchanged_count").to_i
          } : nil
        )
      end

      def template_progress_summary_label(template_results, changed_files, outcome_counts)
        label = "template summary: #{template_results.count(&:ok?)}/#{members.length} members ok"
        return "#{label}, #{template_summary_label(changed_files)}" unless outcome_counts.all?

        totals = outcome_counts.each_with_object({checksum_hits: 0, checksum_protected: 0, unchanged: 0}) do |outcomes, memo|
          memo[:checksum_hits] += outcomes.fetch(:checksum_hits)
          memo[:checksum_protected] += outcomes.fetch(:checksum_protected)
          memo[:unchanged] += outcomes.fetch(:unchanged)
          memo
        end
        "#{label}, #{template_summary_label(changed_files, totals)}"
      end

      def template_summary_label(changed_files, outcomes = nil)
        changed_label = "#{changed_files} file#{"s" unless changed_files == 1} changed"
        return changed_label unless outcomes

        protected_label = if outcomes.fetch(:checksum_protected).positive?
          ", #{outcomes.fetch(:checksum_protected)} checksum-protected changes"
        else
          ""
        end
        "#{outcomes.fetch(:checksum_hits)} checksum hits#{protected_label}, #{outcomes.fetch(:unchanged)} unchanged, #{changed_label}"
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
        if checksum_option_unsupported?(result)
          recovery = runner.call(
            member: member,
            phase: "#{phase}_bundler_recovery",
            command: %w[bundle update --bundler],
            env: workflow_env
          )
          memo << recovery
          return unless recovery.ok?

          result = runner.call(
            member: member,
            phase: phase,
            command: normalize_lockfiles_command(member: member, phase: phase, skip_checksum_option: true),
            env: workflow_env
          )
        end
        if template_lockfile_phase?(phase) && recoverable_bundle_failure?(result)
          recover_template_lockfiles(member: member, runner: runner, memo: memo, phase: "#{phase}_recovery")
          return unless memo.last&.ok?

          result = runner.call(
            member: member,
            phase: phase,
            command: normalize_lockfiles_command(member: member, phase: phase),
            env: workflow_env
          )
        end
        memo << result
      end

      def recover_template_lockfiles(member:, runner:, memo:, phase:)
        reset_gemfile_lock(
          member: member,
          runner: runner,
          memo: memo,
          phase: phase,
          env: template_lockfile_recovery_env(member)
        )
        return unless memo.last&.ok?

        commit_normalized_lockfiles(
          branch_members: [member],
          runner: runner,
          memo: memo,
          reason: "reset",
          force: true
        )
      end

      def recoverable_bundle_failure?(result)
        return false unless execute && !result.ok?

        output = [result.stdout, result.stderr].join("\n")
        output.match?(/Bundler::(?:GemNotFound|VersionConflict)|Could not (?:find|resolve) |already activated .* but your Gemfile requires/)
      end

      def checksum_option_unsupported?(result)
        return false unless execute && !result.ok?

        [result.stdout, result.stderr].join("\n").match?(/Unknown switches? .*--add-checksums/)
      end

      def template_lockfile_recovery_env(member)
        env = release_lockfile_env(member).merge(workflow_env)
        ENV.each do |key, value|
          env[key] = value if key.end_with?("_DEV", "_LOCAL") && local_path_env_requested?(key)
        end
        env.merge!(env_overrides)
        env["K_JEM_TEMPLATING"] = "false"
        env["BUNDLE_DISABLE_CHECKSUM_VALIDATION"] = "true"
        env
      end

      def normalize_lockfiles_command(member:, phase:, skip_checksum_option: false)
        configured = config.normalize_lockfiles_command
        return configured unless template_prepare_lockfiles_phase?(phase)
        return %w[bundle install] if bundle_update_command?(configured) && !File.file?(File.join(member.root, "Gemfile.lock"))

        command = PRE_TEMPLATE_BOOTSTRAP_GEMS.select { |gem_name| member_declares_or_locks_gem?(member, gem_name) }.reduce(configured) do |command_text, gem_name|
          append_command_arg(command_text, gem_name)
        end
        command = remove_command_arg(command, "nomono") unless member_declares_or_locks_gem?(member, "nomono")
        skip_checksum_option ? remove_command_arg(command, "--add-checksums") : command
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

        return append_command_arg_to_argv(command_text.map(&:to_s), arg) if command_text.is_a?(Array)

        # CommandRunner executes String commands through `sh -lc`. Ruby has no
        # shell AST, so only parse the leading command segment and retain a
        # configured compound-command operator and its remaining segments.
        command, separator, remainder = command_text.to_s.partition(/\s(?:&&|\|\||;)\s/)
        argv = append_command_arg_to_argv(Shellwords.split(command), arg)
        [argv.shelljoin, separator, remainder].join
      rescue ArgumentError
        "#{command_text} #{Shellwords.escape(arg)}"
      end

      def append_command_arg_to_argv(argv, arg)
        update_index = argv.index("update")
        if update_index
          option_index = argv[(update_index + 1)..]&.index { |token| token.start_with?("-") }
          insert_index = option_index ? update_index + 1 + option_index : argv.length
          argv.insert(insert_index, arg)
        else
          argv << arg
        end
        argv
      end

      def remove_command_arg(command_text, arg)
        return command_text.map(&:to_s).reject { |token| token == arg } if command_text.is_a?(Array)

        # CommandRunner executes String commands through `sh -lc`; Shellwords
        # cannot round-trip shell operators such as `&&` without turning them
        # into literal arguments. Remove this known standalone option in place.
        command_text.to_s.gsub(/(?<!\S)#{Regexp.escape(arg)}(?=\s|\z)/, "").gsub(/[ \t]{2,}/, " ").strip
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

      def member_declares_or_locks_gem?(member, gem_name)
        return true if member_lockfile_contains_gem?(member, gem_name)

        gemfile = File.join(member.root, "Gemfile")
        return false unless File.file?(gemfile)

        parsed = Kettle::Dev::VersionBump.parse_source(File.read(gemfile), gemfile)
        Kettle::Dev::VersionBump.each_node(parsed.value).any? do |node|
          node.is_a?(Prism::CallNode) && node.name == :gem &&
            node.arguments&.arguments&.first.is_a?(Prism::StringNode) &&
            node.arguments.arguments.first.unescaped == gem_name
        end
      end

      def template_prepare_lockfiles_phase?(phase)
        command == "template" && phase == "prepare_lockfiles"
      end

      def template_lockfile_phase?(phase)
        command == "template" && %w[prepare_lockfiles normalize_lockfiles].include?(phase)
      end

      def repair_checksum_mismatches(member, result)
        return false unless execute
        return false if result.ok?

        line_numbers = checksum_mismatch_lockfile_lines([result.stdout, result.stderr].join("\n"))
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
        if recoverable_bundle_failure?(result)
          recover_template_lockfiles(
            member: member,
            runner: runner,
            memo: memo,
            phase: "prepare_template_dependencies_recovery"
          )
          if no_release_lockfiles_failure?(memo.last)
            memo.pop
            memo << result
            return false
          end
          return false unless memo.last&.ok?

          result = runner.call(
            member: member,
            phase: "prepare_template_dependencies",
            command: template_prepare_command(member),
            env: template_prepare_env
          )
        end
        memo << result
        result.ok?
      end

      def no_release_lockfiles_failure?(result)
        result && !result.ok? && [result.stdout, result.stderr].join("\n").include?("kettle-reset: no release lockfiles found")
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
        env[family_env_name] = "false" if family_env_name && !local_path_env_requested?(family_env_name)
        env
      end

      def local_path_env_requested?(name)
        env_overrides.key?(name) || ENV.key?(name)
      end

      def template_thread_worker_budget
        member_jobs = template_jobs(members)
        [1, (Etc.nprocessors / member_jobs) - 1].max
      end

      def normalize_release_lockfiles(member:, runner:, memo:)
        result = runner.call(
          member: member,
          phase: "release_normalize_lockfiles",
          command: config.release_normalize_lockfiles_command,
          env: release_lockfile_env(member)
        )
        memo << result
        return unless execute && result.ok?

        memo << runner.call(
          member: member,
          phase: "release_bundle_install",
          command: %w[bundle install],
          env: release_lockfile_env(member)
        )
      end

      def normalize_release_lockfiles?(member)
        # kettle-release owns its release lockfile reset and runs it before
        # setup, checks, and publishing. Running the family-level reset too
        # makes two Bundler processes rewrite the same platform set.
        return false if kettle_release_command?(raw_release_command)

        config.release_normalize_lockfiles? || release_lockfile_has_local_path_remote?(member)
      end

      def release_lockfile_readiness_would_fail?(member)
        result = ReadinessCheck.call(member: member, config: config, allowed_local_path_roots: release_allowed_local_path_roots)
        result.stdout.lines.any? { |line| line.start_with?("release lockfile has local path remote at ") }
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
        # Release env disables are passed to Bundler normalization, but they
        # must not hide the active workspace roots from readiness diagnostics.
        release_local_path_env_detection_sources.filter_map do |key, value|
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
