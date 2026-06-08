# frozen_string_literal: true

require "fileutils"
require "tmpdir"

RSpec.describe Kettle::Family::ChangelogCheck do
  around do |example|
    Dir.mktmpdir("kettle-family-changelog-spec") do |dir|
      @tmpdir = dir
      example.run
    end
  end

  it "passes when CHANGELOG.md has an Unreleased section" do
    member = member_at("alpha")
    File.write(File.join(member.root, "CHANGELOG.md"), "## [Unreleased]\n")

    result = described_class.call(member: member)

    expect(result).to be_ok
  end

  it "reports missing or incomplete changelogs" do
    member = member_at("alpha")

    missing = described_class.call(member: member)
    File.write(File.join(member.root, "CHANGELOG.md"), "# Changelog\n")
    incomplete = described_class.call(member: member)

    expect(missing.stdout).to include("missing CHANGELOG.md")
    expect(incomplete.stdout).to include("missing Unreleased")
  end

  def member_at(name)
    root = File.join(@tmpdir, name)
    FileUtils.mkdir_p(root)
    Kettle::Family::Member.new(name: name, root: root, gemspec_path: nil, version_file: nil, version: "1.0.0", dependencies: [])
  end
end
