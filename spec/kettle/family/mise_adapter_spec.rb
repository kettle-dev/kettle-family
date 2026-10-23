# frozen_string_literal: true

require "fileutils"

RSpec.describe Kettle::Family::MiseAdapter do
  subject(:adapter) { described_class.new }

  around do |example|
    Dir.mktmpdir("kettle-family-mise-adapter-spec") do |dir|
      @tmpdir = dir
      example.run
    end
  end

  describe "#executable" do
    it "returns the absolute path of the first executable mise on PATH" do
      bin = File.join(@tmpdir, "bin")
      FileUtils.mkdir_p(bin)
      fake = File.join(bin, "mise")
      File.write(fake, "#!/bin/sh\n")
      FileUtils.chmod("u+x", fake)
      stub_env("PATH" => bin)

      expect(adapter.executable).to eq(fake)
    end

    it "returns nil when PATH has only a non-executable mise" do
      bin = File.join(@tmpdir, "bin")
      FileUtils.mkdir_p(bin)
      File.write(File.join(bin, "mise"), "#!/bin/sh\n")
      stub_env("PATH" => bin)

      expect(adapter.executable).to be_nil
    end

    it "returns nil when PATH has no mise" do
      stub_env("PATH" => @tmpdir)

      expect(adapter.executable).to be_nil
    end
  end

  describe "#trust_argv" do
    context "when mise is available" do
      before do
        @bin = File.join(@tmpdir, "bin")
        FileUtils.mkdir_p(@bin)
        @fake = File.join(@bin, "mise")
        File.write(@fake, "#!/bin/sh\n")
        FileUtils.chmod("u+x", @fake)
        stub_env("PATH" => @bin)
      end

      it "returns the trust argv with the resolved executable" do
        expect(adapter.trust_argv("/some/root")).to eq([@fake, "trust", "-C", "/some/root"])
      end
    end

    context "when mise is unavailable" do
      before do
        stub_env("PATH" => @tmpdir)
      end

      it "returns nil so callers skip the trust phase" do
        expect(adapter.trust_argv("/some/root")).to be_nil
      end
    end
  end

  describe "#exec_argv" do
    let(:argv) { ["bundle", "exec", "rspec"] }

    context "when mise is available" do
      before do
        @bin = File.join(@tmpdir, "bin")
        FileUtils.mkdir_p(@bin)
        @fake = File.join(@bin, "mise")
        File.write(@fake, "#!/bin/sh\n")
        FileUtils.chmod("u+x", @fake)
        stub_env("PATH" => @bin)
      end

      it "wraps the command in mise exec" do
        expect(adapter.exec_argv(member_root: "/member", argv: argv)).to eq(
          [@fake, "exec", "-C", "/member", "--", "bundle", "exec", "rspec"]
        )
      end

      it "injects env through env(1) inside the wrapper" do
        result = adapter.exec_argv(member_root: "/member", argv: argv, set_env: {"A" => "1"}, unset_env: ["B"])

        if Gem.win_platform?
          expect(result.first(5)).to eq([@fake, "exec", "-C", "/member", "--"])
          expect(result).to include("A=1", "B")
        else
          expect(result).to eq(
            [@fake, "exec", "-C", "/member", "--", "env", "-u", "B", "A=1", "bundle", "exec", "rspec"]
          )
        end
      end
    end

    context "when mise is unavailable" do
      before do
        stub_env("PATH" => @tmpdir)
      end

      it "passes the command through unwrapped when no env injection is needed" do
        expect(adapter.exec_argv(member_root: "/member", argv: argv)).to eq(argv)
      end

      it "passes the command through env(1) when env injection is needed" do
        result = adapter.exec_argv(member_root: "/member", argv: argv, set_env: {"A" => "1"}, unset_env: ["B"])

        if Gem.win_platform?
          expect(result.first(4)).to eq(["ruby", "--disable=rubyopt", "-e", described_class::WINDOWS_ENV_EXEC_SCRIPT])
          expect(result).to include("A=1", "B")
        else
          expect(result).to eq(["env", "-u", "B", "A=1", "bundle", "exec", "rspec"])
        end
      end
    end
  end
end
