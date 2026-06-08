# frozen_string_literal: true

require "fileutils"
require "json"
require "stringio"
require "tmpdir"

RSpec.describe Kettle::Family::Discovery do
  around do |example|
    Dir.mktmpdir("kettle-family-sibling-spec") do |dir|
      @tmpdir = dir
      example.run
    end
  end

  it "discovers sibling repository members from direct child directories" do
    write_gem("alpha")
    write_gem("beta")
    FileUtils.mkdir_p(File.join(@tmpdir, "notes"))
    File.write(File.join(@tmpdir, ".kettle-family.yml"), <<~YAML)
      family:
        name: siblings
        mode: sibling_repos
    YAML

    config = Kettle::Family::Config.load(root: @tmpdir)
    members = described_class.new(config: config).members

    expect(config.family_mode).to eq("sibling_repos")
    expect(members.map(&:name)).to eq(%w[alpha beta])
  end

  it "reports branch lane audit results through the CLI" do
    write_gem("alpha")
    File.write(File.join(@tmpdir, ".kettle-family.yml"), <<~YAML)
      family:
        mode: sibling_repos
      branch_lanes:
        ruby-3-4:
          branch: ruby-3-4
          version: 3.4.0
          members:
            - alpha
    YAML
    out = StringIO.new

    status = Kettle::Family::CLI.call(["branch-lanes", "--root", @tmpdir, "--json"], out: out, err: StringIO.new)
    report = JSON.parse(out.string)

    expect(status).to eq(0)
    expect(report.fetch("family_mode")).to eq("sibling_repos")
    expect(report.fetch("branch_lanes")).to have_key("ruby-3-4")
    expect(report.fetch("results").first.fetch("phase")).to eq("branch_lane_audit")
  end

  def write_gem(name)
    root = File.join(@tmpdir, name)
    FileUtils.mkdir_p(root)
    File.write(File.join(root, "#{name}.gemspec"), <<~RUBY)
      Gem::Specification.new do |spec|
        spec.name = "#{name}"
        spec.version = "1.0.0"
      end
    RUBY
  end
end
