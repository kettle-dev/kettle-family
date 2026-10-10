# frozen_string_literal: true

module Kettle
  module Family
    # Builds a Member from a filesystem path (directory or .gemspec file).
    #
    # Shared by LocalInstall (`install`) and CleanInstalled (`clean-installed`),
    # which operate on the same member set -- they are inverse operations, so
    # diverging member construction would make the inverse inexact.
    #
    # Every method is private on inclusion: this is internal machinery, and
    # including it must not widen the public API of the commands that use it.
    module MemberLoader
      private

      def member_from_path(path)
        gemspec = gemspec_path(path)
        spec = load_gemspec(gemspec)
        Member.new(
          name: spec.name,
          root: File.dirname(gemspec),
          gemspec_path: gemspec,
          version_file: version_file(File.dirname(gemspec), spec.name),
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

        gemspecs = Paths.glob(expanded, "*.gemspec")
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

      def version_file(root, gem_name)
        canonical = File.join(root, "lib", gem_name.tr("-", "_"), "version.rb")
        return canonical if File.file?(canonical)

        Paths.glob(root, "lib", "**", "version.rb").min
      end

      def required_ruby_version(spec)
        value = spec.required_ruby_version&.to_s&.strip
        value.empty? ? nil : value
      end
    end
  end
end
