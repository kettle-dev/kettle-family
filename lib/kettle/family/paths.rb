# frozen_string_literal: true

require "pathname"
require "kettle/dev"

module Kettle
  module Family
    module Paths
      module_function

      def canonical(path, base: nil)
        Kettle::Dev::Paths.canonical(path, base: base)
      end

      def same?(left, right, base: nil)
        Kettle::Dev::Paths.same?(left, right, base: base)
      end

      def within?(path, root, base: nil)
        Kettle::Dev::Paths.within?(path, root, base: base)
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
