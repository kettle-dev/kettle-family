# frozen_string_literal: true

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
        gemspecs = Dir.glob(File.join(config.members_root, "**", "*.gemspec"))
        gemspecs.reject! { |path| path.include?("/vendor/") }
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
          version: spec.version.to_s,
          dependencies: spec.dependencies.map(&:name).sort
        )
      end

      def load_gemspec(path)
        spec = Gem::Specification.load(path)
        raise Error, "could not load gemspec #{path}" unless spec

        spec
      rescue => error
        raise Error, "could not load gemspec #{path}: #{error.message}"
      end
    end
  end
end
