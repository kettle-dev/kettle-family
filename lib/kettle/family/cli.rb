# frozen_string_literal: true

require "fileutils"
require "optparse"

module Kettle
  module Family
    class CLI
      COMMANDS = %w[discover plan report metadata check test lint docs template gha-sha-pins bup bupb install bump-version add-changelog release push pull up branch-lanes release-state].freeze
      WORKFLOW_COMMANDS = %w[check test lint docs template gha-sha-pins bup bupb release push pull up].freeze

      def self.call(argv, out: $stdout, err: $stderr)
        new(argv, out: out, err: err).call
      end

      def initialize(argv, out:, err:)
        @argv = argv.dup
        @out = out
        @err = err
      end

      def call
        command = argv.shift || "help"
        return help if command == "help" || command == "--help" || command == "-h"

        raise Error, "unknown command #{command.inspect}" unless COMMANDS.include?(command)

        target_version = argv.shift if command == "bump-version"
        raise Error, "bump-version requires VERSION, major, minor, patch, or pre" if command == "bump-version" && !target_version
        bup_args = parse_bup_args(command)

        options = parse_options
        options[:target_version] = target_version
        options[:bup_args] = bup_args
        return help if options.delete(:help)

        report = build_report(command, options)
        write_report(report, options)
        out.puts(options[:json] ? report.to_json : report.to_text)
        report.success? ? 0 : 1
      rescue Error, OptionParser::ParseError => error
        err.puts("kettle-family: #{error.message}")
        1
      end

      private

      attr_reader :argv, :out, :err

      def help
        out.puts(<<~HELP)
          kettle-family: #{Kettle::Family::VERSION}

          Usage: kettle-family COMMAND [options]
                 kettle-family bump-version VERSION|major|minor|patch|pre [options]
                 kettle-family bup [GEM] [options]

          Commands:
              discover        Discover family members and print selected order
              plan            Alias for discover while execution workflows are built
              report          Print family discovery and configuration report
              metadata        Print version, Ruby floor, license, and author metadata
              check           Run internal read-only readiness checks
              test            Plan or execute configured test command per member
              lint            Plan or execute configured lint command per member
              docs            Plan or execute configured docs command per member
              template        Plan or execute kettle-jem templating per member
              gha-sha-pins    Plan or execute kettle-gha-sha-pins per member
              bup             Plan or execute bundle update --all, or bundle update GEM
              bupb            Plan or execute bundle update --bundler
              install         Build and install selected local family gems
              bump-version    Check, plan, or execute family version alignment
              add-changelog   Add an entry to an existing Unreleased changelog section
              release         Plan or execute release build/publish phases
              push            Plan or execute git push per member
              pull            Plan or execute git pull --rebase per member
              up              Plan or execute git pull --rebase then git push per member
              release-state   Report changelog release state for family members

          Options:
              --root PATH      Workspace or family root (default: current directory)
              --config PATH    Family config path
              --only MEMBER    Select exactly one member
              --start-at NAME  Select from member through the end of order; use MEMBER@BRANCH for branch stacks
              --json           Print JSON report to stdout
              --report PATH    Write JSON report to PATH
              --execute        Execute external workflow commands
              --dry-run        Plan external workflow commands without running them (default)
              --debug          Preserve debug environment for workflow commands
              --jobs N         Parallel jobs for executed family templating, release, or install
              --env KEY=VALUE  Override an environment variable for each member workflow command
              --section NAME   Changelog section for add-changelog
              --entry TEXT     Changelog entry for add-changelog
              --check          Check whether bump-version or gha-sha-pins would need edits
              --from VERSION   Require selected members to currently match VERSION
              --upgrade LEVEL  GitHub Actions SHA pin upgrade strategy: major, minor, patch
              --publish        Use publish release command instead of build command
              --build-only      Use build release command (default)
              --start-step N    Pass start_step=N through to kettle-release commands
              --skip-steps LIST Pass skip_steps=LIST through to kettle-release commands
              --local-ci        Pass --local-ci through to kettle-release commands
              --continue-ci-failures
                               Set K_RELEASE_CI_CONTINUE=true for release commands
              --accept         Answer yes to confirmation prompts in interactive commands (default)
              --no-accept      Wait for user input at confirmation prompts
              --tag            Add release tag phase
              --push           Add release push phase
              --commit         Allow each templated member's kettle-jem run to commit (default)
              --no-commit      Pass --skip-commit to each templated member's kettle-jem run
              --allow-dirty    Reserved for compatibility; member repos manage their own commit safety
              --help           Print this help
        HELP
        0
      end

      def parse_options
        options = {
          root: Dir.pwd,
          config: nil,
          only: nil,
          start_at: nil,
          json: false,
          report: nil,
          execute: false,
          debug: false,
          jobs: nil,
          workflow_env: {},
          changelog_section: nil,
          changelog_entry: nil,
          check: false,
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
          commit: true,
          allow_dirty: false
        }
        OptionParser.new do |parser|
          parser.on("--root PATH") { |value| options[:root] = value }
          parser.on("--config PATH") { |value| options[:config] = value }
          parser.on("--only MEMBER") { |value| options[:only] = value }
          parser.on("--start-at MEMBER[@BRANCH]") { |value| options[:start_at] = value }
          parser.on("--json") { options[:json] = true }
          parser.on("--report PATH") { |value| options[:report] = value }
          parser.on("--execute") { options[:execute] = true }
          parser.on("--dry-run") { options[:execute] = false }
          parser.on("--debug") { options[:debug] = true }
          parser.on("--jobs N", Integer) { |value| options[:jobs] = value }
          parser.on("--env KEY=VALUE") { |value| parse_env_override(value, options[:workflow_env]) }
          parser.on("--section NAME") { |value| options[:changelog_section] = value }
          parser.on("--entry TEXT") { |value| options[:changelog_entry] = value }
          parser.on("--check") { options[:check] = true }
          parser.on("--from VERSION") { |value| options[:from_version] = value }
          parser.on("--upgrade LEVEL") { |value| options[:gha_sha_pins_upgrade] = parse_gha_sha_pins_upgrade(value) }
          parser.on("--publish") { options[:publish] = true }
          parser.on("--build-only") { options[:publish] = false }
          parser.on("--start-step N", Integer) { |value| options[:release_start_step] = value }
          parser.on("--skip-steps LIST") { |value| options[:release_skip_steps] = value }
          parser.on("--local-ci") { options[:release_local_ci] = true }
          parser.on("--continue-ci-failures") { options[:release_continue_ci_failures] = true }
          parser.on("--accept") { options[:accept] = true }
          parser.on("--no-accept") { options[:accept] = false }
          parser.on("--tag") { options[:tag] = true }
          parser.on("--push") { options[:push] = true }
          parser.on("--commit") { options[:commit] = true }
          parser.on("--no-commit") { options[:commit] = false }
          parser.on("--allow-dirty") { options[:allow_dirty] = true }
          parser.on("--help") { options[:help] = true }
        end.parse!(argv)
        raise OptionParser::InvalidArgument, "unexpected argument(s): #{argv.join(" ")}" unless argv.empty?

        options
      end

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
        selected = Selection.new(members: ordered).apply(only: options[:only], start_at: start_at.member)
        result_members = if command == "branch-lanes"
          ordered
        else
          selected
        end
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
          gha_sha_pins_upgrade: options[:gha_sha_pins_upgrade],
          gha_sha_pins_check: options[:check],
          env_overrides: options[:workflow_env],
          debug: options[:debug],
          jobs: options[:jobs],
          progress_io: progress_io(command, options),
          bup_args: options[:bup_args],
          start_member: start_at.member,
          start_branch: start_at.branch
        ).results
      end

      def parse_bup_args(command)
        return [] unless command == "bup"

        args = []
        args << argv.shift while argv.first && !argv.first.start_with?("-")
        args
      end

      def progress_io(command, options)
        return nil unless command == "template"
        return nil unless options[:execute]
        return nil if options[:json]

        out
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

        members.any? { |member| member_local_release_config(member: member, config: config) }
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
          member_config = member_local_release_config(member: member, config: config)
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
          member_config = member_local_release_config(member: member, config: config)
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

      def member_local_release_config(member:, config:)
        BranchTargetConfig.member_local_release_config(member: member, config: config)
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
