# frozen_string_literal: true

require "etc"

module Kettle
  module Family
    # Allocates CPU capacity between concurrent family members and optional
    # member-internal workers. A member consumes one wave slot before any
    # command-specific workers are considered.
    module Concurrency
      module_function

      def default_wave_jobs(cpu_count: Etc.nprocessors)
        [cpu_count / 2, 1].max
      end

      def wave_jobs(requested:, item_count:, cpu_count: Etc.nprocessors)
        return 0 if item_count.zero?

        count = requested.nil? ? default_wave_jobs(cpu_count: cpu_count) : requested.to_i
        count.clamp(1, item_count)
      end

      def internal_worker_limit(wave_jobs:, cpu_count: Etc.nprocessors)
        raise ArgumentError, "wave jobs must be positive" unless wave_jobs.to_i.positive?

        half_cores = default_wave_jobs(cpu_count: cpu_count)
        available_per_member = (cpu_count - wave_jobs.to_i) / wave_jobs.to_i
        [half_cores, [available_per_member, 1].max].min
      end
    end
  end
end
