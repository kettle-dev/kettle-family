# frozen_string_literal: true

require "open3"
require "rubygems/dependency_installer"
require "rubygems/installer"

# Specs must never install gems into the shared gem home. CI runs specs in
# parallel (turbo_tests2 workers share GEM_HOME), so one worker installing or
# rewriting a gem (for example a newer Bundler) while another runs `bundle`
# leaves a half-written gem and a random LoadError somewhere else. Stub the
# installing code instead, or opt in with the :allow_real_gem_install metadata
# when an example genuinely needs a real install into its own isolated GEM_HOME.
module NoRealGemInstalls
  class Violation < StandardError; end

  REMEDY = "Stub the install (e.g. allow(Kettle::Dev::BundlerPinning).to receive(:install_stable)) " \
    "or tag the example :allow_real_gem_install and isolate GEM_HOME."

  def self.allowed?
    !!RSpec.current_example&.metadata&.fetch(:allow_real_gem_install, false)
  end

  def self.check!(what)
    return if allowed?

    raise Violation, "spec attempted a real gem install (#{what}), which races parallel spec workers. #{REMEDY}"
  end

  # In-process installs: Gem::DependencyInstaller#install and Gem::Installer#install.
  module InProcess
    def install(*)
      NoRealGemInstalls.check!("#{self.class}#install")
      super
    end
  end

  # Child processes: `gem install` without --local reaches RubyGems and writes the gem home.
  module Subprocess
    %i[capture3 capture2 capture2e popen3 popen2 popen2e].each do |name|
      define_method(name) do |*args, **kwargs, &block|
        NoRealGemInstalls.check!("#{name} #{NoRealGemInstalls.command_text(args)}") if NoRealGemInstalls.remote_gem_install?(args)
        super(*args, **kwargs, &block)
      end
    end
  end

  def self.command_text(args)
    args.reject { |arg| arg.is_a?(Hash) }.join(" ")[0, 120]
  end

  def self.remote_gem_install?(args)
    argv = args.reject { |arg| arg.is_a?(Hash) }.map(&:to_s)
    argv = argv.flat_map { |arg| arg.split(/\s+/) } if argv.length == 1
    index = argv.index("gem")
    return false unless index && argv[index + 1] == "install"

    (argv & %w[--local -l]).empty?
  end
end

Gem::DependencyInstaller.prepend(NoRealGemInstalls::InProcess)
Gem::Installer.prepend(NoRealGemInstalls::InProcess)
Open3.singleton_class.prepend(NoRealGemInstalls::Subprocess)
