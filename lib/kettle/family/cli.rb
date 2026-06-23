# frozen_string_literal: true

require "fileutils"
require "optparse"

module Kettle
  module Family
    class CLI
      COMMANDS = %w[discover plan report metadata check test lint docs template install bump-version add-changelog release branch-lanes release-state].freeze
      WORKFLOW_COMMANDS = %w[check test lint docs template release].freeze

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
        raise Error, "bump-version requires VERSION" if command == "bump-version" && !target_version

        options = parse_options
        options[:target_version] = target_version
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
          Usage: kettle-family COMMAND [options]

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
              install         Build and install selected local family gems
              bump-version    Check, plan, or execute family version alignment
              add-changelog   Add an entry to an existing Unreleased changelog section
              release         Plan or execute release build/publish phases
              branch-lanes    Audit configured branch lane release mappings
              release-state   Report changelog release state for family members

          Options:
              --root PATH      Workspace or family root (default: current directory)
              --config PATH    Family config path
              --only MEMBER    Select exactly one member
              --start-at NAME  Select from member through the end of order
              --json           Print JSON report to stdout
              --report PATH    Write JSON report to PATH
              --execute        Execute external workflow commands
              --dry-run        Plan external workflow commands without running them (default)
              --env KEY=VALUE  Override an environment variable for each member workflow command
              --section NAME   Changelog section for add-changelog
              --entry TEXT     Changelog entry for add-changelog
              --check          Check whether bump-version would need edits
              --from VERSION   Require selected members to currently match VERSION
              --publish        Use publish release command instead of build command
              --build-only      Use build release command (default)
              --start-step N    Pass start_step=N through to kettle-release commands
              --local-ci        Pass --local-ci through to kettle-release commands
              --continue-ci-failures
                               Set K_RELEASE_CI_CONTINUE=true for release commands
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
          workflow_env: {},
          changelog_section: nil,
          changelog_entry: nil,
          check: false,
          from_version: nil,
          publish: false,
          release_start_step: nil,
          release_local_ci: false,
          release_continue_ci_failures: false,
          tag: false,
          push: false,
          commit: true,
          allow_dirty: false
        }
        OptionParser.new do |parser|
          parser.on("--root PATH") { |value| options[:root] = value }
          parser.on("--config PATH") { |value| options[:config] = value }
          parser.on("--only MEMBER") { |value| options[:only] = value }
          parser.on("--start-at MEMBER") { |value| options[:start_at] = value }
          parser.on("--json") { options[:json] = true }
          parser.on("--report PATH") { |value| options[:report] = value }
          parser.on("--execute") { options[:execute] = true }
          parser.on("--dry-run") { options[:execute] = false }
          parser.on("--env KEY=VALUE") { |value| parse_env_override(value, options[:workflow_env]) }
          parser.on("--section NAME") { |value| options[:changelog_section] = value }
          parser.on("--entry TEXT") { |value| options[:changelog_entry] = value }
          parser.on("--check") { options[:check] = true }
          parser.on("--from VERSION") { |value| options[:from_version] = value }
          parser.on("--publish") { options[:publish] = true }
          parser.on("--build-only") { options[:publish] = false }
          parser.on("--start-step N", Integer) { |value| options[:release_start_step] = value }
          parser.on("--local-ci") { options[:release_local_ci] = true }
          parser.on("--continue-ci-failures") { options[:release_continue_ci_failures] = true }
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
        members = Discovery.new(config: config).members
        ordered = if command == "install"
          install_order(members, config)
        elsif %w[metadata release-state].include?(command)
          members.sort_by(&:name)
        else
          Orderer.new(members: members, mode: config.order_mode, hints: config.order_hints).ordered
        end
        selected = Selection.new(members: ordered).apply(only: options[:only], start_at: options[:start_at])
        result_members = if command == "branch-lanes"
          ordered
        else
          selected
        end
        results = command_results(command: command, config: config, members: result_members, options: options)
        Report.new(
          family_name: config.family_name,
          family_mode: config.family_mode,
          order_mode: config.order_mode,
          members: ordered,
          selected_members: selected,
          config_path: config.path,
          branch_lanes: config.branch_lanes,
          release_target_branches: config.release_target_branches,
          member_release_target_branches: member_release_target_branches(members: selected, config: config),
          release_mode: release_mode(command: command, options: options),
          command: command,
          results: results
        )
      end

      def command_results(command:, config:, members:, options:)
        return branch_target_command_results(command: command, config: config, members: members, options: options) if branch_target_command?(command, config)

        command_results_for_current_branch(command: command, config: config, members: members, options: options)
      end

      def command_results_for_current_branch(command:, config:, members:, options:)
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
          commit: options[:commit],
          allow_dirty: options[:allow_dirty],
          publish: options[:publish],
          push: options[:push],
          tag: options[:tag],
          start_step: options[:release_start_step],
          local_ci: options[:release_local_ci],
          continue_ci_failures: options[:release_continue_ci_failures],
          env_overrides: options[:workflow_env]
        ).results
      end

      def branch_target_command?(command, config)
        return false if config.release_target_branches.empty?
        return false if command == "release-state"
        return false if command == "branch-lanes"
        return false unless WORKFLOW_COMMANDS.include?(command) || %w[bump-version install add-changelog].include?(command)

        !WORKFLOW_COMMANDS.include?(command)
      end

      def branch_target_command_results(command:, config:, members:, options:)
        runner = CommandRunner.new(execute: options[:execute])
        selected_names = members.map(&:name)
        config.release_target_branches.each_with_object([]) do |branch, memo|
          memo << runner.call(
            member: family_member(config),
            phase: "release_checkout",
            command: ["git", "checkout", branch]
          )
          break memo unless memo.last.ok?

          branch_members = rediscovered_selected_members(config: config, selected_names: selected_names, command: command)
          branch_members = members if branch_members.empty?
          memo.concat(command_results_for_current_branch(command: command, config: config, members: branch_members, options: options))
          break memo unless memo.last&.ok?

          commit_changelog_entries(branch_members: branch_members, runner: runner, memo: memo) if command == "add-changelog"
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

      def bump_version_results(members:, options:)
        VersionBump.new(
          members: members,
          target_version: options[:target_version],
          from_version: options[:from_version],
          mode: bump_version_mode(options)
        ).results
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
        LocalInstall.new(config: config, members: members, execute: options[:execute]).results
      end

      def release_state_results(config:, members:)
        ReleaseStateCheck.new(config: config, members: members).results
      end

      def release_mode(command:, options:)
        return unless command == "release"

        options[:publish] ? "publish" : "build-only"
      end

      def member_release_target_branches(members:, config:)
        members.each_with_object({}) do |member, memo|
          member_config = member_local_release_config(member: member, config: config)
          memo[member.name] = member_config.release_target_branches if member_config
        end
      end

      def member_local_release_config(member:, config:)
        member_config = Config.load(root: member.root)
        return unless member_config.path
        return if config.path && File.realpath(member_config.path) == File.realpath(config.path)
        return if member_config.release_target_branches.empty?

        member_config
      rescue Errno::ENOENT
        nil
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
