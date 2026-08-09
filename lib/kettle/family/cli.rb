# frozen_string_literal: true

require "command_kit"
require "command_kit/commands"
require "fileutils"
require "optparse"

module Kettle
  module Family
    class CLI < CommandKit::Command
      include CommandKit::Commands

      COMMANDS = %w[version mise-trust discover plan report metadata check clean-unreleased reconcile-releases reset test lint docs template gha-sha-pins bup bupb bex install bump bump-version add-changelog release push pull sync up branch-lanes release-state state].freeze
      WORKFLOW_COMMANDS = %w[check reset test lint docs template gha-sha-pins bup bupb bex release push pull sync up].freeze

      command_name "kettle-family"
      usage "[options] COMMAND [ARGS...]"
      description "Coordinate related Ruby gems as one family."

      option :root, value: {type: String, usage: "PATH"}, desc: "Workspace or family root"
      option :config, value: {type: String, usage: "PATH"}, desc: "Family config path"
      option :json, desc: "Print JSON report to stdout"
      option :report, value: {type: String, usage: "PATH"}, desc: "Write JSON report to PATH"
      option :events, desc: "Stream release-state analysis as NDJSON"

      def self.call(argv, out: $stdout, err: $stderr)
        main(argv, stdout: out, stderr: err)
      end

      module SharedOptions
        def self.included(base)
          base.option :root, value: {type: String, usage: "PATH"}, desc: "Workspace or family root"
          base.option :config, value: {type: String, usage: "PATH"}, desc: "Family config path"
          base.option :json, desc: "Print JSON report to stdout"
          base.option :report, value: {type: String, usage: "PATH"}, desc: "Write JSON report to PATH"
          base.option :events, desc: "Stream release-state analysis as NDJSON"
        end
      end

      module SelectionOptions
        def self.included(base)
          base.option :only, value: {type: String, usage: "MEMBERS"}, desc: "Select comma-separated members, or release-state tokens: unreleased/unrel, prepared/prep, pending/pend, bump"
          base.option :exclude, value: {type: String, usage: "MEMBERS"}, desc: "Exclude comma-separated members"
          base.option :start_at, long: "--start-at", value: {type: String, usage: "MEMBER[@BRANCH]"}, desc: "Select from member through the end of order"
        end
      end

      module ExecutionOptions
        def self.included(base)
          base.option :execute, desc: "Execute external workflow commands"
          base.option :dry_run, long: "--dry-run", desc: "Plan external workflow commands without running them" do
            options[:execute] = false
          end
        end
      end

      module CommitOptions
        def self.included(base)
          base.option :commit, desc: "Allow workflow commands that change files to commit"
          base.option :no_commit, long: "--no-commit", desc: "Skip automatic commits after mutating workflow commands" do
            options[:commit] = false
          end
          base.option :allow_dirty, long: "--allow-dirty", desc: "Reserved for compatibility; member repos manage their own commit safety"
          base.option :autostash, long: "--autostash", desc: "Use the default template autostash behavior"
          base.option :no_autostash, long: "--no-autostash", desc: "Fail template runs when a member worktree is dirty" do
            options[:autostash] = false
          end
        end
      end

      module ParallelOptions
        def self.included(base)
          base.option :jobs, value: {type: Integer, usage: "N"}, desc: "Parallel jobs for supported workflows"
        end
      end

      module WorkflowOptions
        def self.included(base)
          base.option :debug, desc: "Preserve debug environment for workflow commands"
          base.option :verbose, desc: "Pass verbose mode through to supported workflow commands"
          ParallelOptions.included(base)
          base.option :env, value: {type: String, usage: "KEY=VALUE"}, desc: "Override an environment variable for each member workflow command" do |value|
            parse_env_override(value, workflow_env)
          end
        end
      end

      module ReturningMain
        def main(argv = [])
          args = parse_options(argv)
          return 1 unless valid_argument_count?(args)

          run(*args)
        rescue SystemExit => error
          error.status
        rescue Error, OptionParser::ParseError => error
          stderr.puts("kettle-family: #{error.message}")
          1
        end

        private

        def valid_argument_count?(args)
          required_args = self.class.arguments.each_value.count(&:required?)
          optional_args = self.class.arguments.each_value.count(&:optional?)
          has_repeats_arg = self.class.arguments.each_value.any?(&:repeats?)
          return true if args.length >= required_args && (has_repeats_arg || args.length <= (required_args + optional_args))

          message = if args.length < required_args
            "insufficient number of arguments"
          else
            "unexpected argument(s): #{args[(required_args + optional_args)..].join(" ")}"
          end
          stderr.puts("kettle-family: #{message}")
          help_usage
          false
        end

        def on_parse_error(error)
          raise error
        end
      end

      class BaseCommand < CommandKit::Command
        prepend ReturningMain

        include SharedOptions
        include SelectionOptions

        def initialize(**kwargs)
          super
          @workflow_env = {}
        end

        private

        attr_reader :workflow_env

        def family_options(overrides = {})
          {
            root: options[:root] || Dir.pwd,
            config: options[:config],
            only: options[:only],
            exclude: options[:exclude],
            start_at: options[:start_at],
            json: truthy_option?(:json),
            events: truthy_option?(:events),
            report: options[:report],
            execute: truthy_option?(:execute),
            debug: truthy_option?(:debug),
            verbose: truthy_option?(:verbose),
            jobs: options[:jobs],
            workflow_env: workflow_env,
            changelog_section: nil,
            changelog_entry: nil,
            check: truthy_option?(:check),
            from_version: nil,
            gha_sha_pins_upgrade: "patch",
            gha_sha_pins_ttl_days: options[:ttl],
            publish: false,
            release_start_step: nil,
            release_skip_steps: nil,
            release_local_ci: false,
            release_continue_ci_failures: false,
            release_ci_workflows: nil,
            release_skip_bundle_audit: false,
            release_skip_remotes: nil,
            release_required_remotes: nil,
            release_secrets_provider: nil,
            accept: true,
            tag: false,
            push: false,
            commit: !options.key?(:commit) || options[:commit],
            allow_dirty: truthy_option?(:allow_dirty),
            autostash: !options.key?(:autostash) || options[:autostash],
            target_version: nil,
            reset_target: nil,
            bup_args: [],
            bex_args: []
          }.merge(overrides)
        end

        def run_family(command, overrides = {})
          Kettle::Family::CLI.new(stdout: stdout, stderr: stderr).run_command(command, family_options(overrides))
        end

        def truthy_option?(name)
          options.key?(name) && !!options[name]
        end

        def parse_env_override(value, env)
          key, env_value = value.split("=", 2)
          raise OptionParser::InvalidArgument, "--env requires KEY=VALUE" if key.to_s.empty? || env_value.nil?
          raise OptionParser::InvalidArgument, "invalid environment variable name #{key.inspect}" unless key.match?(/\A[A-Za-z_][A-Za-z0-9_]*\z/)

          env[key] = env_value
        end

        def parse_gha_sha_pins_upgrade(value)
          normalized = value.to_s.downcase
          return normalized if %w[major minor patch].include?(normalized)

          raise OptionParser::InvalidArgument, "--upgrade must be one of: major, minor, patch"
        end

        def unexpected_arguments!(args)
          raise OptionParser::InvalidArgument, "unexpected argument(s): #{args.join(" ")}" unless args.empty?
        end
      end

      class Discover < BaseCommand
        command_name "discover"
        usage "[options]"
        description "Discover family members and print selected order."

        def run(*args)
          unexpected_arguments!(args)
          run_family("discover")
        end
      end

      class Version < CommandKit::Command
        command_name "version"
        usage ""
        description "Print the kettle-family version."

        def run(*args)
          raise OptionParser::InvalidArgument, "unexpected argument(s): #{args.join(" ")}" unless args.empty?

          stdout.puts(Kettle::Family::Version::VERSION)
          0
        end
      end

      class MiseTrust < BaseCommand
        command_name "mise-trust"
        usage "[options]"
        description "Trust mise.toml at the family root and selected member roots."

        def run(*args)
          unexpected_arguments!(args)
          run_family("mise-trust", execute: true)
        end
      end

      class Plan < Discover
        command_name "plan"
        description "Alias for discover while execution workflows are built."

        def run(*args)
          unexpected_arguments!(args)
          run_family("plan")
        end
      end

      class ReportCommand < Discover
        command_name "report"
        description "Print family discovery and configuration report."

        def run(*args)
          unexpected_arguments!(args)
          run_family("report")
        end
      end

      class Metadata < BaseCommand
        command_name "metadata"
        usage "[options]"
        description "Print version, Ruby floor, license, and author metadata."

        def run(*args)
          unexpected_arguments!(args)
          run_family("metadata")
        end
      end

      class BranchLanes < BaseCommand
        command_name "branch-lanes"
        usage "[options]"
        description "Audit configured branch lanes."

        def run(*args)
          unexpected_arguments!(args)
          run_family("branch-lanes")
        end
      end

      class ReleaseState < BaseCommand
        include ParallelOptions

        command_name "release-state"
        usage "[options]"
        description "Report changelog release state for family members."

        def run(*args)
          unexpected_arguments!(args)
          run_family("release-state")
        end
      end

      class State < ReleaseState
        command_name "state"
        description "Alias for release-state."

        def run(*args)
          unexpected_arguments!(args)
          run_family("release-state")
        end
      end

      class WorkflowCommand < BaseCommand
        include ExecutionOptions
        include WorkflowOptions
        include CommitOptions

        def run(*args)
          unexpected_arguments!(args)
          run_family(self.class.command_name)
        end
      end

      class Check < WorkflowCommand
        command_name "check"
        usage "[options]"
        description "Run internal read-only readiness checks."
      end

      class CleanUnreleased < WorkflowCommand
        command_name "clean-unreleased"
        usage "[options]"
        description "Uninstall locally installed family gem versions newer than the latest released version."
      end

      class ReconcileReleases < BaseCommand
        include ExecutionOptions

        command_name "reconcile-releases"
        usage "[options]"
        description "Check RubyGems releases for missing GitHub Releases; --execute creates only verified backfills."

        def run(*args)
          unexpected_arguments!(args)
          run_family("reconcile-releases")
        end
      end

      class Reset < WorkflowCommand
        command_name "reset"
        usage "[options] TARGET"
        description "Reset a managed family artifact. Initially supports Gemfile.lock."
        argument :target, required: true, usage: "TARGET", desc: "Artifact to reset"

        def run(target = nil)
          raise Error, "reset requires TARGET" if target.to_s.empty?

          run_family("reset", reset_target: target)
        end
      end

      class Test < WorkflowCommand
        command_name "test"
        usage "[options]"
        description "Plan or execute configured test command per member."
      end

      class Lint < WorkflowCommand
        command_name "lint"
        usage "[options]"
        description "Plan or execute configured lint command per member."
      end

      class Docs < WorkflowCommand
        command_name "docs"
        usage "[options]"
        description "Plan or execute configured docs command per member."
      end

      class Template < WorkflowCommand
        command_name "template"
        usage "[options]"
        description "Plan or execute kettle-jem templating per member."
      end

      class GhaShaPins < WorkflowCommand
        command_name "gha-sha-pins"
        usage "[options]"
        description "Plan or execute kettle-gha-pins per member."

        option :check, desc: "Check whether SHA pins would need edits"
        option :upgrade, value: {type: String, usage: "LEVEL"}, desc: "SHA pin upgrade strategy: major, minor, patch" do |value|
          options[:upgrade] = parse_gha_sha_pins_upgrade(value)
        end
        option :ttl, value: {type: Float, usage: "DAYS"}, desc: "Cache TTL for action metadata review (default: 1 day)" do |value|
          raise OptionParser::InvalidArgument, "--ttl must be non-negative" if value.negative?

          options[:ttl] = value
        end

        def run(*args)
          unexpected_arguments!(args)
          run_family("gha-sha-pins", gha_sha_pins_upgrade: options[:upgrade] || "patch", gha_sha_pins_ttl_days: options[:ttl])
        end
      end

      class Bup < WorkflowCommand
        command_name "bup"
        usage "[options] [GEM]"
        description "Plan or execute bundle update --all, or bundle update GEM."
        argument :gems, required: false, repeats: true, usage: "GEM", desc: "Gem name(s) to update"

        def run(*bup_args)
          run_family("bup", bup_args: bup_args)
        end
      end

      class Bupb < WorkflowCommand
        command_name "bupb"
        usage "[options]"
        description "Plan or execute bundle update --bundler."
      end

      class Bex < WorkflowCommand
        command_name "bex"
        usage "[options] -- COMMAND [ARGS...]"
        description "Plan or execute bundle exec COMMAND per member."
        argument :command, required: false, repeats: true, usage: "COMMAND [ARGS...]", desc: "Command and arguments to run through bundle exec"

        def run(*bex_args)
          raise Error, "bex requires COMMAND [ARGS]" if bex_args.empty?

          run_family("bex", bex_args: bex_args)
        end
      end

      class Install < BaseCommand
        include ExecutionOptions

        command_name "install"
        usage "[options]"
        description "Build and install selected local family gems."

        option :jobs, value: {type: Integer, usage: "N"}, desc: "Parallel jobs for executed installs"

        def run(*args)
          unexpected_arguments!(args)
          run_family("install")
        end
      end

      class Bump < BaseCommand
        include ExecutionOptions
        include CommitOptions

        command_name "bump"
        usage "[options] VERSION|major|minor|patch|pre"
        description "Check, plan, or execute family version alignment."
        argument :target_version, required: false, usage: "VERSION|major|minor|patch|pre", desc: "Version or bump target"

        option :check, desc: "Check whether version bumps would need edits"
        option :from, value: {type: String, usage: "VERSION"}, desc: "Require selected members to currently match VERSION"

        def run(target_version = nil)
          raise Error, "#{workflow_command_name} requires VERSION, major, minor, patch, or pre" unless target_version

          run_family(workflow_command_name, target_version: target_version, from_version: options[:from])
        end

        private

        def workflow_command_name
          "bump"
        end
      end

      class BumpVersion < Bump
        command_name "bump-version"
        description "Deprecated alias for bump."

        def run(target_version = nil)
          stderr.puts("kettle-family: bump-version is deprecated; use bump instead.")
          super
        end

        private

        def workflow_command_name
          "bump-version"
        end
      end

      class AddChangelog < BaseCommand
        include ExecutionOptions

        command_name "add-changelog"
        usage "[options]"
        description "Add an entry to an existing Unreleased changelog section."

        option :section, value: {type: String, usage: "NAME"}, desc: "Changelog section"
        option :entry, value: {type: String, usage: "TEXT"}, desc: "Changelog entry"

        def run(*args)
          unexpected_arguments!(args)
          run_family("add-changelog", changelog_section: options[:section], changelog_entry: options[:entry])
        end
      end

      class Release < BaseCommand
        include ExecutionOptions
        include WorkflowOptions
        include CommitOptions

        command_name "release"
        usage "[options]"
        description "Plan or execute release build/publish phases."

        option :publish, desc: "Use publish release command instead of build command"
        option :build_only, long: "--build-only", desc: "Use build release command" do
          options[:publish] = false
        end
        option :start_step, long: "--start-step", value: {type: Integer, usage: "N"}, desc: "Pass start_step=N through to kettle-release commands"
        option :skip_steps, long: "--skip-steps", value: {type: String, usage: "LIST"}, desc: "Pass skip_steps=LIST through to kettle-release commands"
        option :local_ci, long: "--local-ci", desc: "Pass --local-ci through to kettle-release commands"
        option :continue_ci_failures, long: "--continue-ci-failures", desc: "Set K_RELEASE_CI_CONTINUE=true for release commands"
        option :ci_workflows, long: "--ci-workflows", value: {type: String, usage: "LIST"}, desc: "Pass a comma-separated CI workflow monitor subset through to kettle-release commands"
        option :skip_bundle_audit, long: "--skip-bundle-audit", desc: "Skip bundle:audit/update during release rake checks"
        option :skip_remotes, long: "--skip-remotes", value: {type: String, usage: "LIST"}, desc: "Pass a comma-separated git remote skip list through to kettle-release commands"
        option :required_remotes, long: "--required-remotes", value: {type: String, usage: "LIST"}, desc: "Pass a comma-separated required git remote list through to kettle-release commands"
        option :secrets_provider, long: "--secrets-provider", value: {type: String, usage: "NAME"}, desc: "Release secrets provider: interactive, 1password"
        option :no_auto_floors, long: "--no-auto-floors", desc: "Do not raise family dependency floors between member releases" do
          options[:no_auto_floors] = true
        end
        option :accept, desc: "Answer yes to confirmation prompts in interactive commands"
        option :no_accept, long: "--no-accept", desc: "Wait for user input at confirmation prompts" do
          options[:accept] = false
        end
        option :tag, desc: "Add release tag phase"
        option :push, desc: "Add release push phase"

        def run(*args)
          unexpected_arguments!(args)
          run_family(
            "release",
            publish: truthy_option?(:publish),
            release_start_step: options[:start_step],
            release_skip_steps: options[:skip_steps],
            release_local_ci: truthy_option?(:local_ci),
            release_continue_ci_failures: truthy_option?(:continue_ci_failures),
            release_ci_workflows: options[:ci_workflows],
            release_skip_bundle_audit: truthy_option?(:skip_bundle_audit),
            release_skip_remotes: options[:skip_remotes],
            release_required_remotes: options[:required_remotes],
            release_secrets_provider: options[:secrets_provider],
            release_auto_dependency_floors: !truthy_option?(:no_auto_floors),
            accept: !options.key?(:accept) || options[:accept],
            tag: truthy_option?(:tag),
            push: truthy_option?(:push)
          )
        end
      end

      class Push < WorkflowCommand
        command_name "push"
        usage "[options]"
        description "Plan or execute git push per member."
      end

      class Pull < WorkflowCommand
        command_name "pull"
        usage "[options]"
        description "Plan or execute git pull --rebase per member."
      end

      class Sync < WorkflowCommand
        command_name "sync"
        usage "[options]"
        description "Plan or execute default-branch fetch/rebase and branch rebase per member."
      end

      class Up < WorkflowCommand
        command_name "up"
        usage "[options]"
        description "Plan or execute git pull --rebase then git push per member."
      end

      command Discover
      command Version
      command MiseTrust
      command Plan
      command "report", ReportCommand
      command Metadata
      command Check
      command CleanUnreleased
      command ReconcileReleases
      command Reset
      command Test
      command Lint
      command Docs
      command Template
      command GhaShaPins
      command Bup
      command Bupb
      command Bex
      command Install
      command Bump
      command BumpVersion
      command AddChangelog
      command Release
      command Push
      command Pull
      command Sync
      command Up
      command BranchLanes
      command ReleaseState
      command State

      prepend ReturningMain

      def run(command = nil, *argv)
        return invoke(command, *argv) if command

        help
        0
      end

      def on_unknown_command(name, _argv = [])
        stderr.puts("kettle-family: unknown command #{name.inspect}")
        1
      end

      def run_command(command, options)
        report = build_report(command, options)
        write_report(report, options)
        if options[:events] && command == "release-state"
          stdout.puts(JSON.generate("event_version" => 1, "type" => "summary", "report" => report.to_h))
        else
          stdout.puts(options[:json] ? report.to_json : report.to_text)
        end
        report.success? ? 0 : 1
      rescue Error, OptionParser::ParseError => error
        stderr.puts("kettle-family: #{error.message}")
        1
      end

      private

      def build_report(command, options)
        config = Config.load(root: options[:root], path: options[:config])
        start_at = parse_start_at(options[:start_at])
        effective_only = default_only_filter(command: command, only: options[:only])
        discovery = Discovery.new(
          config: config,
          release_dependency_member_names: direct_member_only_names(effective_only)
        )
        members = discovery.members
        ordered = if command == "install"
          install_order(members, config)
        elsif %w[metadata release-state].include?(command)
          members.sort_by(&:name)
        else
          Orderer.new(members: members, mode: config.order_mode, hints: config.order_hints).ordered
        end
        state_event_tape = release_state_event_tape(command: command, config: config, options: options)
        release_state_results = release_state_results_for_selection(config: config, members: ordered, only: effective_only, jobs: options[:jobs])
        selected = Selection.new(
          members: ordered,
          release_state_results: release_state_results,
          shared_version: config.shared_changelog?
        ).apply(only: effective_only, exclude: options[:exclude], start_at: start_at.member)
        result_members = selected
        display_members = display_members_for(command: command, config: config, members: ordered, selected_members: selected)
        display_selected_members = display_members_for(command: command, config: config, members: selected, selected_members: selected)
        print_execution_intent(command: command, config: config, members: display_selected_members, options: options, start_at: start_at)
        started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        state_progress = release_state_progress(command: command, members: result_members, options: options)
        state_progress&.start
        state_event_handler = release_state_event_handler(
          event_tape: state_event_tape,
          progress: state_progress,
          members: result_members
        )
        results = command_results(
          command: command,
          config: config,
          members: result_members,
          options: options,
          start_at: start_at,
          state_event_handler: state_event_handler
        )
        state_progress&.finish
        elapsed_seconds = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at
        Report.new(
          family_name: config.family_name,
          family_mode: config.family_mode,
          order_mode: config.order_mode,
          members: display_members,
          selected_members: selected,
          config_path: config.path,
          branch_lanes: config.branch_lanes,
          release_target_branches: release_target_branches(command: command, config: config, start_at: start_at),
          member_release_target_branches: member_release_target_branches(command: command, members: selected, config: config, start_at: start_at),
          release_mode: release_mode(command: command, options: options),
          command: command,
          results: results,
          warnings: discovery.warnings,
          event_log_dirs: state_event_tape ? [state_event_tape.directory] : [],
          elapsed_seconds: elapsed_seconds
        )
      end

      StartAt = Struct.new(:member, :branch)

      def command_results(command:, config:, members:, options:, start_at:, state_event_handler: nil)
        return branch_target_command_results(command: command, config: config, members: members, options: options, start_at: start_at) if branch_target_command?(command, config)
        return member_local_branch_target_command_results(command: command, config: config, members: members, options: options, start_at: start_at) if member_local_branch_target_command?(command, config, members)

        command_results_for_current_branch(command: command, config: config, members: members, options: options, start_at: start_at, state_event_handler: state_event_handler)
      end

      def release_state_results_for_selection(config:, members:, only:, jobs: nil)
        return nil unless only.to_s.split(",").map(&:strip).any? { |token| Selection.status_token?(token) }

        ReleaseStateCheck.new(config: config, members: members, jobs: jobs).results
      end

      def default_only_filter(command:, only:)
        return only unless only.to_s.empty?
        return "bump" if %w[bump bump-version].include?(command)
        return "pending" if command == "release"

        only
      end

      def direct_member_only_names(only)
        names = only.to_s.split(",").map(&:strip).reject(&:empty?)
        return nil if names.empty? || names.any? { |name| Selection.status_token?(name) }

        names
      end

      def display_members_for(command:, config:, members:, selected_members:)
        return members unless command == "release"

        require_relative "release_waves"
        planned = ReleaseWaves.new(
          members: selected_members,
          configured_waves: config.release_waves,
          strict_cycles: true
        ).waves.flatten
        planned_names = planned.map(&:name)
        planned + members.reject { |member| planned_names.include?(member.name) }
      rescue Error
        # Let the workflow report invalid cycles or wave configuration. The
        # display should not prevent that diagnostic from being produced.
        members
      end

      def command_results_for_current_branch(command:, config:, members:, options:, start_at: StartAt.new(nil, nil), state_event_handler: nil)
        return mise_trust_results(config: config, members: members) if command == "mise-trust"
        return bump_version_results(config: config, members: members, options: options, phase: command) if %w[bump bump-version].include?(command)
        return add_changelog_results(members: members, options: options) if command == "add-changelog"
        return clean_unreleased_results(config: config, members: members, options: options) if command == "clean-unreleased"
        return reconcile_release_results(config: config, members: members, options: options) if command == "reconcile-releases"
        return branch_lane_results(config: config, members: members) if command == "branch-lanes"
        return release_state_results(config: config, members: members, jobs: options[:jobs], event_handler: state_event_handler) if command == "release-state"
        return install_results(config: config, members: members, options: options) if command == "install"
        return [] unless WORKFLOW_COMMANDS.include?(command)

        Workflow.new(
          command: command,
          config: config,
          members: members,
          execute: options[:execute],
          accept: options[:accept],
          commit: options[:commit],
          allow_dirty: options[:allow_dirty],
          autostash: options[:autostash],
          publish: options[:publish],
          push: options[:push],
          tag: options[:tag],
          start_step: options[:release_start_step],
          skip_steps: options[:release_skip_steps],
          local_ci: options[:release_local_ci],
          continue_ci_failures: options[:release_continue_ci_failures],
          ci_workflows: options[:release_ci_workflows],
          skip_bundle_audit: options[:release_skip_bundle_audit],
          skip_remotes: options[:release_skip_remotes],
          required_remotes: options[:release_required_remotes],
          secrets_provider: release_secrets_provider(command: command, config: config, options: options),
          auto_dependency_floors: options[:release_auto_dependency_floors],
          gha_sha_pins_upgrade: options[:gha_sha_pins_upgrade],
          gha_sha_pins_check: options[:check],
          gha_sha_pins_ttl_days: options[:gha_sha_pins_ttl_days],
          env_overrides: options[:workflow_env],
          debug: options[:debug],
          verbose: options[:verbose],
          jobs: options[:jobs],
          progress_io: progress_io(command, options),
          reset_target: options[:reset_target],
          bup_args: options[:bup_args],
          bex_args: options[:bex_args],
          start_member: start_at.member,
          start_branch: start_at.branch
        ).results
      end

      def mise_trust_results(config:, members:)
        roots = [config.root, *members.map(&:root)].uniq
        runner = CommandRunner.new(execute: true, accept: true)
        roots.map.with_index do |root, index|
          member = members.find { |candidate| candidate.root == root } || Member.new("family", root, nil, nil, nil, [], [], nil, [], [])
          runner.call(member: member, phase: "mise_trust", command: ["mise", "trust", "-C", root], env: {})
        end
      end

      def progress_io(command, options)
        return nil unless %w[release template gha-sha-pins].include?(command)
        return nil unless options[:execute]
        return nil if options[:json]

        stdout
      end

      def release_state_progress(command:, members:, options:)
        return nil unless command == "release-state"
        return nil if options[:events] || options[:json]
        return nil unless stdout.respond_to?(:tty?) && stdout.tty?

        WorkflowProgress.new(
          io: stdout,
          label: "release state",
          total: members.length,
          jobs: [options[:jobs].to_i, 1].max,
          members: members,
          heading: "release state #{members.length} member#{"s" unless members.length == 1}:"
        )
      end

      def release_state_event_handler(event_tape:, progress:, members:)
        return nil unless event_tape || progress

        members_by_name = members.to_h { |member| [member.name, member] }
        lambda do |event|
          event_tape&.call(event)
          next unless progress

          member = members_by_name[event["member"]]
          next unless member

          action = event["action"].to_s
          status = event["status"].to_s
          case action
          when "member_start"
            progress.start_member(member, total: 5, status: "release_state")
          when "member_complete"
            progress.finish_member(member, success: status == "ok", status: status)
          when "changelog_command", "computed_booleans", "git_state", "github_release", "transfer_changelog"
            if status == "running"
              progress.update(member, status: action)
            elsif status == "ok" || status == "failed"
              progress.advance(member, status: action, success: status == "ok")
            end
          end
        end
      end

      def print_execution_intent(command:, config:, members:, options:, start_at:)
        return unless command == "release"
        return unless options[:execute]
        return if options[:json]

        stdout.puts("release intent:")
        stdout.puts("  family: #{config.family_name}")
        stdout.puts("  mode: #{options[:publish] ? "publish" : "build-only"}")
        selected_label = (members.length == 1) ? "1 member" : "#{members.length} members"
        stdout.puts("  selected: #{selected_label}")
        start_label = start_at.branch ? "#{start_at.member}@#{start_at.branch}" : start_at.member
        stdout.puts("  start: #{start_label}") if start_at.member
        stdout.puts("  members: #{members.map(&:name).join(", ")}")
        stdout.flush
        countdown_before_execution
      end

      def countdown_before_execution
        seconds = release_countdown_seconds
        return if seconds <= 0
        return unless stdout.respond_to?(:tty?) && stdout.tty?

        stdout.print("Continuing in #{seconds}...")
        stdout.flush
        seconds.downto(1) do |remaining|
          sleep 1
          next if remaining == 1

          stdout.print(" #{remaining - 1}...")
          stdout.flush
        end
        stdout.puts(" running...")
        stdout.flush
      end

      def release_countdown_seconds
        value = ENV.fetch("KETTLE_FAMILY_RELEASE_COUNTDOWN", "3")
        Integer(value, 10)
      rescue ArgumentError
        3
      end

      def release_secrets_provider(command:, config:, options:)
        return nil unless command == "release"

        Secrets::Factory.build(config: config, override_provider: options[:release_secrets_provider])
      end

      def branch_target_command?(command, config)
        return false if config.release_target_branches.empty?
        return false if command == "release-state"
        return false if command == "branch-lanes"
        return false unless WORKFLOW_COMMANDS.include?(command) || %w[bump bump-version install add-changelog].include?(command)

        !WORKFLOW_COMMANDS.include?(command)
      end

      def member_local_branch_target_command?(command, config, members)
        return false if !config.release_target_branches.empty?
        return false unless %w[bump bump-version install add-changelog].include?(command)

        members.any? { |member| member_release_config(member: member, config: config) }
      end

      def branch_target_command_results(command:, config:, members:, options:, start_at:)
        runner = CommandRunner.new(execute: options[:execute])
        selected_names = members.map(&:name)
        release_target_branches(command: command, config: config, start_at: start_at).each_with_object([]) do |branch, memo|
          memo << runner.call(
            member: family_member(config),
            phase: "release_checkout",
            command: ["git", "checkout", branch]
          )
          memo.last.branch = branch
          break memo unless memo.last.ok?

          branch_members = rediscovered_selected_members(config: config, selected_names: selected_names, command: command)
          branch_members = members if branch_members.empty?
          branch_results = command_results_for_current_branch(command: command, config: config, members: branch_members, options: options)
          branch_results.each { |result| result.branch = branch if result.respond_to?(:branch=) }
          memo.concat(branch_results)
          break memo unless memo.last&.ok?

          commit_changelog_entries(branch_members: branch_members, runner: runner, memo: memo) if command == "add-changelog"
          break memo unless memo.last&.ok?
        end
      end

      def member_local_branch_target_command_results(command:, config:, members:, options:, start_at:)
        runner = CommandRunner.new(execute: options[:execute])
        members.each_with_object([]) do |member, memo|
          member_config = member_release_config(member: member, config: config)
          unless member_config
            memo.concat(command_results_for_current_branch(command: command, config: config, members: [member], options: options))
            break memo unless memo.last&.ok?
            next
          end

          member_branch_targets(command: command, member: member, member_config: member_config, start_at: start_at).each do |branch|
            memo << runner.call(
              member: member,
              phase: "release_checkout",
              command: ["git", "checkout", branch]
            )
            memo.last.branch = branch
            break unless memo.last.ok?

            branch_members = rediscovered_selected_members(config: member_config, selected_names: [member.name], command: command)
            branch_members = [member] if branch_members.empty?
            branch_results = command_results_for_current_branch(command: command, config: member_config, members: branch_members, options: options)
            branch_results.each { |result| result.branch = branch if result.respond_to?(:branch=) }
            memo.concat(branch_results)
            break unless memo.last&.ok?
          end
          break memo unless memo.last&.ok?
        end
      end

      def rediscovered_selected_members(config:, selected_names:, command:)
        discovered = Discovery.new(config: config).members
        ordered = (command == "install") ? install_order(discovered, config) : Orderer.new(members: discovered, mode: config.order_mode, hints: config.order_hints).ordered
        ordered.select { |member| selected_names.include?(member.name) }
      rescue Error
        []
      end

      def family_member(config)
        Member.new(
          name: config.family_name,
          root: config.root,
          gemspec_path: nil,
          version_file: nil,
          version: nil,
          dependencies: []
        )
      end

      def parse_start_at(value)
        return StartAt.new(nil, nil) unless value

        member, branch = value.split("@", 2)
        raise Error, "--start-at requires MEMBER before @BRANCH" if member.to_s.empty?
        raise Error, "--start-at requires BRANCH after MEMBER@" if value.include?("@") && branch.to_s.empty?

        StartAt.new(member, branch)
      end

      def bump_version_results(config:, members:, options:, phase:)
        require_relative "version_bump"
        require_relative "release_waves"

        results = []
        completed_target_versions = {}
        shared_target_version = shared_bump_target_version(config: config, members: members, options: options)
        ReleaseWaves.new(members: members).waves.each do |wave|
          bump = VersionBump.new(
            members: wave,
            target_version: options[:target_version],
            from_version: options[:from_version],
            mode: bump_version_mode(options),
            phase: phase,
            shared_target_version: shared_target_version,
            dependency_target_versions: completed_target_versions
          )
          wave_results = bump.results
          results.concat(wave_results)
          break unless wave_results.all?(&:ok?)

          completed_target_versions.merge!(bump.target_versions)
        end
        return results if options[:check] || !options[:commit]
        return results unless results.all?(&:ok?)

        runner = CommandRunner.new(execute: options[:execute])
        members.each_with_object(results) do |member, memo|
          memo << runner.call(
            member: member,
            phase: "commit_version_bump",
            command: [
              "sh",
              "-lc",
              "if ! git diff --quiet -- '*.gemspec' 'lib/**/version.rb'; then git add -- '*.gemspec' 'lib/**/version.rb' && git commit -m '🔖 Bump gem version'; fi"
            ]
          )
          break memo unless memo.last.ok?
        end
      end

      def shared_bump_target_version(config:, members:, options:)
        return unless config.shared_changelog?
        return unless Kettle::Dev::VersionBump::BUMP_TYPES.include?(options[:target_version].to_s)

        versions = members.map { |member| Gem::Version.new(member.version.to_s) }.uniq
        current = versions.max
        return current.to_s if versions.length > 1

        Kettle::Dev::VersionBump.resolve_target_version(options[:target_version].to_s, current.to_s)
      end

      def add_changelog_results(members:, options:)
        section = options[:changelog_section].to_s
        entry = options[:changelog_entry].to_s
        raise Error, "add-changelog requires --section" if section.empty?
        raise Error, "add-changelog requires --entry" if entry.empty?

        runner = CommandRunner.new(execute: options[:execute])
        members.each_with_object([]) do |member, memo|
          memo << runner.call(
            member: member,
            phase: "add-changelog",
            command: [installed_executable("kettle-changelog"), "--add-unreleased-entry", "--section", section, "--entry", entry]
          )
          break memo unless memo.last.ok?
        end
      end

      def installed_executable(name)
        File.join(Gem.bindir, name)
      end

      def commit_changelog_entries(branch_members:, runner:, memo:)
        branch_members.each do |member|
          memo << runner.call(
            member: member,
            phase: "commit_changelog",
            command: [
              "sh",
              "-lc",
              "if ! git diff --quiet -- CHANGELOG.md; then git add CHANGELOG.md && git commit -m '📝 Add runtime compatibility changelog entry'; fi"
            ]
          )
          break unless memo.last.ok?
        end
      end

      def bump_version_mode(options)
        return :check if options[:check]
        return :execute if options[:execute]

        :dry_run
      end

      def branch_lane_results(config:, members:)
        BranchLaneAudit.new(config: config, members: members).results
      end

      def clean_unreleased_results(config:, members:, options:)
        UnreleasedGemCleanup.new(config: config, members: members, execute: options[:execute]).results
      end

      def reconcile_release_results(config:, members:, options:)
        ReleaseReconciler.new(config: config, members: members, execute: options[:execute]).results
      end

      def install_results(config:, members:, options:)
        LocalInstall.new(config: config, members: members, execute: options[:execute], jobs: options[:jobs]).results
      end

      def release_state_results(config:, members:, jobs: nil, event_handler: nil)
        ReleaseStateCheck.new(config: config, members: members, jobs: jobs).results(event_handler: event_handler)
      end

      def release_state_event_tape(command:, config:, options:)
        return unless command == "release-state"

        tape = ReleaseStateEventTape.new(root: config.root, stream: options[:events] ? stdout : nil)
        stderr.puts("release state event tapes: #{tape.directory}") unless options[:events]
        tape
      end

      def release_mode(command:, options:)
        return unless command == "release"

        options[:publish] ? "publish" : "build-only"
      end

      def release_target_branches(command:, config:, start_at:)
        branch_targets = BranchTargetConfig.branch_targets_for(command, config.release_target_branches)
        return branch_targets if branch_targets.empty?

        slice_branch_targets(branch_targets, start_at.branch)
      end

      def member_release_target_branches(command:, members:, config:, start_at:)
        members.each_with_object({}) do |member, memo|
          member_config = member_release_config(member: member, config: config)
          memo[member.name] = member_branch_targets(command: command, member: member, member_config: member_config, start_at: start_at) if member_config
        end
      end

      def member_branch_targets(command:, member:, member_config:, start_at:)
        branch_targets = BranchTargetConfig.branch_targets_for(command, member_config.release_target_branches)
        return branch_targets unless start_at.branch && start_at.member == member.name

        slice_branch_targets(branch_targets, start_at.branch)
      end

      def slice_branch_targets(branch_targets, start_branch)
        return branch_targets unless start_branch

        index = branch_targets.index(start_branch)
        raise Error, "unknown branch target #{start_branch.inspect}" unless index

        branch_targets.drop(index)
      end

      def member_release_config(member:, config:)
        BranchTargetConfig.member_release_config(member: member, config: config)
      end

      def install_order(members, config)
        by_name = members.to_h { |member| [member.name, member] }
        hinted = config.order_hints.filter_map { |name| by_name[name] }
        hinted_names = hinted.map(&:name)
        hinted + members.reject { |member| hinted_names.include?(member.name) }.sort_by(&:name)
      end

      def write_report(report, options)
        return unless options[:report]

        path = File.expand_path(options[:report], options[:root])
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, report.to_json)
      end
    end
  end
end
