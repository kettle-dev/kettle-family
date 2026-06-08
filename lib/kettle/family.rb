# frozen_string_literal: true

require "version_gem"

require_relative "family/version"
require_relative "family/member"
require_relative "family/config"
require_relative "family/discovery"
require_relative "family/orderer"
require_relative "family/selection"
require_relative "family/report"
require_relative "family/cli"

module Kettle
  module Family
    class Error < StandardError; end
  end
end

Kettle::Family::Version.class_eval do
  extend VersionGem::Basic
end
