# frozen_string_literal: true

module Kettle
  module Family
    # The execution context is a compatibility boundary, not a collection of
    # incidental ENV assignments. Each workflow command selects one profile so
    # path-gem, lockfile, install, and mutation rules remain reviewable.
    class ExecutionProfile
      Definition = Struct.new(
        :name,
        :path_gem_policy,
        :lockfile_role,
        :install_location,
        :host_platform_policy,
        :allowed_mutations
      ) do
        def local_path_gems?
          path_gem_policy != :registry_only
        end

        def canonical_lockfile?
          lockfile_role == :canonical
        end
      end

      DEFINITIONS = {
        development_local: Definition.new(
          name: :development_local,
          path_gem_policy: :configured_siblings,
          lockfile_role: :canonical,
          install_location: :member,
          host_platform_policy: :active_platform_must_resolve,
          allowed_mutations: %i[development_lockfiles source test]
        ),
        template_local: Definition.new(
          name: :template_local,
          path_gem_policy: :configured_siblings,
          lockfile_role: :canonical,
          install_location: :member,
          host_platform_policy: :active_platform_must_resolve,
          allowed_mutations: %i[template development_lockfiles generated]
        ),
        release_registry: Definition.new(
          name: :release_registry,
          path_gem_policy: :registry_only,
          lockfile_role: :canonical,
          install_location: :disposable,
          host_platform_policy: :active_platform_must_resolve,
          allowed_mutations: %i[canonical_release_lockfiles]
        ),
        release_monorepo: Definition.new(
          name: :release_monorepo,
          path_gem_policy: :configured_release_wave,
          lockfile_role: :canonical,
          install_location: :disposable,
          host_platform_policy: :active_platform_must_resolve,
          allowed_mutations: %i[canonical_release_lockfiles configured_wave_paths]
        ),
        release_recovery: Definition.new(
          name: :release_recovery,
          path_gem_policy: :configured_release_wave,
          lockfile_role: :canonical,
          install_location: :disposable,
          host_platform_policy: :active_platform_must_resolve,
          allowed_mutations: %i[canonical_release_lockfiles configured_wave_paths]
        )
      }.each_value(&:freeze).freeze

      def self.fetch(name)
        DEFINITIONS.fetch(name.to_sym)
      rescue KeyError
        raise ArgumentError, "unknown execution profile: #{name.inspect}"
      end
    end
  end
end
