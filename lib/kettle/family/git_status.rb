# frozen_string_literal: true

require "open3"

module Kettle
  module Family
    class GitStatus
      def self.dirty?(root)
        stdout, _stderr, status = Open3.capture3("git", "status", "--short", chdir: root)
        status.success? && !stdout.empty?
      end
    end
  end
end
