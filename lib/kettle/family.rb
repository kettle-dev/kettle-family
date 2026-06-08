# frozen_string_literal: true

require "version_gem"

require_relative "family/version"
require_relative "family/member"
require_relative "family/command_result"
require_relative "family/command_runner"
require_relative "family/readiness_check"
require_relative "family/changelog_check"
require_relative "family/git_status"
require_relative "family/version_bump"
require_relative "family/branch_lane_audit"
require_relative "family/workflow"
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
