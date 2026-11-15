# frozen_string_literal: true

RSpec.describe NoRealGemInstalls do
  it "blocks in-process DependencyInstaller installs" do
    expect { Gem::DependencyInstaller.new.install("bundler") }.to raise_error(described_class::Violation, /real gem install/)
  end

  it "blocks child-process remote `gem install`" do
    expect { Open3.capture3("gem", "install", "bundler") }.to raise_error(described_class::Violation)
  end

  it "does not block `gem install --local`" do
    expect(described_class.remote_gem_install?(["gem", "install", "--local", "x.gem"])).to be(false)
  end

  it "does not block unrelated commands" do
    expect(described_class.remote_gem_install?(["bundle", "install"])).to be(false)
  end

  it "can be opted out per example", :allow_real_gem_install do
    expect(described_class.allowed?).to be(true)
  end
end
