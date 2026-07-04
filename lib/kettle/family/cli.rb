# frozen_string_literal: true

require "command_kit"
require "command_kit/commands"
require "fileutils"
require "optparse"

module Kettle
  module Family
    class CLI < CommandKit::Command
      include CommandKit::Commands

      COMMANDS = %w[discover plan report metadata check test lint docs template gha-sha-pins bup bupb bex install bump-version add-changelog release push pull up branch-lanes release-state].freeze
      WORKFLOW_COMMANDS = %w[check test lint docs template gha-sha-pins bup bupb bex release push pull up].freeze

      command_name "kettle-family"
      usage "[options] COMMAND [ARGS...]"
      description "Coordinate related Ruby gems as one family."

      option :root, value: {type: String, usage: "PATH"}, desc: "Workspace or family root"
      option :config, value: {type: String, usage: "PATH"}, desc: "Family config path"
      option :json, desc: "Print JSON report to stdout"
      option :report, value: {type: String, usage: "PATH"}, desc: "Write JSON report to PATH"

      def self.call(argv, out: $stdout, err: $stderr)
        main(argv, stdout: out, stderr: err)
      end

      module SharedOptions
        def self.included(base)
          base.option :root, value: {type: String, usage: "PATH"}, desc: "Workspace or family root"
          base.option :config, value: {type: String, usage: "PATH"}, desc: "Family config path"
          base.option :json, desc: "Print JSON report to stdout"
          base.option :report, value: {type: String, usage: "PATH"}, desc: "Write JSON report to PATH"
        end
      end

      module SelectionOptions
        def self.included(base)
          base.option :only, value: {type: String, usage: "MEMBERS"}, desc: "Select comma-separated members"
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
        end
      end

      module WorkflowOptions
        def self.included(base)
          base.option :debug, desc: "Preserve debug environment for workflow commands"
          base.option :jobs, value: {type: Integer, usage: "N"}, desc: "Parallel jobs for supported executed workflows"
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
            report: options[:report],
            execute: truthy_option?(:execute),
            debug: truthy_option?(:debug),
            jobs: options[:jobs],
            workflow_env: workflow_env,
            changelog_section: nil,
            changelog_entry: nil,
            check: truthy_option?(:check),
            from_version: nil,
            gha_sha_pins_upgrade: "patch",
            publish: false,
            release_start_step: nil,
            release_skip_steps: nil,
            release_local_ci: false,
            release_continue_ci_failures: false,
            accept: true,
            tag: false,
            push: false,
            commit: !options.key?(:commit) || options[:commit],
            allow_dirty: truthy_option?(:allow_dirty),
            target_version: nil,
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
        command_name "release-state"
        usage "[options]"
        description "Report changelog release state for family members."

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
        description "Plan or execute kettle-gha-sha-pins per member."

        option :check, desc: "Check whether SHA pins would need edits"
        option :upgrade, value: {type: String, usage: "LEVEL"}, desc: "SHA pin upgrade strategy: major, minor, patch" do |value|
          options[:upgrade] = parse_gha_sha_pins_upgrade(value)
        end

        def run(*args)
          unexpected_arguments!(args)
          run_family("gha-sha-pins", gha_sha_pins_upgrade: options[:upgrade] || "patch")
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

      class BumpVersion < BaseCommand
        include ExecutionOptions
        include CommitOptions

        command_name "bump-version"
        usage "[options] VERSION|major|minor|patch|pre"
        description "Check, plan, or execute family version alignment."
        argument :target_version, required: false, usage: "VERSION|major|minor|patch|pre", desc: "Version or bump target"

        option :check, desc: "Check whether version bumps would need edits"
        option :from, value: {type: String, usage: "VERSION"}, desc: "Require selected members to currently match VERSION"

        def run(target_version = nil)
          raise Error, "bump-version requires VERSION, major, minor, patch, or pre" unless target_version

          run_family("bump-version", target_version: target_version, from_version: options[:from])
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

      class Up < WorkflowCommand
        command_name "up"
        usage "[options]"
        description "Plan or execute git pull --rebase then git push per member."
      end

      command Discover
      command Plan
      command "report", ReportCommand
      command Metadata
      command Check
      command Test
      command Lint
      command Docs
      command Template
      command GhaShaPins
      command Bup
      command Bupb
      command Bex
      command Install
      command BumpVersion
      command AddChangelog
      command Release
      command Push
      command Pull
      command Up
      command BranchLanes
      command ReleaseState

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
        stdout.puts(options[:json] ? report.to_json : report.to_text)
        report.success? ? 0 : 1
      rescue Error, OptionParser::ParseError => error
        stderr.puts("kettle-family: #{error.message}")
        1
      end

      private

      def build_report(command, options)
        config = Config.load(root: options[:root], path: options[:config])
        start_at = parse_start_at(options[:start_at])
        members = Discovery.new(config: config).members
        ordered = if command == "install"
          install_order(members, config)
        elsif %w[metadata release-state].include?(command)
          members.sort_by(&:name)
        else
          Orderer.new(members: members, mode: config.order_mode, hints: config.order_hints).ordered
        end
        selected = Selection.new(members: ordered).apply(only: options[:only], exclude: options[:exclude], start_at: start_at.member)
        result_members = selected
        results = command_results(command: command, config: config, members: result_members, options: options, start_at: start_at)
        Report.new(
          family_name: config.family_name,
          family_mode: config.family_mode,
          order_mode: config.order_mode,
          members: ordered,
          selected_members: selected,
          config_path: config.path,
          branch_lanes: config.branch_lanes,
          release_target_branches: release_target_branches(command: command, config: config, start_at: start_at),
          member_release_target_branches: member_release_target_branches(command: command, members: selected, config: config, start_at: start_at),
          release_mode: release_mode(command: command, options: options),
          command: command,
          results: results
        )
      end

      StartAt = Struct.new(:member, :branch)

      def command_results(command:, config:, members:, options:, start_at:)
        return branch_target_command_results(command: command, config: config, members: members, options: options, start_at: start_at) if branch_target_command?(command, config)
        return member_local_branch_target_command_results(command: command, config: config, members: members, options: options, start_at: start_at) if member_local_branch_target_command?(command, config, members)

        command_results_for_current_branch(command: command, config: config, members: members, options: options, start_at: start_at)
      end

      def command_results_for_current_branch(command:, config:, members:, options:, start_at: StartAt.new(nil, nil))
        return bump_version_results(members: members, options: options) if command == "bump-version"
        return add_changelog_results(members: members, options: options) if command == "add-changelog"
        return branch_lane_results(config: config, members: members) if command == "branch-lanes"
        return release_state_results(config: config, members: members) if command == "release-state"
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
          publish: options[:publish],
          push: options[:push],
          tag: options[:tag],
          start_step: options[:release_start_step],
          skip_steps: options[:release_skip_steps],
          local_ci: options[:release_local_ci],
          continue_ci_failures: options[:release_continue_ci_failures],
          auto_dependency_floors: options[:release_auto_dependency_floors],
          gha_sha_pins_upgrade: options[:gha_sha_pins_upgrade],
          gha_sha_pins_check: options[:check],
          env_overrides: options[:workflow_env],
          debug: options[:debug],
          jobs: options[:jobs],
          progress_io: progress_io(command, options),
          bup_args: options[:bup_args],
          bex_args: options[:bex_args],
          start_member: start_at.member,
          start_branch: start_at.branch
        ).results
      end

      def progress_io(command, options)
        return nil unless command == "template"
        return nil unless options[:execute]
        return nil if options[:json]

        stdout
      end

      def branch_target_command?(command, config)
        return false if config.release_target_branches.empty?
        return false if command == "release-state"
        return false if command == "branch-lanes"
        return false unless WORKFLOW_COMMANDS.include?(command) || %w[bump-version install add-changelog].include?(command)

        !WORKFLOW_COMMANDS.include?(command)
      end

      def member_local_branch_target_command?(command, config, members)
        return false if !config.release_target_branches.empty?
        return false unless %w[bump-version install add-changelog].include?(command)

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

      def bump_version_results(members:, options:)
        results = VersionBump.new(
          members: members,
          target_version: options[:target_version],
          from_version: options[:from_version],
          mode: bump_version_mode(options)
        ).results
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

      def install_results(config:, members:, options:)
        LocalInstall.new(config: config, members: members, execute: options[:execute], jobs: options[:jobs]).results
      end

      def release_state_results(config:, members:)
        ReleaseStateCheck.new(config: config, members: members).results
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
