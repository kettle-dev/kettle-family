# frozen_string_literal: true

require "fileutils"
require "tmpdir"

RSpec.describe Kettle::Family::Config do
  around do |example|
    Dir.mktmpdir("kettle-family-config-spec") do |dir|
      @tmpdir = dir
      example.run
    end
  end

  it "loads default config values when no config file exists" do
    config = described_class.load(root: @tmpdir)

    expect(config.path).to be_nil
    expect(config.family_name).to eq(File.basename(@tmpdir))
    expect(config.family_local_path_env_name).to eq("#{File.basename(@tmpdir).gsub(/[^A-Za-z0-9]+/, "_").upcase}_DEV")
    expect(config.family_local_path_root).to eq(@tmpdir)
    expect(config.family_local_path_env).to eq(config.family_local_path_env_name => @tmpdir)
    expect(config.members_root).to eq(@tmpdir)
    expect(config.discover_members?).to be(true)
    expect(config.member_exclude_patterns).to eq([
      "vendor/**",
      "**/vendor/**",
      "tmp/**",
      "**/tmp/**",
      "spec/**",
      "**/spec/**",
      "test/**",
      "**/test/**"
    ])
    expect(config.order_mode).to eq("dependency")
    expect(config.order_hints).to be_empty
  end

  it "loads configured family local path environment" do
    File.write(File.join(@tmpdir, ".kettle-family.yml"), <<~YAML)
      family:
        name: ruby-oauth
        local_path_env: RUBY_OAUTH_DEV
        local_path_root: families/oauth
    YAML

    config = described_class.load(root: @tmpdir)

    expect(config.family_local_path_env_name).to eq("RUBY_OAUTH_DEV")
    expect(config.family_local_path_root).to eq(File.join(@tmpdir, "families", "oauth"))
    expect(config.family_local_path_env).to eq("RUBY_OAUTH_DEV" => File.join(@tmpdir, "families", "oauth"))
  end

  it "allows family local path environment injection to be disabled" do
    File.write(File.join(@tmpdir, ".kettle-family.yml"), <<~YAML)
      family:
        local_path_env: false
    YAML

    config = described_class.load(root: @tmpdir)

    expect(config.family_local_path_env_name).to be_nil
    expect(config.family_local_path_env).to eq({})
  end

  it "loads configured values and stringifies keys" do
    File.write(File.join(@tmpdir, ".kettle-family.yml"), <<~YAML)
      family:
        name: configured-family
        members_root: gems
      members:
        discover: false
        explicit:
          - root: alpha
        exclude:
          - "**/custom/**"
        order:
          mode: fixed
          hints:
            - alpha
    YAML

    config = described_class.load(root: @tmpdir)

    expect(config.family_name).to eq("configured-family")
    expect(config.members_root).to eq(File.join(@tmpdir, "gems"))
    expect(config.discover_members?).to be(false)
    expect(config.member_exclude_patterns).to eq([
      "vendor/**",
      "**/vendor/**",
      "tmp/**",
      "**/tmp/**",
      "spec/**",
      "**/spec/**",
      "test/**",
      "**/test/**",
      "**/custom/**"
    ])
    expect(config.explicit_members).to eq([{"root" => File.join(@tmpdir, "alpha")}])
    expect(config.order_mode).to eq("fixed")
    expect(config.order_hints).to eq(["alpha"])
  end

  it "loads an explicit config path" do
    File.write(File.join(@tmpdir, "family.yml"), "family:\n  name: explicit\n")

    config = described_class.load(root: @tmpdir, path: "family.yml")

    expect(config.path).to eq(File.join(@tmpdir, "family.yml"))
    expect(config.family_name).to eq("explicit")
  end

  it "falls back to members.root when family.members_root is absent" do
    File.write(File.join(@tmpdir, ".kettle-family.yml"), "members:\n  root: components\n")

    config = described_class.load(root: @tmpdir)

    expect(config.members_root).to eq(File.join(@tmpdir, "components"))
  end

  it "loads release target branches from release config" do
    File.write(File.join(@tmpdir, ".kettle-family.yml"), <<~YAML)
      release:
        target_branches:
          - r1_8-even-v0
          - r1_9-even-v2
    YAML

    config = described_class.load(root: @tmpdir)

    expect(config.release_target_branches).to eq(%w[r1_8-even-v0 r1_9-even-v2])
  end

  it "loads release target branches from branch aliases" do
    File.write(File.join(@tmpdir, ".kettle-family.yml"), <<~YAML)
      branches:
        release_targets:
          - r3_2-even-v24
    YAML

    config = described_class.load(root: @tmpdir)

    expect(config.release_target_branches).to eq(["r3_2-even-v24"])
  end

  it "loads member-specific release target branches from release config" do
    File.write(File.join(@tmpdir, ".kettle-family.yml"), <<~YAML)
      release:
        member_target_branches:
          alpha:
            - r1
            - r2
          beta:
            - main
    YAML

    config = described_class.load(root: @tmpdir)

    expect(config.member_release_target_branches).to eq(
      "alpha" => %w[r1 r2],
      "beta" => ["main"]
    )
  end

  it "resolves install local dependencies relative to the config file" do
    FileUtils.mkdir_p(File.join(@tmpdir, "config"))
    File.write(File.join(@tmpdir, "config", "family.yml"), <<~YAML)
      install:
        local_dependencies:
          - ../deps/token-resolver
          - path: /absolute/example
    YAML

    config = described_class.load(root: @tmpdir, path: "config/family.yml")

    expect(config.install_local_dependencies).to eq([
      File.join(@tmpdir, "deps", "token-resolver"),
      "/absolute/example"
    ])
  end

  it "defaults publish releases to kettle-release" do
    config = described_class.load(root: @tmpdir)

    expect(config.release_publish_command).to eq("bundle exec kettle-release")
  end

  it "enables release dependency floor updates by default" do
    config = described_class.load(root: @tmpdir)

    expect(config.release_auto_dependency_floors?).to be(true)
  end

  it "allows release dependency floor updates to be disabled" do
    File.write(File.join(@tmpdir, ".kettle-family.yml"), <<~YAML)
      release:
        auto_dependency_floors: false
    YAML

    config = described_class.load(root: @tmpdir)

    expect(config.release_auto_dependency_floors?).to be(false)
  end

  it "defaults release lockfile normalization to template normalization" do
    File.write(File.join(@tmpdir, ".kettle-family.yml"), <<~YAML)
      template:
        normalize_lockfiles: true
        normalize_lockfiles_command:
          - bundle
          - update
          - nomono
          - --bundler
    YAML

    config = described_class.load(root: @tmpdir)

    expect(config.release_normalize_lockfiles?).to be(true)
    expect(config.release_normalize_lockfiles_command).to eq(%w[bundle update nomono --bundler])
    expect(config.release_disable_local_path_env).to include(config.family_local_path_env_name, "SMORG_RB_DEV", "K_JEM_TEMPLATING")
  end

  it "allows release lockfile normalization overrides" do
    File.write(File.join(@tmpdir, ".kettle-family.yml"), <<~YAML)
      template:
        normalize_lockfiles: true
      release:
        normalize_lockfiles: false
        normalize_lockfiles_command: bundle lock
        disable_local_path_env:
          - CUSTOM_DEV
    YAML

    config = described_class.load(root: @tmpdir)

    expect(config.release_normalize_lockfiles?).to be(false)
    expect(config.release_normalize_lockfiles_command).to eq("bundle lock")
    expect(config.release_disable_local_path_env).to eq(["CUSTOM_DEV"])
  end

  it "loads configurable checks, shared changelog, and release env" do
    File.write(File.join(@tmpdir, ".kettle-family.yml"), <<~YAML)
      check:
        required_files:
          - Gemfile
          - Rakefile
        required_bins:
          - bin/rake
        root_required_files:
          - CHANGELOG.md
        member_required_dirs:
          - docs
        forbidden_tracked_member_dirs:
          - .github
        forbidden_tracked_member_dirs_except:
          - kettle-jem
        readme_links:
          CHANGELOG.md: CHANGELOG.md
      pre_release:
        image_url_skip_patterns:
          - https://assets.example.com/generated/*
      changelog:
        mode: root
        path: CHANGELOG.md
        version_file: gems/tree_haver/lib/tree_haver/version.rb
      family:
        name: configured-family
      release:
        env:
          KETTLE_RB_DEV: false
          TSLP_DEV: ""
        family_changelog:
          enabled: true
          command: bundle exec kettle-changelog
    YAML

    config = described_class.load(root: @tmpdir)

    expect(config.check_required_files).to eq(%w[Gemfile Rakefile])
    expect(config.check_required_bins).to eq(["bin/rake"])
    expect(config.check_root_required_files).to eq(["CHANGELOG.md"])
    expect(config.check_member_required_dirs).to eq(["docs"])
    expect(config.check_forbidden_tracked_member_dirs).to eq([".github"])
    expect(config.check_forbidden_tracked_member_dirs_except).to eq(["kettle-jem"])
    expect(config.check_readme_links).to eq("CHANGELOG.md" => "CHANGELOG.md")
    expect(config.pre_release_image_url_skip_patterns).to eq(["https://assets.example.com/generated/*"])
    expect(config.shared_changelog?).to be(true)
    expect(config.changelog_full_path(double(root: File.join(@tmpdir, "gems", "alpha")))).to eq(File.join(@tmpdir, "CHANGELOG.md"))
    expect(config.changelog_env).to eq(
      "K_CHANGELOG_GEM_NAME" => "configured-family",
      "K_CHANGELOG_VERSION_FILE" => "gems/tree_haver/lib/tree_haver/version.rb"
    )
    expect(config.release_env).to eq("KETTLE_RB_DEV" => "false", "TSLP_DEV" => "")
    expect(config.release_family_changelog?).to be(true)
    expect(config.release_family_changelog_command).to eq("bundle exec kettle-changelog")
  end
end
