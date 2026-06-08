# frozen_string_literal: true

require "fileutils"
require "optparse"

module Kettle
  module Family
    class CLI
      COMMANDS = %w[discover plan check test lint docs template bump-version release].freeze
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
              check           Run internal read-only readiness checks
              test            Plan or execute configured test command per member
              lint            Plan or execute configured lint command per member
              docs            Plan or execute configured docs command per member
              template        Plan or execute kettle-jem templating per member
              bump-version    Check, plan, or execute family version alignment
              release         Plan or execute release build/publish phases

          Options:
              --root PATH      Workspace or family root (default: current directory)
              --config PATH    Family config path
              --only MEMBER    Select exactly one member
              --start-at NAME  Select from member through the end of order
              --json           Print JSON report to stdout
              --report PATH    Write JSON report to PATH
              --execute        Execute external workflow commands
              --dry-run        Plan external workflow commands without running them (default)
              --check          Check whether bump-version would need edits
              --from VERSION   Require selected members to currently match VERSION
              --publish        Use publish release command instead of build command
              --build-only      Use build release command (default)
              --tag            Add release tag phase
              --push           Add release push phase
              --commit         Add final family-level git commit phase for template
              --no-commit      Disable final family-level git commit phase (default)
              --allow-dirty    Allow template --commit when the family worktree starts dirty
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
          check: false,
          from_version: nil,
          publish: false,
          tag: false,
          push: false,
          commit: false,
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
          parser.on("--check") { options[:check] = true }
          parser.on("--from VERSION") { |value| options[:from_version] = value }
          parser.on("--publish") { options[:publish] = true }
          parser.on("--build-only") { options[:publish] = false }
          parser.on("--tag") { options[:tag] = true }
          parser.on("--push") { options[:push] = true }
          parser.on("--commit") { options[:commit] = true }
          parser.on("--no-commit") { options[:commit] = false }
          parser.on("--allow-dirty") { options[:allow_dirty] = true }
          parser.on("--help") { options[:help] = true }
        end.parse!(argv)
        options
      end

      def build_report(command, options)
        config = Config.load(root: options[:root], path: options[:config])
        members = Discovery.new(config: config).members
        ordered = Orderer.new(members: members, mode: config.order_mode, hints: config.order_hints).ordered
        selected = Selection.new(members: ordered).apply(only: options[:only], start_at: options[:start_at])
        results = command_results(command: command, config: config, members: selected, options: options)
        Report.new(
          family_name: config.family_name,
          order_mode: config.order_mode,
          members: ordered,
          selected_members: selected,
          config_path: config.path,
          command: command,
          results: results
        )
      end

      def command_results(command:, config:, members:, options:)
        return bump_version_results(members: members, options: options) if command == "bump-version"
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
          tag: options[:tag]
        ).results
      end

      def bump_version_results(members:, options:)
        VersionBump.new(
          members: members,
          target_version: options[:target_version],
          from_version: options[:from_version],
          mode: bump_version_mode(options)
        ).results
      end

      def bump_version_mode(options)
        return :check if options[:check]
        return :execute if options[:execute]

        :dry_run
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
