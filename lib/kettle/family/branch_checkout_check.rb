# frozen_string_literal: true

require "open3"

module Kettle
  module Family
    # Family-level preflight: bundle- and history-mutating commands run from
    # branches the family expects, or stop before any member is touched.
    #
    # Why this gate exists: template_sync rebases whatever branch is checked
    # out onto the default branch, and local sibling wiring resolves sibling
    # gems from their CHECKED-OUT branches — so a member parked on the wrong
    # branch turns into wrong-branch commits, or into an unresolvable bundle
    # when a sibling sits on a maintenance lane (a member requiring
    # `oauth2 ~> 2.0` against an oauth2 checkout on 1-4-stable providing
    # 1.4.12). Both surface here as named preflight failures with the remedy,
    # instead of mid-run Bundler errors or commits on the wrong branch.
    #
    # Expected branches per member: the repo's default branch (origin/HEAD),
    # plus configured release/stack lanes (family `release.member_target_branches`,
    # member-local `release.target_branches`, and `branch_lanes`), plus any
    # `--branch MEMBER:BRANCH` override.
    #
    # Sibling satisfiability is only checked when local sibling wiring is
    # active (the family's local-path env toggle, or K_JEM_TEMPLATING); with
    # released gems the checkout versions are irrelevant.
    class BranchCheckoutCheck
      PHASE = "branch_checkout_check"

      # Gated commands. Release is deliberately absent: branch-stack release
      # flows check out their target lanes themselves, so the pre-existing
      # checkout is not the thing release mutates from.
      GATED_COMMANDS = %w[bump bup template].freeze

      FALSEY_ENV = %w[false 0 no off].freeze

      def self.gated?(command)
        GATED_COMMANDS.include?(command.to_s)
      end

      def self.call(config:, members:, overrides: {})
        new(config: config, members: members, overrides: overrides).call
      end

      def initialize(config:, members:, overrides: {})
        @config = config
        @members = members
        @overrides = overrides || {}
      end

      def call
        found = diagnostics
        CommandResult.new(
          member_name: config.family_name,
          phase: PHASE,
          command: ["internal", PHASE],
          workdir: config.root,
          status: found.empty? ? 0 : 1,
          success: found.empty?,
          stdout: found.map { |diagnostic| diagnostic.fetch("message") }.join("\n"),
          stderr: "",
          elapsed_seconds: 0.0,
          skipped: false,
          reason: found.empty? ? nil : "members checked out on unexpected branches",
          diagnostics: found
        )
      end

      private

      attr_reader :config, :members, :overrides

      def diagnostics
        members.flat_map { |member| member_diagnostics(member) }.compact
      end

      def member_diagnostics(member)
        [branch_diagnostic(member), *sibling_diagnostics(member)]
      end

      # nil when the member is not a git repo (nothing to enforce), when the
      # default branch cannot be determined (enforcement would be a guess),
      # or when the checkout is on an expected branch.
      def branch_diagnostic(member)
        current = current_branch(member.root)
        return nil unless current
        return detached_diagnostic(member) if current.empty?

        default = default_branch(member.root)
        return nil unless default

        expected = expected_branches(member, default)
        return nil if expected.include?(current)

        unexpected_branch_diagnostic(member, current, expected)
      end

      def expected_branches(member, default)
        branches = [default]
        branches.concat(stack_lanes(member))
        override = overrides[member.name]
        branches << override if override
        branches.uniq
      end

      # Configured lanes the member may legitimately be checked out on, from
      # both config key shapes (family member_target_branches and member-local
      # release.target_branches — see BranchTargetConfig), plus branch_lanes.
      def stack_lanes(member)
        lanes = Array(config.member_release_target_branches[member.name])
        release_config = BranchTargetConfig.member_release_config(member: member, config: config)
        lanes |= release_config.release_target_branches if release_config
        lane_branches = config.branch_lanes.values.select do |lane|
          Array(lane["members"]).include?(member.name)
        end.map { |lane| lane["branch"].to_s }
        lanes | lane_branches
      end

      def unexpected_branch_diagnostic(member, current, expected)
        {
          "kind" => "unexpected_branch",
          "member" => member.name,
          "root" => member.root,
          "current" => current,
          "expected" => expected,
          "message" => "#{member.name} is on branch #{current.inspect}, expected #{expected.join(" or ")}; " \
            "switch with `git -C #{member.root} switch #{expected.first}` " \
            "or allow the current branch with --branch #{member.name}:#{current}"
        }
      end

      def detached_diagnostic(member)
        default = default_branch(member.root)
        expected = default ? expected_branches(member, default) : []
        target = expected.empty? ? "the default branch" : expected.join(" or ")
        switch = expected.empty? ? "" : " (`git -C #{member.root} switch #{expected.first}`)"
        {
          "kind" => "detached_head",
          "member" => member.name,
          "root" => member.root,
          "message" => "#{member.name} is on a detached HEAD; switch to #{target}#{switch}"
        }
      end

      # Cross-member version satisfiability: a member's sibling runtime
      # requirements must be satisfiable from the siblings' checked-out
      # versions whenever local sibling wiring is active. With released gems
      # the registry resolves instead, and checkout versions are irrelevant.
      def sibling_diagnostics(member)
        return [] unless local_wiring_active?
        return [] unless member.gemspec_path && File.file?(member.gemspec_path)

        spec = load_gemspec(member)
        return [] unless spec

        siblings = all_members_by_name
        spec.runtime_dependencies.filter_map do |dependency|
          sibling = siblings[dependency.name]
          next unless sibling

          version = sibling_version(sibling)
          next unless version
          next if dependency.requirement.satisfied_by?(version)

          sibling_mismatch_diagnostic(member, sibling, dependency, version)
        end
      end

      def sibling_mismatch_diagnostic(member, sibling, dependency, version)
        sibling_branch = current_branch(sibling.root)
        {
          "kind" => "sibling_version_mismatch",
          "member" => member.name,
          "sibling" => sibling.name,
          "requirement" => dependency.requirement.to_s,
          "actual" => version.to_s,
          "message" => "#{member.name} requires #{dependency.name} #{dependency.requirement}, " \
            "but the #{sibling.name} checkout provides #{version}#{branch_note(sibling_branch)}; " \
            "switch #{sibling.name} to a branch carrying a matching version, or run with released gems"
        }
      end

      def branch_note(sibling_branch)
        " (branch #{sibling_branch.inspect})" if sibling_branch
      end

      def local_wiring_active?
        family_env = config.family_local_path_env_name
        truthy_env?(ENV.fetch("K_JEM_TEMPLATING", nil)) ||
          (family_env && truthy_env?(ENV.fetch(family_env, nil)))
      end

      def truthy_env?(value)
        return false if value.nil?

        !FALSEY_ENV.include?(value.to_s.strip.downcase)
      end

      # Every discovered family member by name — the sibling universe — not
      # only the selected members: a --only run still resolves the unselected
      # siblings' checkouts.
      def all_members_by_name
        @all_members_by_name ||= Discovery.new(config: config).members.to_h { |member| [member.name, member] }
      end

      def sibling_version(sibling)
        return nil if sibling.version.to_s.empty?

        Gem::Version.new(sibling.version)
      rescue ArgumentError
        nil
      end

      # Some gemspecs use root-relative loads (see MemberLoader). A gemspec
      # that cannot load returns nil from Gem::Specification.load (with a
      # warning), and the preflight simply skips it.
      def load_gemspec(member)
        # rubocop:disable ThreadSafety/DirChdir
        Dir.chdir(member.root) { Gem::Specification.load(member.gemspec_path) }
        # rubocop:enable ThreadSafety/DirChdir
      end

      # The repo's default branch: the origin/HEAD symref a clone sets, with
      # `git remote show origin` (the sync command's fallback) when the symref
      # is unset. nil when neither can answer — branch enforcement is skipped
      # rather than guessed.
      def default_branch(root)
        @default_branches ||= {}
        return @default_branches[root] if @default_branches.key?(root)

        @default_branches[root] = detect_default_branch(root)
      end

      def detect_default_branch(root)
        stdout, _stderr, status = Open3.capture3("git", "symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD", chdir: root)
        ref = status.success? ? stdout.strip.sub(%r{\Aorigin/}, "") : ""
        return ref unless ref.empty?

        stdout, _stderr, status = Open3.capture3("git", "remote", "show", "origin", chdir: root)
        return nil unless status.success?

        branch = stdout[/HEAD branch:\s*(\S+)/, 1]
        # "(unknown)" / ambiguity notices are placeholders, not branch names.
        branch&.start_with?("(") ? nil : branch
      rescue SystemCallError
        nil
      end

      # Current branch short name; "" on a detached HEAD, nil when the root
      # is not a git repo (or git cannot answer). Memoized per root — monorepo
      # members share one repo.
      def current_branch(root)
        @current_branches ||= {}
        return @current_branches[root] if @current_branches.key?(root)

        stdout, _stderr, status = Open3.capture3("git", "branch", "--show-current", chdir: root)
        @current_branches[root] = status.success? ? stdout.strip : nil
      rescue SystemCallError
        @current_branches[root] = nil
      end
    end
  end
end
