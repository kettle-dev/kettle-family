# frozen_string_literal: true

require "pathname"

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

      def glob(*parts)
        Dir.glob(File.join(*parts).tr("\\", "/"))
      end

      def local_path_remote?(remote)
        text = remote.to_s
        drive_absolute = text.length >= 3 && text[1] == ":" && ["/", "\\"].include?(text[2])
        drive_absolute || text.start_with?("/", "./", "../", ".\\", "..\\") || Pathname.new(text).absolute?
      end
    end
  end
end
