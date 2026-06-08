# frozen_string_literal: true

require "yaml"

module Kettle
  module Family
    class Config
      DEFAULT_PATHS = [".kettle-family.yml", ".structuredmerge/kettle-family.yml"].freeze

      attr_reader :data, :path, :root

      def self.load(root:, path: nil)
        expanded_root = File.expand_path(root)
        config_path = path && File.expand_path(path, expanded_root)
        config_path ||= DEFAULT_PATHS
          .map { |candidate| File.join(expanded_root, candidate) }
          .find { |candidate| File.file?(candidate) }

        data = config_path ? YAML.load_file(config_path) : {}
        new(root: expanded_root, path: config_path, data: data || {})
      end

      def initialize(root:, path:, data:)
        @root = root
        @path = path
        @data = stringify_keys(data)
      end

      def family_name
        fetch_path("family", "name") || File.basename(root)
      end

      def members_root
        configured = fetch_path("family", "members_root") || fetch_path("members", "root")
        configured ? File.expand_path(configured, root) : root
      end

      def explicit_members
        members = data.fetch("members", {})
        explicit = members.fetch("explicit", [])
        explicit.map do |entry|
          entry = stringify_keys(entry)
          member_root = File.expand_path(entry.fetch("root"), root)
          entry.merge("root" => member_root)
        end
      end

      def discover_members?
        members = data.fetch("members", {})
        members.fetch("discover", true)
      end

      def order_mode
        fetch_path("members", "order", "mode") || "dependency"
      end

      def order_hints
        fetch_path("members", "order", "hints") || []
      end

      private

      def fetch_path(*keys)
        keys.reduce(data) do |memo, key|
          break nil unless memo.is_a?(Hash)

          memo[key]
        end
      end

      def stringify_keys(value)
        case value
        when Hash
          value.to_h { |key, item| [key.to_s, stringify_keys(item)] }
        when Array
          value.map { |item| stringify_keys(item) }
        else
          value
        end
      end
    end
  end
end
