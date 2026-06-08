# frozen_string_literal: true

require "fileutils"
require "tmpdir"

RSpec.describe Kettle::Family::ReadinessCheck do
  around do |example|
    Dir.mktmpdir("kettle-family-readiness-spec") do |dir|
      @tmpdir = dir
      example.run
    end
  end

  it "passes when required files and binstubs are present" do
    member = ready_member("alpha")

    result = described_class.call(member: member)

    expect(result).to be_ok
    expect(result.stdout).to eq("")
  end

  it "reports missing files, missing binstubs, and local lockfile remotes" do
    root = File.join(@tmpdir, "alpha")
    FileUtils.mkdir_p(root)
    File.write(File.join(root, "Gemfile.lock"), "PATH\n  remote: ../beta\n")
    member = Kettle::Family::Member.new(name: "alpha", root: root, gemspec_path: "alpha.gemspec", version: "1.0.0", dependencies: [])

    result = described_class.call(member: member)

    expect(result).not_to be_ok
    expect(result.stdout).to include("missing required file Gemfile")
    expect(result.stdout).to include("missing executable binstub bin/rake")
    expect(result.stdout).to include("local path remote")
  end

  def ready_member(name)
    root = File.join(@tmpdir, name)
    FileUtils.mkdir_p(File.join(root, "bin"))
    %w[Gemfile Rakefile README.md CHANGELOG.md LICENSE.md].each do |path|
      File.write(File.join(root, path), "stub\n")
    end
    %w[bin/rake bin/rspec].each do |path|
      full_path = File.join(root, path)
      File.write(full_path, "#!/bin/sh\n")
      FileUtils.chmod("u+x", full_path)
    end
    Kettle::Family::Member.new(name: name, root: root, gemspec_path: File.join(root, "#{name}.gemspec"), version: "1.0.0", dependencies: [])
  end
end
