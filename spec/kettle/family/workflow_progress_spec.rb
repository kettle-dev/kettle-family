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
    expect(output.string).to include("#{"*" * 30} Gemfile")
    expect(output.string).to include("1 file changed")
    expect(output.string).not_to include("#{"*" * 31} Gemfile")
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

    alpha_row = output.string.index("\e[1Galpha")
    beta_row = output.string.index("\e[1Gbeta")
    expect(alpha_row).to be < beta_row
    expect(output.string).to include("\e[1A\e[1Gbeta")
    expect(output.string).to include("\e[2A\e[1Galpha")
  end

  it "renders readable non-TTY progress lines without requiring flush" do
    output = progress_output_class.new
    member = instance_double(Kettle::Family::Member, name: "alpha")
    progress = described_class.new(io: output, label: "releasing", total: 2, jobs: 1)

    progress.start
    progress.start_member(member, total: 1, status: "check")
    progress.advance(member, status: "release_build", success: false)
    progress.update(member, status: "waiting")
    progress.finish_member(member, success: false, status: "release_build")
    progress.finish_member(member, success: true, status: "release_build")
    progress.summary("release summary: 0/1 members ok")
    progress.stop

    expect(output.string).to include("releasing 2 members with 1 job:")
    expect(output.string).to include("[alpha] F release_build")
    expect(output.string).to include("[alpha] > waiting")
    expect(output.string).to include("[alpha] failed release_build")
    expect(output.string).to include("[alpha] done release_build")
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
