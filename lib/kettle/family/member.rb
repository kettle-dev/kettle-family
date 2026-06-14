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
      :required_ruby_version,
      :licenses,
      :authors
    ) do
      def to_h
        {
          "name" => name,
          "root" => root,
          "gemspec_path" => gemspec_path,
          "version_file" => version_file,
          "version" => version,
          "dependencies" => dependencies,
          "required_ruby_version" => required_ruby_version,
          "licenses" => Array(licenses),
          "authors" => Array(authors)
        }
      end
    end
  end
end
