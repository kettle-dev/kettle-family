# frozen_string_literal: true

require "version_gem"

require_relative "family/version"

module Kettle
  module Family
    class Error < StandardError; end
    # Your code goes here...
  end
end

Kettle::Family::Version.class_eval do
  extend VersionGem::Basic
end
