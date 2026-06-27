# frozen_string_literal: true

module Kettle
  module Family
    class ReadinessCheck
      REQUIRED_FILES = %w[Gemfile Rakefile README.md CHANGELOG.md LICENSE.md].freeze
      REQUIRED_BINS = %w[bin/rake bin/rspec].freeze

      def self.call(member:, config: nil, allowed_local_path_roots: [])
        new(member: member, config: config, allowed_local_path_roots: allowed_local_path_roots).call
      end

      def initialize(member:, config: nil, allowed_local_path_roots: [])
        @member = member
        @config = config
        @allowed_local_path_roots = allowed_local_path_roots.filter_map { |path| normalized_path(path) }
      end

      def call
        diagnostics = []
        diagnostics.concat(missing_required_files)
        diagnostics.concat(missing_required_bins)
        diagnostics.concat(missing_root_required_files)
        diagnostics.concat(missing_member_required_dirs)
        diagnostics.concat(forbidden_tracked_member_dirs)
        diagnostics.concat(missing_readme_links)
        diagnostics.concat(local_path_lockfile_entries)
        result(diagnostics)
      end

      private

      attr_reader :member, :config, :allowed_local_path_roots

      def missing_required_files
        required_files.filter_map do |path|
          next if File.file?(File.join(member.root, path))

          "missing required file #{path}"
        end
      end

      def missing_required_bins
        required_bins.filter_map do |path|
          full_path = File.join(member.root, path)
          next if File.file?(full_path) && File.executable?(full_path)

          "missing executable binstub #{path}"
        end
      end

      def missing_root_required_files
        return [] unless config

        config.check_root_required_files.filter_map do |path|
          next if File.file?(File.join(config.root, path))

          "missing root required file #{path}"
        end
      end

      def missing_member_required_dirs
        return [] unless config

        config.check_member_required_dirs.filter_map do |path|
          next if Dir.exist?(File.join(member.root, path))

          "missing required directory #{path}"
        end
      end

      def forbidden_tracked_member_dirs
        return [] unless config
        return [] if config.check_forbidden_tracked_member_dirs_except.include?(member.name)

        config.check_forbidden_tracked_member_dirs.filter_map do |path|
          full_path = File.join(member.root, path)
          next unless Dir.exist?(full_path) && tracked_path?(full_path)

          "forbidden tracked directory #{path}"
        end
      end

      def missing_readme_links
        return [] unless config

        readme = File.join(member.root, "README.md")
        return [] unless File.file?(readme)

        content = File.read(readme)
        config.check_readme_links.filter_map do |label, target|
          next if content.include?("/#{target}") || content.include?("../../#{target}") || content.include?("../#{target}")

          "README.md missing link to root #{label}"
        end
      end

      def local_path_lockfile_entries
        lockfile = File.join(member.root, "Gemfile.lock")
        return [] unless File.file?(lockfile)

        File.readlines(lockfile).filter_map.with_index(1) do |line, index|
          next unless line.start_with?("  remote: /", "  remote: ./", "  remote: ../")
          next if allowed_local_path?(line)

          "release lockfile has local path remote at Gemfile.lock:#{index}"
        end
      end

      def allowed_local_path?(line)
        remote = line.split("remote:", 2).last.to_s.strip
        remote_path = normalized_path(remote, base: member.root)
        return false unless remote_path

        allowed_local_path_roots.any? { |root| remote_path == root || remote_path.start_with?("#{root}/") }
      end

      def normalized_path(path, base: nil)
        text = path.to_s
        return nil if text.empty? || text.casecmp("false").zero?

        expanded = File.expand_path(text, base)
        File.realpath(expanded)
      rescue Errno::ENOENT
        expanded
      end

      def required_files
        config ? config.check_required_files : REQUIRED_FILES
      end

      def required_bins
        config ? config.check_required_bins : REQUIRED_BINS
      end

      def tracked_path?(path)
        return false unless config

        relative = path.delete_prefix("#{config.root}/")
        system("git", "-C", config.root, "ls-files", "--error-unmatch", relative, out: File::NULL, err: File::NULL)
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
