# frozen_string_literal: true

module Kettle
  module Family
    Member = Struct.new(
      :name,
      :root,
      :gemspec_path,
      :version_file,
      :version,
      :dependencies,
      keyword_init: true
    ) do
      def to_h
        {
          "name" => name,
          "root" => root,
          "gemspec_path" => gemspec_path,
          "version_file" => version_file,
          "version" => version,
          "dependencies" => dependencies
        }
      end
    end
  end
end
