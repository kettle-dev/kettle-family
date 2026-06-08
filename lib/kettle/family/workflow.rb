# frozen_string_literal: true

module Kettle
  module Family
    class Workflow
      DEFAULT_COMMANDS = {
        "test" => "bundle exec kettle-test",
        "lint" => "bundle exec rake rubocop_gradual",
        "docs" => "bundle exec rake yard"
      }.freeze

      def initialize(command:, config:, members:, execute: false)
        @command = command
        @config = config
        @members = members
        @execute = execute
      end

      def results
        return check_results if command == "check"

        runner = CommandRunner.new(execute: execute)
        command_text = command_for(command)
        members.each_with_object([]) do |member, memo|
          result = runner.call(member: member, phase: command, command: command_text)
          memo << result
          break memo unless result.ok?
        end
      end

      private

      attr_reader :command, :config, :members, :execute

      def check_results
        members.map { |member| ReadinessCheck.call(member: member) }
      end

      def command_for(name)
        configured = config.command_for(name)
        configured || DEFAULT_COMMANDS.fetch(name)
      end
    end
  end
end
