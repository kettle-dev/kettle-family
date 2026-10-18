# frozen_string_literal: true

RSpec.describe Kettle::Family::CLI::MiseTasks do
  let(:tmp_root) { Dir.mktmpdir("mise_tasks_cli_spec_") }
  let(:root_mise) { File.join(tmp_root, "mise.toml") }

  before do
    File.write(root_mise, <<~TOML)
      [env]
      FOO = "bar"

      [tasks.clean]
      run = "echo clean"
    TOML
  end

  after { FileUtils.rm_rf(tmp_root) }

  def run_command(*argv)
    Kettle::Family::CLI.call(["mise-tasks", *argv], out: StringIO.new, err: StringIO.new)
  end

  it "is registered as a kettle-family command" do
    expect(Kettle::Family::CLI::COMMANDS).to include("mise-tasks")
  end

  it "creates the managed task file from the baseline and ensures the include" do
    skip_for(engine: "ruby", versions: "head", reason: "tree_sitter_language_pack does not publish a native extension for Ruby head's unstable ABI")

    expect(run_command("--root", tmp_root)).to eq(0)

    task_file = File.join(tmp_root, "mise-family.tasks.toml")
    expect(File).to exist(task_file)
    content = File.read(root_mise)
    expect(content).to include("[task_config]")
    expect(content).to include('includes = ["mise-family.tasks.toml"]')
    expect(content).to include("[tasks.clean]")
  end

  it "is idempotent on a second run" do
    skip_for(engine: "ruby", versions: "head", reason: "tree_sitter_language_pack does not publish a native extension for Ruby head's unstable ABI")

    run_command("--root", tmp_root)
    before = File.read(root_mise)

    expect(run_command("--root", tmp_root)).to eq(0)
    expect(File.read(root_mise)).to eq(before)
  end

  it "warns on redefinitions and exits 0 (redefinition allowed)" do
    skip_for(engine: "ruby", versions: "head", reason: "tree_sitter_language_pack does not publish a native extension for Ruby head's unstable ABI")

    run_command("--root", tmp_root)
    File.write(root_mise, File.read(root_mise) + "\n[tasks.family-lint]\nrun = \"echo local\"\n")

    expect(run_command("--root", tmp_root)).to eq(0)
    expect(File.read(root_mise)).to include("[tasks.family-lint]")
  end

  it "removes redefinitions with --clean" do
    skip_for(engine: "ruby", versions: "head", reason: "tree_sitter_language_pack does not publish a native extension for Ruby head's unstable ABI")

    run_command("--root", tmp_root)
    # The managed file must define the task too -- --clean only removes
    # definitions that duplicate the managed baseline.
    File.write(File.join(tmp_root, "mise-family.tasks.toml"), "[family-lint]\nrun = \"echo managed\"\n")
    File.write(root_mise, File.read(root_mise) + "\n[tasks.family-lint]\nrun = \"echo local\"\n")

    expect(run_command("--root", tmp_root, "--clean")).to eq(0)
    expect(File.read(root_mise)).not_to include("echo local")
    expect(File.read(root_mise)).to include("[tasks.clean]")
  end

  it "fails when the root has no mise.toml" do
    empty = File.join(tmp_root, "empty")
    FileUtils.mkdir_p(empty)

    expect(run_command("--root", empty)).to eq(1)
  end
end
