# frozen_string_literal: true

require "fileutils"
require "optparse"

module Kettle
  module Family
    class CLI
      COMMANDS = %w[discover plan check test lint docs].freeze
      WORKFLOW_COMMANDS = %w[check test lint docs].freeze

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

        options = parse_options
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

          Options:
              --root PATH      Workspace or family root (default: current directory)
              --config PATH    Family config path
              --only MEMBER    Select exactly one member
              --start-at NAME  Select from member through the end of order
              --json           Print JSON report to stdout
              --report PATH    Write JSON report to PATH
              --execute        Execute external workflow commands
              --dry-run        Plan external workflow commands without running them (default)
              --help           Print this help
        HELP
        0
      end

      def parse_options
        options = {root: Dir.pwd, config: nil, only: nil, start_at: nil, json: false, report: nil, execute: false}
        OptionParser.new do |parser|
          parser.on("--root PATH") { |value| options[:root] = value }
          parser.on("--config PATH") { |value| options[:config] = value }
          parser.on("--only MEMBER") { |value| options[:only] = value }
          parser.on("--start-at MEMBER") { |value| options[:start_at] = value }
          parser.on("--json") { options[:json] = true }
          parser.on("--report PATH") { |value| options[:report] = value }
          parser.on("--execute") { options[:execute] = true }
          parser.on("--dry-run") { options[:execute] = false }
          parser.on("--help") { options[:help] = true }
        end.parse!(argv)
        options
      end

      def build_report(command, options)
        config = Config.load(root: options[:root], path: options[:config])
        members = Discovery.new(config: config).members
        ordered = Orderer.new(members: members, mode: config.order_mode, hints: config.order_hints).ordered
        selected = Selection.new(members: ordered).apply(only: options[:only], start_at: options[:start_at])
        results = workflow_results(command: command, config: config, members: selected, execute: options[:execute])
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

      def workflow_results(command:, config:, members:, execute:)
        return [] unless WORKFLOW_COMMANDS.include?(command)

        Workflow.new(command: command, config: config, members: members, execute: execute).results
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
