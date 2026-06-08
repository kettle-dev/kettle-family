# frozen_string_literal: true

module Kettle
  module Family
    class ReadinessCheck
      REQUIRED_FILES = %w[Gemfile Rakefile README.md CHANGELOG.md LICENSE.md].freeze
      REQUIRED_BINS = %w[bin/rake bin/rspec].freeze

      def self.call(member:)
        new(member: member).call
      end

      def initialize(member:)
        @member = member
      end

      def call
        diagnostics = []
        diagnostics.concat(missing_required_files)
        diagnostics.concat(missing_required_bins)
        diagnostics.concat(local_path_lockfile_entries)
        result(diagnostics)
      end

      private

      attr_reader :member

      def missing_required_files
        REQUIRED_FILES.filter_map do |path|
          next if File.file?(File.join(member.root, path))

          "missing required file #{path}"
        end
      end

      def missing_required_bins
        REQUIRED_BINS.filter_map do |path|
          full_path = File.join(member.root, path)
          next if File.file?(full_path) && File.executable?(full_path)

          "missing executable binstub #{path}"
        end
      end

      def local_path_lockfile_entries
        lockfile = File.join(member.root, "Gemfile.lock")
        return [] unless File.file?(lockfile)

        File.readlines(lockfile).filter_map.with_index(1) do |line, index|
          next unless line.start_with?("  remote: /", "  remote: ./", "  remote: ../")

          "release lockfile has local path remote at Gemfile.lock:#{index}"
        end
      end

      def result(diagnostics)
        CommandResult.new(
          member_name: member.name,
          phase: "check",
          command: ["internal", "readiness"],
          workdir: member.root,
          status: diagnostics.empty? ? 0 : 1,
          success: diagnostics.empty?,
          stdout: diagnostics.join("\n"),
          stderr: "",
          elapsed_seconds: 0.0,
          skipped: false,
          reason: diagnostics.empty? ? nil : "readiness check failed"
        )
      end
    end
  end
end
