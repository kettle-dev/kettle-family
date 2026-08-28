# frozen_string_literal: true

require "open3"

module Kettle
  module Family
    class GitStatus
      def self.dirty?(root)
        stdout, _stderr, status = Open3.capture3("git", "status", "--short", chdir: root)
        status.success? && !stdout.empty?
      end

      def self.dirty_paths(root)
        stdout, _stderr, status = Open3.capture3("git", "status", "--short", chdir: root)
        return [] unless status.success?

        stdout.lines.map(&:chomp).reject(&:empty?)
      end

      def self.path_from_status_line(status_line)
        line = status_line.to_s
        path = (line.length >= 3 && line[2] == " ") ? line[3..] : line
        path = path.to_s.strip
        path.include?(" -> ") ? path.split(" -> ", 2).last : path
      end
    end
  end
end
