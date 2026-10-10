# frozen_string_literal: true

require "kettle/dev/ruby_gems_versions"

module Kettle
  module Family
    # Removes locally installed unreleased gems BEFORE a release-mode
    # dependency update re-resolves lockfiles, instead of merely detecting the
    # damage afterwards.
    #
    # This exists because bup's release-mode validation
    # (+PublishedVersionCheck+, via +validate_bundle_update_lockfile+) is
    # diagnostic only: it reports "release lockfile pins X, which is not
    # published (locally installed but unreleased; run a release-mode
    # dependency update to re-resolve)" — but that advice is circular. Bundler
    # resolves against the local gem dir and floor constraints are `>=`, so
    # with the unreleased version still installed every re-resolution pins it
    # again. Detection cannot fix resolution; the offenders have to be removed
    # first. Removing them up front turns an opaque post-update failure into a
    # resolved-before-it-mattered cleanup.
    #
    # Candidates are registry-driven, the complement of CleanInstalled's
    # source-driven selection: for every gem name this family can influence
    # (its members plus the GEM specs named in member lockfiles), any version
    # installed in a gem home that the registry does not publish is removed.
    # That catches both family members ahead of their release and transitive
    # siblings whose locally installed versions poison otherwise-clean
    # lockfiles. Published versions are never touched, so a member sitting at
    # its released version is left alone.
    #
    # Self-removal is expected and safe: the family tool itself is a candidate
    # like any other when its installed version is unreleased. The uninstall
    # runs in a subprocess and the running process has already loaded its code;
    # the executable falls back to the latest released install for subsequent
    # invocations.
    #
    # The removal is the shared GemUninstallSupport batch: one invocation, the
    # documented --ignore-dependencies retry, cache removal, and post-uninstall
    # re-enumeration proving the gems actually left the gem home.
    class ReleasePreClean
      PHASE = "release_pre_clean"

      include GemUninstallSupport

      def initialize(config:, members:, execute: false, runner: nil)
        @config = config
        @members = members
        @execute = execute
        @runner = runner || CommandRunner.new(execute: execute)
        @published = {}
      end

      # @return [Array<CommandResult>] empty when there is nothing to remove
      def results
        candidates = unreleased_installed_candidates
        return [] if candidates.empty?

        host = members.first || synthetic_host
        [verified_uninstall_outcome(candidates: candidates, host: host, command: batched_uninstall_command(candidates))]
      end

      private

      attr_reader :config, :members, :execute, :runner

      # Gem names whose installed versions this run may police: family members,
      # plus every gem named in a member's lockfile GEM section. Cross-family
      # offenders ride along through the lockfile half; unrelated user gems
      # that no member locks stay untouched.
      def policed_gem_names
        (members.map(&:name) + members.flat_map { |member| lockfile_gem_names(member) }).uniq
      end

      def lockfile_gem_names(member)
        lockfile = File.join(member.root, "Gemfile.lock")
        return [] unless File.file?(lockfile)

        Kettle::Dev::LockfileReset.registry_gem_specs_from_source(File.read(lockfile)).filter_map do |spec|
          spec[:name].to_s
        end
      rescue => error
        warn("release_pre_clean: could not read #{lockfile}: #{error.message}")
        []
      end

      # Installed versions of policed gems that no registry publishes.
      # Registry answers are memoized per process — policed names overlap
      # heavily across members, and one command run should see one snapshot.
      def unreleased_installed_candidates
        policed_gem_names.flat_map do |name|
          published = published_versions(name)
          next [] if published.nil?

          installed_versions(name).filter_map do |version|
            [name, version] unless published.include?(version.version)
          end
        end
      end

      # nil (registry unreachable) counts as "everything is published": a
      # pre-clean that fails open never removes gems because of a network
      # blip. The post-update PublishedVersionCheck still reports anything
      # real that survives.
      def published_versions(name)
        @published[name] ||= Kettle::Dev::RubyGemsVersions.published_version_numbers(name)&.then { |versions| Set.new(versions) }
      end

      def synthetic_host
        Member.new(
          name: config.family_name,
          root: config.root,
          gemspec_path: nil,
          version_file: nil,
          version: nil,
          dependencies: []
        )
      end

      def uninstall_phase
        PHASE
      end
    end
  end
end
