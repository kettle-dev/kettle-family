# frozen_string_literal: true

require "fileutils"
require "open3"
require "tmpdir"

RSpec.describe Kettle::Family::RemoteCheck do
  around do |example|
    Dir.mktmpdir do |tmpdir|
      @tmpdir = tmpdir
      example.run
    end
  end

  def create_git_member(name, origin:, extra_remotes: {}, gemspec_homepage: nil)
    root = File.join(@tmpdir, name)
    FileUtils.mkdir_p(root)
    Open3.capture3("git", "init", chdir: root)
    Open3.capture3("git", "remote", "add", "origin", origin, chdir: root) if origin
    extra_remotes.each do |remote_name, url|
      Open3.capture3("git", "remote", "add", remote_name, url, chdir: root)
    end
    gemspec_path = nil
    if gemspec_homepage
      gemspec_path = File.join(root, "#{name}.gemspec")
      File.write(gemspec_path, <<~RUBY)
        Gem::Specification.new do |spec|
          spec.name = #{name.inspect}
          spec.homepage = #{gemspec_homepage.inspect}
        end
      RUBY
    end
    Kettle::Family::Member.new(
      name: name,
      root: root,
      gemspec_path: gemspec_path,
      version_file: nil,
      version: "1.0.0",
      dependencies: []
    )
  end

  def build_config(extra_yaml = "")
    File.write(File.join(@tmpdir, ".kettle-family.yml"), <<~YAML)
      family:
        name: example
        mode: sibling_repos
      #{extra_yaml}
    YAML
    Kettle::Family::Config.load(root: @tmpdir)
  end

  describe ".parse_hosted_remote and .rewrite_remote_url" do
    it "parses SSH, ssh://, git+ssh://, and HTTPS remotes across supported hosts" do
      expect(described_class.parse_hosted_remote("git@github.com:pboling/kettle-paths.git"))
        .to eq(host: "github.com", owner: "pboling", repo: "kettle-paths")
      expect(described_class.parse_hosted_remote("https://gitlab.com/kettle-dev/kettle-paths"))
        .to eq(host: "gitlab.com", owner: "kettle-dev", repo: "kettle-paths")
      expect(described_class.parse_hosted_remote("ssh://git@codeberg.org/kettle-dev/kettle-paths.git"))
        .to eq(host: "codeberg.org", owner: "kettle-dev", repo: "kettle-paths")
      expect(described_class.parse_hosted_remote("/local/path/repo")).to be_nil
    end

    it "rewrites remote URLs while preserving scheme and .git suffix" do
      expect(described_class.rewrite_remote_url("git@github.com:pboling/kettle-paths.git", "kettle-dev", "kettle-paths"))
        .to eq("git@github.com:kettle-dev/kettle-paths.git")
      expect(described_class.rewrite_remote_url("https://github.com/pboling/kettle-paths", "kettle-dev", "kettle-paths"))
        .to eq("https://github.com/kettle-dev/kettle-paths")
      expect(described_class.rewrite_remote_url("git+ssh://git@github.com/pboling/kettle-paths.git", "kettle-dev", "kettle-paths"))
        .to eq("git+ssh://git@github.com/kettle-dev/kettle-paths.git")
    end
  end

  describe ".inspect_family" do
    it "flags a member whose origin org disagrees with the family majority and gemspec" do
      config = build_config
      members = [
        create_git_member("alpha", origin: "git@github.com:kettle-dev/alpha.git"),
        create_git_member("beta", origin: "git@github.com:kettle-dev/beta.git"),
        create_git_member(
          "kettle-paths",
          origin: "git@github.com:pboling/kettle-paths.git",
          gemspec_homepage: "https://github.com/kettle-dev/kettle-paths"
        )
      ]

      inspection = described_class.inspect_family(config: config, members: members)

      expect(inspection[:expected_org_by_host]).to eq("github.com" => "kettle-dev")
      expect(inspection[:members]["alpha"][:issues]).to be_empty
      expect(inspection[:members]["beta"][:issues]).to be_empty
      expect(inspection[:members]["kettle-paths"][:origin_org]).to eq("pboling")
      expect(inspection[:members]["kettle-paths"][:issues]).to contain_exactly(
        include(
          "remote" => "origin",
          "owner" => "pboling",
          "expected_org" => "kettle-dev",
          "recommended_command" => "git remote set-url origin git@github.com:kettle-dev/kettle-paths.git"
        )
      )
    end

    it "honors remotes.allowed_orgs for intentional multi-org families" do
      config = build_config(<<~YAML)
        remotes:
          expected_org: kettle-dev
          allowed_orgs:
            - pboling
      YAML
      member = create_git_member("personal", origin: "git@github.com:pboling/personal.git")

      inspection = described_class.inspect_family(config: config, members: [member])
      expect(inspection[:members]["personal"][:issues]).to be_empty
    end
  end

  describe ".call (preflight)" do
    it "auto-fixes a confirmed permanent GitHub redirect under execute: true" do
      config = build_config
      alpha = create_git_member("alpha", origin: "git@github.com:kettle-dev/alpha.git")
      beta = create_git_member("beta", origin: "git@github.com:kettle-dev/beta.git")
      stale = create_git_member("kettle-paths", origin: "git@github.com:pboling/kettle-paths.git")
      probe = ->(owner:, repo:) {
        if owner == "pboling" && repo == "kettle-paths"
          {status: :redirect, canonical_owner: "kettle-dev", canonical_repo: "kettle-paths", code: 301}
        else
          {status: :ok, canonical_owner: owner, canonical_repo: repo}
        end
      }

      result = described_class.call(config: config, members: [alpha, beta, stale], execute: true, probe: probe)

      expect(result).to be_ok
      expect(result.skipped).to be(false)
      expect(result.stdout).to include("updated redirected remote 'origin' from pboling/kettle-paths to kettle-dev/kettle-paths")
      updated_url, _err, _st = Open3.capture3("git", "remote", "get-url", "origin", chdir: stale.root)
      expect(updated_url.strip).to eq("git@github.com:kettle-dev/kettle-paths.git")
    end

    it "fails preflight in read-only mode on a confirmed permanent redirect with the exact fix hint" do
      config = build_config
      alpha = create_git_member("alpha", origin: "git@github.com:kettle-dev/alpha.git")
      beta = create_git_member("beta", origin: "git@github.com:kettle-dev/beta.git")
      stale = create_git_member("kettle-paths", origin: "git@github.com:pboling/kettle-paths.git")
      probe = ->(owner:, repo:) { {status: :redirect, canonical_owner: "kettle-dev", canonical_repo: repo, code: 301} }

      result = described_class.call(config: config, members: [alpha, beta, stale], execute: false, probe: probe)

      expect(result).not_to be_ok
      expect(result.stderr).to include("kettle-family fix-remotes --execute", "git remote set-url origin git@github.com:kettle-dev/kettle-paths.git")
    end

    it "fails preflight on HTTP 404" do
      config = build_config
      alpha = create_git_member("alpha", origin: "git@github.com:kettle-dev/alpha.git")
      beta = create_git_member("beta", origin: "git@github.com:kettle-dev/beta.git")
      broken = create_git_member("ghost", origin: "git@github.com:pboling/ghost.git")
      probe = ->(owner:, repo:) { {status: :not_found} }

      result = described_class.call(config: config, members: [alpha, beta, broken], execute: true, probe: probe)

      expect(result).not_to be_ok
      expect(result.stderr).to include("HTTP 404")
    end

    it "does not block or rewrite an intentional different-org repo when GitHub returns 200 and no explicit org is configured" do
      config = build_config
      alpha = create_git_member("alpha", origin: "git@github.com:kettle-dev/alpha.git")
      beta = create_git_member("beta", origin: "git@github.com:kettle-dev/beta.git")
      other = create_git_member("other", origin: "git@github.com:other-org/other.git")
      probe = ->(owner:, repo:) { {status: :ok, canonical_owner: owner, canonical_repo: repo} }

      result = described_class.call(config: config, members: [alpha, beta, other], execute: true, probe: probe)

      expect(result).to be_ok
      expect(result.skipped).to be(true)
      url, _err, _st = Open3.capture3("git", "remote", "get-url", "origin", chdir: other.root)
      expect(url.strip).to eq("git@github.com:other-org/other.git")
    end

    it "fails preflight when explicit family.org policy is violated even without a redirect" do
      config = build_config(<<~YAML)
        remotes:
          expected_org: kettle-dev
      YAML
      other = create_git_member("other", origin: "git@github.com:other-org/other.git")
      probe = ->(owner:, repo:) { {status: :ok, canonical_owner: owner, canonical_repo: repo} }

      result = described_class.call(config: config, members: [other], execute: true, probe: probe)

      expect(result).not_to be_ok
      expect(result.stderr).to include("does not match configured org 'kettle-dev'")
    end
  end

  describe ".fix (fix-remotes)" do
    it "plans remote updates in dry-run mode without mutating git config" do
      config = build_config
      alpha = create_git_member("alpha", origin: "git@github.com:kettle-dev/alpha.git")
      beta = create_git_member("beta", origin: "git@github.com:kettle-dev/beta.git")
      stale = create_git_member("kettle-paths", origin: "git@github.com:pboling/kettle-paths.git")
      probe = ->(owner:, repo:) { {status: :redirect, canonical_owner: "kettle-dev", canonical_repo: repo, code: 301} }

      results = described_class.fix(config: config, members: [alpha, beta, stale], execute: false, probe: probe)

      stale_result = results.find { |r| r.member_name == "kettle-paths" }
      expect(stale_result).to be_ok
      expect(stale_result.skipped).to be(true)
      expect(stale_result.stdout).to include("git remote set-url origin git@github.com:kettle-dev/kettle-paths.git")
      url, _err, _st = Open3.capture3("git", "remote", "get-url", "origin", chdir: stale.root)
      expect(url.strip).to eq("git@github.com:pboling/kettle-paths.git")
    end

    it "applies confirmed redirect updates under execute: true" do
      config = build_config
      alpha = create_git_member("alpha", origin: "git@github.com:kettle-dev/alpha.git")
      beta = create_git_member("beta", origin: "git@github.com:kettle-dev/beta.git")
      stale = create_git_member("kettle-paths", origin: "git@github.com:pboling/kettle-paths.git")
      probe = ->(owner:, repo:) { {status: :redirect, canonical_owner: "kettle-dev", canonical_repo: repo, code: 301} }

      results = described_class.fix(config: config, members: [alpha, beta, stale], execute: true, probe: probe)

      stale_result = results.find { |r| r.member_name == "kettle-paths" }
      expect(stale_result).to be_ok
      expect(stale_result.skipped).to be(false)
      expect(stale_result.reason).to eq("updated redirected remote(s)")
      url, _err, _st = Open3.capture3("git", "remote", "get-url", "origin", chdir: stale.root)
      expect(url.strip).to eq("git@github.com:kettle-dev/kettle-paths.git")
    end
  end

  describe ".probe_github_repo_http" do
    it "follows HTTP 301 redirect and reports canonical owner/repo" do
      redirect = Net::HTTPMovedPermanently.new("1.1", "301", "Moved Permanently")
      redirect["location"] = "https://api.github.com/repositories/1405940447"
      ok = Net::HTTPOK.new("1.1", "200", "OK")
      allow(ok).to receive(:body).and_return(JSON.dump("full_name" => "kettle-dev/kettle-paths"))
      responses = [redirect, ok]
      http = instance_double(Net::HTTP)
      allow(http).to receive(:request) { responses.shift }
      allow(Net::HTTP).to receive(:start).and_yield(http)

      probe = described_class.probe_github_repo_http(owner: "pboling", repo: "kettle-paths", token: "tok")

      expect(probe).to eq(status: :redirect, canonical_owner: "kettle-dev", canonical_repo: "kettle-paths", code: 301)
    end

    it "returns :not_found on HTTP 404" do
      not_found = Net::HTTPNotFound.new("1.1", "404", "Not Found")
      allow(Net::HTTP).to receive(:start).and_return(not_found)

      probe = described_class.probe_github_repo_http(owner: "missing", repo: "nope")

      expect(probe[:status]).to eq(:not_found)
    end
  end
end
