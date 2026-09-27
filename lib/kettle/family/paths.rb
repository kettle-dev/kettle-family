# frozen_string_literal: true

module Kettle
  module Family
    module Paths
      module_function

      def canonical(path, base: nil)
        expanded = File.expand_path(path, base)
        existing = expanded
        suffix = []
        until File.exist?(existing)
          parent = File.dirname(existing)
          break if parent == existing

          suffix.unshift(File.basename(existing))
          existing = parent
        end

        File.join(File.realpath(existing), *suffix)
      rescue Errno::ENOENT, Errno::EACCES
        expanded
      end
    end
  end
end
