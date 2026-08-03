# frozen_string_literal: true

require "stringio"

RSpec.describe Kettle::Family::WorkflowProgress do
  let(:progress_output_class) do
    Class.new do
      attr_reader :lines

      def initialize
        @lines = []
      end

      def puts(line = "")
        @lines << line
      end

      def string
        @lines.join("\n")
      end
    end
  end

  it "renders a sliding fixed-width event tape for TTY progress" do
    output = StringIO.new
    allow(output).to receive(:tty?).and_return(true)
    member = instance_double(Kettle::Family::Member, name: "alpha")
    progress = described_class.new(io: output, label: "templating", total: 1, jobs: 1)

    progress.start
    progress.start_member(member, total: 1, status: "template")
    35.times { progress.update(member, status: "Gemfile", mark: "*") }
    progress.finish_member(member, success: true, status: "1 file changed")
    progress.stop

    expect(output.string).to include("alpha")
    expect(output.string).to include("#{"*" * 20} Gemfile")
    expect(output.string).to include("1 file changed")
    expect(output.string).not_to include("#{"*" * 21} Gemfile")
  end

  it "renders TTY step counters and elapsed member time" do
    output = StringIO.new
    now = 10.0
    allow(output).to receive(:tty?).and_return(true)
    member = instance_double(Kettle::Family::Member, name: "alpha")
    progress = described_class.new(io: output, label: "templating", total: 1, jobs: 1, clock: -> { now })

    progress.start_member(member, total: 4, status: "prepare_lockfiles")
    now = 75.0
    progress.advance(member, status: "prepare_template_dependencies")
    progress.stop

    expect(output.string).to include("(0/4)")
    expect(output.string).to include("(1/4)")
    expect(output.string).to include("01:05")
  end

  it "preallocates TTY progress rows in member order" do
    output = StringIO.new
    allow(output).to receive(:tty?).and_return(true)
    alpha = instance_double(Kettle::Family::Member, name: "alpha")
    beta = instance_double(Kettle::Family::Member, name: "beta")
    progress = described_class.new(io: output, label: "templating", total: 2, jobs: 2, members: [alpha, beta])

    progress.start
    progress.start_member(beta, total: 1, status: "template")
    progress.start_member(alpha, total: 1, status: "template")
    progress.stop

    alpha_row = output.string.index("\e[1G\e[2Kalpha")
    beta_row = output.string.index("\e[1G\e[2Kbeta")
    expect(alpha_row).to be < beta_row
    expect(output.string).to include("\e[3A")
    expect(output.string).to include("\e[s", "\e[u\e[3A")
    expect(output.string).not_to include("\e7", "\e8")
  end

  it "redraws every member from the block anchor when updates arrive out of row order" do
    output = StringIO.new
    allow(output).to receive(:tty?).and_return(true)
    alpha = instance_double(Kettle::Family::Member, name: "alpha")
    beta = instance_double(Kettle::Family::Member, name: "beta")
    progress = described_class.new(io: output, label: "releasing", total: 2, jobs: 2, members: [alpha, beta])

    progress.start
    progress.update(beta, status: "ci:github_tick", mark: ">")
    progress.update(alpha, status: "secret:prompt_response", mark: ">")

    expect(output.string.scan("\e[3A").length).to eq(2)
    expect(output.string).to include("\e[u\e[3A")
    expect(output.string).not_to include("\e7", "\e8")
  end

  it "leaves a terminal column unused so rows cannot auto-wrap at the boundary" do
    output = StringIO.new
    allow(output).to receive(:tty?).and_return(true)
    allow(TTY::Screen).to receive(:width).and_return(72)
    member = instance_double(Kettle::Family::Member, name: "alpha")
    progress = described_class.new(io: output, label: "releasing", total: 1, jobs: 1, members: [member])

    progress.start
    progress.update(member, status: "release_publish", mark: ".")

    row = output.string.scan(/\e\[1G\e\[2K([^\n]*)\n/).last.first
    expect(Unicode::DisplayWidth.of(row)).to be < 72
  end

  it "clamps TTY statuses so member rows cannot wrap" do
    output = StringIO.new
    allow(output).to receive(:tty?).and_return(true)
    allow(TTY::Screen).to receive(:width).and_return(72)
    member = instance_double(Kettle::Family::Member, name: "alpha")
    long_status = "plugin_lifecycle " + ("configured_plugins " * 8)
    progress = described_class.new(io: output, label: "templating", total: 1, jobs: 1, members: [member])

    progress.start
    progress.update(member, status: long_status, mark: "!")
    progress.stop

    expect(output.string).to include("plugin...")
    expect(output.string).not_to include(long_status)
  end

  it "pads shorter TTY statuses so stale text cannot remain after a redraw" do
    output = StringIO.new
    allow(output).to receive(:tty?).and_return(true)
    member = instance_double(Kettle::Family::Member, name: "alpha")
    progress = described_class.new(io: output, label: "releasing", total: 1, jobs: 1, members: [member])

    progress.start
    progress.start_member(member, total: 1, status: "secret:prompt_response:RubyGems MFA code")
    progress.update(member, status: "release_publish")
    progress.stop

    status_width = progress.send(:status_width)
    expect(progress.send(:truncate_status, "release_publish").length).to eq(status_width)
    expect(progress.send(:truncate_status, "release_publish")).to end_with(" " * (status_width - "release_publish".length))
  end

  it "keeps wide-character statuses within the terminal row width" do
    output = StringIO.new
    allow(output).to receive(:tty?).and_return(true)
    allow(TTY::Screen).to receive(:width).and_return(72)
    member = instance_double(Kettle::Family::Member, name: "alpha")
    progress = described_class.new(io: output, label: "releasing", total: 1, jobs: 1, members: [member])

    progress.start
    progress.update(member, status: "secret:prompt_request:👀 🔒 watch for authorization prompt", mark: ">")

    status = progress.send(:truncate_status, "secret:prompt_request:👀 🔒 watch for authorization prompt")
    expect(Unicode::DisplayWidth.of(status)).to eq(progress.send(:status_width))
  end

  it "reserves a notification line above the event tape" do
    output = StringIO.new
    allow(output).to receive(:tty?).and_return(true)
    member = instance_double(Kettle::Family::Member, name: "alpha")
    progress = described_class.new(io: output, label: "releasing", total: 1, jobs: 1, members: [member])

    progress.start
    progress.notification("👀 🔒 watch for authorization prompt")
    progress.update(member, status: "release_publish", mark: ".")
    progress.notification("")

    expect(output.string).to include("👀 🔒 watch for authorization prompt")
    expect(output.string.scan("\e[2A").length).to eq(3)
  end

  it "saves the redraw anchor at column one below the notification and tape" do
    output = StringIO.new
    allow(output).to receive(:tty?).and_return(true)
    member = instance_double(Kettle::Family::Member, name: "alpha")
    progress = described_class.new(io: output, label: "releasing", total: 1, jobs: 1, members: [member])

    progress.start
    progress.update(member, status: "release_publish", mark: ".")

    expect(output.string).to match(/release_publish\s+\e\[1G\e\[s/)
  end

  it "renders readable non-TTY progress lines without requiring flush" do
    output = progress_output_class.new
    member = instance_double(Kettle::Family::Member, name: "alpha")
    now = 100.0
    progress = described_class.new(io: output, label: "releasing", total: 2, jobs: 1, clock: -> { now })

    progress.start
    progress.start_member(member, total: 1, status: "check")
    now = 160.0
    progress.advance(member, status: "release_build", success: false)
    progress.update(member, status: "waiting")
    progress.finish_member(member, success: false, status: "release_build")
    progress.finish_member(member, success: true, status: "release_build")
    progress.summary("release summary: 0/1 members ok")
    progress.stop

    expect(output.string).to include("releasing 2 members with 1 job:")
    expect(output.string).to include("[alpha]   (0/1)   00:00 > check")
    expect(output.string).to include("[alpha]   (1/1)   01:00 F release_build")
    expect(output.string).to include("[alpha]   (1/1)   01:00 > waiting")
    expect(output.string).to include("[alpha]   (1/1)   01:00 failed release_build")
    expect(output.string).to include("[alpha]   (1/1)   01:00 done release_build")
    expect(output.string).to include("release summary: 0/1 members ok")
  end

  it "renders TTY command result marks and ignores empty TTY event marks" do
    output = StringIO.new
    allow(output).to receive(:tty?).and_return(true)
    member = instance_double(Kettle::Family::Member, name: "alpha")
    enabled = described_class.new(io: output, label: "templating", total: 1, jobs: 1)

    enabled.start_member(member, total: 1, status: "template")
    enabled.advance(member, status: "template")
    enabled.advance(member, status: "template", success: false)
    enabled.update(member, status: "")
    enabled.update(member, status: "Gemfile")
    enabled.update(member, status: "Gemfile", mark: "")
    enabled.summary("template summary")

    expect(output.string).to include(".F")
    expect(output.string).to include("Gemfile")
    expect(output.string).to include("template summary")
  end

  it "ignores disabled progress without output" do
    progress = described_class.new(io: nil, label: "templating", total: 1, jobs: 1)
    member = instance_double(Kettle::Family::Member, name: "alpha")

    progress.start
    progress.start_member(member, total: 1, status: "template")
    progress.advance(member, status: "template")
    progress.update(member, status: "Gemfile")
    progress.finish_member(member, success: true, status: "template")
    progress.summary("template summary")
    progress.stop

    expect(progress.tty?).to be(false)
  end
end
