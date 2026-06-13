# frozen_string_literal: true

require "open3"

module Kettle
  module Family
    class Discovery
      def initialize(config:)
        @config = config
      end

      def members
        discovered = config.discover_members? ? discover_members : []
        explicit = explicit_members
        by_name = {}

        (discovered + explicit).each do |member|
          existing = by_name[member.name]
          raise Error, "duplicate family member #{member.name.inspect}" if existing && existing.root != member.root

          by_name[member.name] = member
        end

        by_name.values.sort_by(&:name)
      end

      private

      attr_reader :config

      def discover_members
        gemspecs = config.member_roots.flat_map do |root|
          Dir.glob(File.join(root, "**", "*.gemspec"))
        end
        gemspecs.reject! { |path| excluded_gemspec?(path) }
        gemspecs.map { |path| member_from_gemspec(path) }
      end

      def explicit_members
        config.explicit_members.map do |entry|
          gemspec_path = if entry["gemspec"]
            File.expand_path(entry["gemspec"], entry.fetch("root"))
          else
            primary_gemspec(entry.fetch("root"))
          end
          member_from_gemspec(gemspec_path)
        end
      end

      def primary_gemspec(root)
        gemspecs = Dir.glob(File.join(root, "*.gemspec"))
        raise Error, "no gemspec found in #{root}" if gemspecs.empty?
        return gemspecs.first if gemspecs.one?

        raise Error, "multiple gemspecs found in #{root}; configure the member gemspec explicitly"
      end

      def member_from_gemspec(path)
        spec = load_gemspec(path)
        Member.new(
          name: spec.name,
          root: File.dirname(path),
          gemspec_path: path,
          version_file: version_file(File.dirname(path)),
          version: spec.version.to_s,
          dependencies: spec.dependencies.map(&:name).sort
        )
      end

      def version_file(root)
        candidates = Dir.glob(File.join(root, "lib", "**", "version.rb"))
        candidates.min
      end

      def load_gemspec(path)
        spec = Gem::Specification.load(path)
        raise Error, "could not load gemspec #{path}" unless spec

        spec
      rescue => error
        raise Error, "could not load gemspec #{path}: #{error.message}"
      end

      def excluded_gemspec?(path)
        ignored_by_git?(path) || excluded_by_pattern?(path)
      end

      def ignored_by_git?(path)
        _stdout, _stderr, status = Open3.capture3("git", "check-ignore", "--quiet", "--", path, chdir: config.root)
        status.success?
      end

      def excluded_by_pattern?(path)
        config.member_exclude_patterns.any? do |pattern|
          path_matches_pattern?(path, pattern)
        end
      end

      def path_matches_pattern?(path, pattern)
        relative_candidates(path).any? do |relative|
          File.fnmatch?(pattern, relative, File::FNM_DOTMATCH | File::FNM_EXTGLOB)
        end
      end

      def relative_candidates(path)
        ([config.root] + config.member_roots).filter_map do |root|
          relative_path(path, root)
        end
      end

      def relative_path(path, root)
        expanded_path = File.expand_path(path)
        expanded_root = File.expand_path(root)
        prefix = "#{expanded_root}/"
        return unless expanded_path.start_with?(prefix)

        expanded_path.delete_prefix(prefix)
      end
    end
  end
end
