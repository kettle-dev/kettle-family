# frozen_string_literal: true

require "kettle/dev/lockfile_reset"
require "kettle/dev/ruby_gems_versions"

module Kettle
  module Family
    # Detects versions pinned in a release lockfile that no registry actually
    # serves — the signature of a locally built and installed gem leaking into
    # a lockfile.
    #
    # Why this is needed at all: bundler resolves against the local gem dir, so
    # an ordinary `bundle install` will happily pin a locally installed version.
    # The resulting entry is a normal GEM-section line carrying a valid checksum
    # taken from the installed spec, so it is indistinguishable from a published
    # gem by inspection. There is also no offline marker for a local build —
    # installed specs look the same as fetched ones, and Gem::Specification has
    # no #remote — so the only reliable signal is asking the registry.
    #
    # Deliberately NOT applied to templating. Templating injects its own
    # (often unreleased) version into a destination so it can run itself, and
    # local templating from unreleased source is a routine workflow; gating that
    # would break it. So this runs only where a lockfile is about to be
    # committed or published, and templating's transient local pins get cleaned
    # up later by a release-mode dependency update.
    #
    # Fails open: when the registry cannot be consulted the version counts as
    # unverifiable rather than unpublished, so offline runs are never blocked by
    # network conditions.
    class PublishedVersionCheck
      PHASE = "published_version_check"

      # Process-local memo of registry answers, keyed by [gem name, remote].
      #
      # Two reasons this is safe and desirable:
      #
      #   * Family members share almost all their toolchain and sibling
      #     dependencies, so one member's lookups serve every later member.
      #     Without this, a 30-member release re-queries the same gems 30
      #     times.
      #   * A single command invocation should see one consistent snapshot of
      #     the registry. Re-querying per member could otherwise report a gem
      #     as unpublished for early members and published for later ones if it
      #     lands mid-run.
      #
      # The memo is subordinate to the on-disk release marker, never above it.
      # kettle-release writes ~/.local/state/kettle-dev/rubygems-cache-bust.json
      # after publishing, so the filesystem is the authority on what this
      # machine just released. A gem published *during* the current run — say
      # kettle-dev 3.1.8, released before its dependents' floors are raised to
      # it — would otherwise be answered from a pre-publish memo entry and
      # falsely reported unpublished, blocking a legitimate release. So
      # #published_versions always consults the marker first and skips the memo
      # when it says that exact gem+version was just released. Verified: a
      # pre-publish memo entry yields 0 live queries without the marker check
      # and reports the new version missing.
      #
      # nil is memoized too, so an unreachable registry is asked once rather
      # than once per pin. Lifetime is one process; nothing persists.
      REGISTRY_MEMO = {}

      def self.call(member:)
        new(member: member).call
      end

      def initialize(member:)
        @member = member
      end

      def call
        found = diagnostics
        result(found)
      end

      private

      attr_reader :member

      def diagnostics
        lockfile = File.join(member.root, "Gemfile.lock")
        return [] unless File.file?(lockfile)

        registry_lockfile_specs(lockfile).filter_map { |spec| diagnostic_for(spec) }
      end

      def registry_lockfile_specs(lockfile)
        Kettle::Dev::LockfileReset.registry_gem_specs_from_source(File.read(lockfile))
      end

      # A structured diagnostic for an unpublished pin, or nil when the version is
      # published or the registry could not be consulted.
      #
      # The structured form is what machine consumers read; #message renders the
      # human line. Keeping both here rather than formatting a string and later
      # parsing it back out is what lets a consumer act on the complete set — see
      # CommandResult#diagnostics for why the summarized stdout cannot be used.
      def diagnostic_for(spec)
        return nil unless unpublished?(spec)

        name = spec.fetch(:name).to_s
        version = spec.fetch(:version).to_s
        remote = spec.fetch(:remote).to_s
        {
          "kind" => "unpublished_lockfile_pin",
          "gem" => name,
          "version" => version,
          "remote" => remote,
          "member" => member.name,
          "lockfile" => File.join(member.root, "Gemfile.lock"),
          "message" => unpublished_message(name: name, version: version, remote: remote)
        }
      end

      def unpublished_message(name:, version:, remote:)
        "release lockfile pins #{name} #{version}, " \
          "which is not published on #{remote} " \
          "(locally installed but unreleased; bup's release-mode pre-clean should have removed it — " \
          "run `kettle-family clean-installed --execute`, then repeat the release-mode dependency update)"
      end

      def unpublished?(spec)
        remote = spec.fetch(:remote).to_s
        return false if remote.empty?

        pinned = version_without_platform(spec.fetch(:version))
        versions = published_versions(spec.fetch(:name), remote, pinned)
        return false if versions.nil?

        !versions.include?(pinned)
      end

      # A lockfile pins a native gem as "1.19.4-x86_64-linux-gnu" while the
      # registry lists its versions as bare "1.19.4", one entry per platform.
      # Comparing the pinned string directly would report every native gem as
      # unpublished, so split off the platform first.
      #
      # Splitting on the first "-" matches Bundler::LockfileParser. It is safe
      # because RubyGems version strings cannot themselves contain a hyphen
      # (prerelease segments are dot-separated, e.g. "1.0.0.rc1"), so the first
      # hyphen is always the version/platform boundary.
      def version_without_platform(pinned)
        pinned.to_s.split("-", 2).first
      end

      # nil when the registry could not be consulted. Memoized per process,
      # except for gems the on-disk release marker says were just published —
      # see REGISTRY_MEMO for why bypassing the memo there is required.
      def published_versions(name, remote, version)
        key = [name, remote, version]
        unless just_released?(name, version)
          return REGISTRY_MEMO[key] if REGISTRY_MEMO.key?(key)
        end

        REGISTRY_MEMO[key] = Kettle::Dev::RubyGemsVersions.published_version_numbers(
          name,
          source: remote,
          version: version
        )
      end

      def just_released?(name, version)
        return false if version.to_s.empty?

        Kettle::Dev::RubyGemsVersions.recently_released?(name, version)
      rescue
        false
      end

      def result(found)
        clean = found.empty?
        CommandResult.new(
          member_name: member.name,
          phase: PHASE,
          command: ["internal", PHASE],
          workdir: member.root,
          status: clean ? 0 : 1,
          success: clean,
          stdout: found.map { |diagnostic| diagnostic.fetch("message") }.join("\n"),
          stderr: "",
          elapsed_seconds: 0.0,
          skipped: false,
          reason: clean ? nil : "lockfile pins versions no registry serves",
          diagnostics: found
        )
      end
    end
  end
end
