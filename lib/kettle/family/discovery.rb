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
        root = File.dirname(path)
        dependencies = spec.runtime_dependencies.map(&:name).sort
        Member.new(
          name: spec.name,
          root: root,
          gemspec_path: path,
          version_file: version_file(root, spec.name),
          version: spec.version.to_s,
          dependencies: dependencies,
          release_dependencies: release_dependencies(root: root, spec: spec, dependencies: dependencies),
          required_ruby_version: required_ruby_version(spec),
          licenses: licenses(spec),
          authors: authors(spec)
        )
      end

      def release_dependencies(root:, spec:, dependencies:)
        (
          dependencies +
          spec.development_dependencies.map(&:name) +
          gemfile_dependencies(root)
        ).uniq.sort
      end

      def gemfile_dependencies(root)
        gemfile = File.join(root, "Gemfile")
        return [] unless File.file?(gemfile)

        gemfile_dependency_collector(root: root).dependencies_for(gemfile).sort
      end

      def gemfile_dependency_collector(root:)
        GemfileDependencyCollector.new(root: root)
      end

      def required_ruby_version(spec)
        value = spec.required_ruby_version&.to_s&.strip
        value.empty? ? nil : value
      end

      def licenses(spec)
        values = Array(spec.licenses).compact.map(&:to_s).map(&:strip).reject(&:empty?)
        values = [spec.license.to_s.strip] if values.empty? && spec.respond_to?(:license) && !spec.license.to_s.strip.empty?
        values
      end

      def authors(spec)
        Array(spec.authors).compact.map(&:to_s).map(&:strip).reject(&:empty?)
      end

      def version_file(root, gem_name)
        canonical = File.join(root, "lib", gem_name.tr("-", "_"), "version.rb")
        return canonical if File.file?(canonical)

        candidates = Dir.glob(File.join(root, "lib", "**", "version.rb"))
        candidates.min
      end

      def load_gemspec(path)
        # Some legacy gemspecs use root-relative Kernel.load calls, and RubyGems
        # evaluates gemspecs relative to the current process directory.
        # Gem::Specification.load caches by path, which is wrong for branch-stack
        # workflows that checkout different contents at the same path.
        # rubocop:disable ThreadSafety/DirChdir
        spec = Dir.chdir(File.dirname(path)) { eval_gemspec(path) }
        # rubocop:enable ThreadSafety/DirChdir
        raise Error, "could not load gemspec #{path}" unless spec

        spec
      rescue => error
        raise Error, "could not load gemspec #{path}: #{error.message}"
      end

      def eval_gemspec(path)
        return unless File.file?(path)

        code = Gem.open_file(path, "r:UTF-8:-", &:read)
        spec = eval(code, binding, path) # rubocop:disable Security/Eval -- Mirrors RubyGems gemspec loading without its path cache.
        return spec if spec.is_a?(Gem::Specification)

        raise Error, "#{path} is not a Gem::Specification"
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

      class GemfileDependencyCollector
        GEM_METHODS = %i[gem].freeze
        EVAL_GEMFILE_METHODS = %i[eval_gemfile].freeze

        def initialize(root:)
          @root = root
          @dependencies = Set.new
          @visited = Set.new
        end

        def dependencies_for(path)
          collect(File.expand_path(path))
          dependencies.to_a
        end

        private

        attr_reader :root, :dependencies, :visited

        def collect(path)
          return unless File.file?(path)
          return if visited.include?(path)

          visited << path
          source = File.read(path)
          parse_result = parse_source(source, path)
          each_node(parse_result.value) do |node|
            collect_call(path, node) if node.is_a?(Prism::CallNode)
          end
        end

        def collect_call(path, node)
          args = node.arguments&.arguments || []
          first_arg = args.first
          dependencies << first_arg.unescaped if GEM_METHODS.include?(node.name) && first_arg.is_a?(Prism::StringNode)
          collect(eval_gemfile_path(path, first_arg)) if EVAL_GEMFILE_METHODS.include?(node.name) && first_arg.is_a?(Prism::StringNode)
        end

        def eval_gemfile_path(path, node)
          gemfile_path = node.unescaped
          return File.expand_path(gemfile_path, root) if gemfile_path.start_with?("/")

          File.expand_path(gemfile_path, File.dirname(path))
        end

        def parse_source(source, path)
          require_prism
          parse_result = Prism.parse(source)
          raise Error, "could not parse Gemfile dependency file #{path}" unless parse_result.success?

          parse_result
        end

        def require_prism
          return if defined?(Prism)

          require "prism"
        rescue LoadError => error
          raise Error, "Gemfile dependency discovery requires Prism; install the prism gem or run on Ruby 3.3+ (#{error.message})"
        end

        def each_node(root)
          return enum_for(__method__, root) unless block_given?

          queue = [root]
          until queue.empty?
            node = queue.shift
            yield node
            queue.concat(node.child_nodes.compact) if node.respond_to?(:child_nodes)
          end
        end
      end
    end
  end
end
