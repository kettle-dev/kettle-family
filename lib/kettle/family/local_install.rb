# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "time"

module Kettle
  module Family
    class LocalInstall
      def initialize(config:, members:, execute: false)
        @config = config
        @members = members
        @execute = execute
      end

      def results
        results = install_members.each_with_object([]) do |member, memo|
          memo << install_member(member)
          break memo unless memo.last.ok?
        end
        write_local_install_marker if execute && results.all?(&:ok?)
        results
      end

      private

      attr_reader :config, :members, :execute

      def install_members
        seen = {}
        (local_dependency_members + members).each_with_object([]) do |member, memo|
          next if seen.key?(member.name)

          seen[member.name] = true
          memo << member
        end
      end

      def local_dependency_members
        config.install_local_dependencies.map { |path| member_from_path(path) }
      end

      def member_from_path(path)
        gemspec = gemspec_path(path)
        spec = load_gemspec(gemspec)
        Member.new(
          name: spec.name,
          root: File.dirname(gemspec),
          gemspec_path: gemspec,
          version_file: version_file(File.dirname(gemspec)),
          version: spec.version.to_s,
          dependencies: spec.runtime_dependencies.map(&:name).sort,
          required_ruby_version: required_ruby_version(spec),
          licenses: Array(spec.licenses),
          authors: Array(spec.authors)
        )
      end

      def gemspec_path(path)
        expanded = File.expand_path(path)
        return expanded if File.file?(expanded) && File.extname(expanded) == ".gemspec"

        raise Error, "install local dependency does not exist: #{path}" unless Dir.exist?(expanded)

        gemspecs = Dir.glob(File.join(expanded, "*.gemspec"))
        raise Error, "no gemspec found for install local dependency: #{path}" if gemspecs.empty?
        raise Error, "multiple gemspecs found for install local dependency: #{path}" if gemspecs.size > 1

        gemspecs.first
      end

      def load_gemspec(path)
        # Some gemspecs use root-relative loads.
        # rubocop:disable ThreadSafety/DirChdir
        spec = Dir.chdir(File.dirname(path)) { Gem::Specification.load(path) }
        # rubocop:enable ThreadSafety/DirChdir
        raise Error, "could not load gemspec #{path}" unless spec

        spec
      rescue => error
        raise Error, "could not load gemspec #{path}: #{error.message}"
      end

      def version_file(root)
        Dir.glob(File.join(root, "lib", "**", "version.rb")).min
      end

      def required_ruby_version(spec)
        value = spec.required_ruby_version&.to_s&.strip
        value.empty? ? nil : value
      end

      def install_member(member)
        gem_path = local_gem_path(member)
        argv = install_argv(gem_path)
        return skipped_result(member: member, argv: argv) unless execute

        FileUtils.mkdir_p(File.dirname(gem_path))
        FileUtils.rm_f(gem_path)
        build_stdout, build_stderr, build_status = run(build_argv(member, gem_path), chdir: member.root)
        return failed_result(member: member, argv: build_argv(member, gem_path), stdout: build_stdout, stderr: build_stderr, status: build_status) unless build_status.success?

        stdout, stderr, status = run(argv)
        CommandResult.new(
          member_name: member.name,
          phase: "install",
          command: argv,
          workdir: member.root,
          status: status.exitstatus,
          success: status.success?,
          stdout: build_stdout + stdout,
          stderr: build_stderr + stderr,
          elapsed_seconds: 0.0,
          skipped: false,
          reason: status.success? ? nil : "command failed"
        )
      end

      def run(argv, chdir: nil)
        env = {"SKIP_GEM_SIGNING" => "true"}
        chdir ? Open3.capture3(env, *argv, chdir: chdir) : Open3.capture3(env, *argv)
      end

      def local_gem_path(member)
        File.join(member.root, "tmp", "local-gem-install", "#{member.name}-#{member.version}.gem")
      end

      def build_argv(member, gem_path)
        ["gem", "build", member.gemspec_path, "--output", gem_path]
      end

      def install_argv(gem_path)
        ["gem", "install", "--force", "--no-document", "--local", "--ignore-dependencies", gem_path]
      end

      def skipped_result(member:, argv:)
        CommandResult.new(
          member_name: member.name,
          phase: "install",
          command: argv,
          workdir: member.root,
          status: nil,
          success: true,
          stdout: "",
          stderr: "",
          elapsed_seconds: 0.0,
          skipped: true,
          reason: "dry-run; pass --execute to run"
        )
      end

      def failed_result(member:, argv:, stdout:, stderr:, status:)
        CommandResult.new(
          member_name: member.name,
          phase: "install",
          command: argv,
          workdir: member.root,
          status: status.exitstatus,
          success: false,
          stdout: stdout,
          stderr: stderr,
          elapsed_seconds: 0.0,
          skipped: false,
          reason: "command failed"
        )
      end

      def write_local_install_marker
        FileUtils.mkdir_p(File.dirname(local_install_marker_path))
        File.write(local_install_marker_path, JSON.pretty_generate(local_install_marker))
      end

      def local_install_marker
        {
          "family" => config.family_name,
          "root" => config.root,
          "members_root" => config.members_root,
          "local_dependencies" => config.install_local_dependencies,
          "installed_members" => install_members.map(&:name),
          "installed_at" => Time.now.utc.iso8601
        }
      end

      def local_install_marker_path
        File.join(Dir.home, ".kettle-family", "local-install.json")
      end
    end
  end
end
