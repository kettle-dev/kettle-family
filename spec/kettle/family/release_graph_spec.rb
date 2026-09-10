# frozen_string_literal: true

require "tmpdir"

RSpec.describe Kettle::Family::ReleaseGraph do
  around do |example|
    Dir.mktmpdir("kettle-family-release-graph-spec") do |root|
      @root = root
      example.run
    end
  end

  it "serializes a CI-resident monorepo graph with its family CI root" do
    gems = File.join(@root, "gems")
    FileUtils.mkdir_p(gems)

    graph = described_class.new(
      name: "monorepo_ci_local",
      ci_root: @root,
      local_path_roots: [gems],
      selector_env: {"STRUCTUREDMERGE_DEV" => gems}
    )

    expect(graph.to_h).to eq(
      "name" => "monorepo_ci_local",
      "ci_root" => @root,
      "local_path_roots" => [gems],
      "selector_env" => {"STRUCTUREDMERGE_DEV" => gems}
    )
  end

  it "rejects a monorepo graph whose path is outside its CI checkout" do
    expect do
      described_class.new(
        name: "monorepo_ci_local",
        ci_root: @root,
        local_path_roots: [File.join(File.dirname(@root), "outside")],
        selector_env: {"STRUCTUREDMERGE_DEV" => File.join(File.dirname(@root), "outside")}
      )
    end.to raise_error(Kettle::Family::Error, /outside CI root/)
  end

  it "does not permit local selectors in a terminal branch graph" do
    expect do
      described_class.new(
        name: "branch_terminal",
        local_path_roots: [@root],
        selector_env: {"RUBOCOP_LTS_DEV" => @root}
      )
    end.to raise_error(Kettle::Family::Error, /cannot declare local paths or selectors/)
  end

  it "does not permit an unrecognized graph contract" do
    expect { described_class.new(name: "ambient") }.to raise_error(Kettle::Family::Error, /unknown release graph contract/)
  end
end
