# frozen_string_literal: true

require "json"
require "net/http"
require "open3"
require "uri"
require "kettle/dev"

module Kettle
  module Family
    # Family-level git remote hygiene check and redirect-verified fixer.
    #
    # Detects member git remotes whose org disagrees with:
    #   1. explicit config (`remotes.expected_org` or `family.org`, honoring
    #      `remotes.allowed_orgs`),
    #   2. the member's gemspec `homepage` / `source_code_uri` on the same host, or
    #   3. the family's majority org on that host (when >= 2 distinct git roots).
    #
    # Offline inspection (`inspect_family`) is read-only and makes zero network
    # requests so `kettle-family state` stays fast and side-effect-free.
    #
    # Authoritative probing (`call` / `fix`) checks flagged GitHub remotes via
    # `GET /repos/:owner/:repo` (following HTTP 301/302/307/308 redirects):
    #   * Confirmed permanent redirect (301/308): safe to auto-fix via
    #     `git remote set-url` under `execute: true` (preserving SSH vs HTTPS
    #     and `.git` suffix), or reported as a planned fix in dry-run mode.
    #   * HTTP 404: fails fast with remote URL / token guidance.
    #   * Unverified org mismatch (no redirect): fails only when an explicit
    #     `expected_org` policy is violated; never silently rewrites an
    #     intentional multi-org repo.
    class RemoteCheck
      PHASE = "remote_check"
      FIX_PHASE = "fix_remotes"
      GATED_COMMANDS = %w[release template sync push].freeze
      SUPPORTED_HOSTS = %w[github.com gitlab.com codeberg.org].freeze
      MAX_REDIRECTS = 5
      PERMANENT_REDIRECT_CODES = [301, 308].freeze

      def self.gated?(command)
        GATED_COMMANDS.include?(command.to_s)
      end

      def self.has_hosted_remotes?(members:, config: nil, **options)
        return true if config&.expected_org && !config.expected_org.to_s.empty?

        Array(members).any? do |member|
          !hosted_remotes_for(member.root).empty?
        end
      end

      def self.inspect_family(config:, members:, **options)
        new(config: config, members: members).inspect_family
      end

      def self.call(config:, members:, execute: false, verify_redirects: true, auto_fix: nil, probe: nil, **options)
        new(
          config: config,
          members: members,
          execute: execute,
          verify_redirects: verify_redirects,
          auto_fix: auto_fix.nil? ? execute : auto_fix,
          probe: probe
        ).call
      end

      def self.fix(config:, members:, execute: false, probe: nil, **options)
        new(
          config: config,
          members: members,
          execute: execute,
          verify_redirects: true,
          auto_fix: execute,
          probe: probe
        ).fix
      end

      def self.parse_hosted_remote(url)
        raw = url.to_s.strip
        return nil if raw.empty?

        SUPPORTED_HOSTS.each do |host|
          if raw =~ %r{\Agit@#{Regexp.escape(host)}:([^/]+)/([^/]+?)(?:\.git)?\z}
            return {host: host, owner: Regexp.last_match(1), repo: Regexp.last_match(2)}
          end

          begin
            uri = URI.parse(raw)
          rescue URI::InvalidURIError
            next
          end
          next unless uri.host == host

          path = uri.path.to_s.sub(%r{\A/}, "")
          owner, repo = path.split("/", 2)
          next if owner.to_s.empty? || repo.to_s.empty?

          return {host: host, owner: owner, repo: repo.sub(/\.git\z/, "")}
        end
        nil
      end

      def self.rewrite_remote_url(url, new_owner, new_repo)
        raw = url.to_s.strip
        suffix = raw.end_with?(".git") ? ".git" : ""
        parsed = parse_hosted_remote(raw)
        host = parsed ? parsed[:host] : "github.com"
        if raw.start_with?("git@#{host}:")
          "git@#{host}:#{new_owner}/#{new_repo}#{suffix}"
        elsif raw =~ %r{\A((?:git\+)?ssh://[^/]+/)}
          "#{Regexp.last_match(1)}#{new_owner}/#{new_repo}#{suffix}"
        else
          "https://#{host}/#{new_owner}/#{new_repo}#{suffix}"
        end
      end

      def self.hosted_remotes_for(root)
        return [] unless root && Dir.exist?(root)

        stdout, _stderr, status = Open3.capture3("git", "remote", "-v", chdir: root)
        return [] unless status.success?

        seen = {}
        stdout.each_line(chomp: true).each_with_object([]) do |line, list|
          match = line.match(/\A(\S+)\s+(\S+)\s+\(fetch\)\z/)
          next unless match

          remote_name = match[1]
          url = match[2]
          next if seen[remote_name]

          parsed = parse_hosted_remote(url)
          next unless parsed

          seen[remote_name] = true
          list << parsed.merge(remote: remote_name, url: url)
        end
      rescue SystemCallError
        []
      end

      def self.probe_github_repo(owner:, repo:, token: nil, **options)
        token ||= ENV["GITHUB_TOKEN"] || ENV["GH_TOKEN"]
        if Kettle::Dev::CIHelpers.respond_to?(:github_repo_info)
          begin
            info = Kettle::Dev::CIHelpers.github_repo_info(owner: owner, repo: repo, token: token)
            return {status: :unknown} unless info.is_a?(Hash)

            return classify_github_repo_info(owner: owner, repo: repo, info: info)
          rescue => error
            return {status: :not_found, message: error.message} if error.message.to_s.include?("404")

            return {status: :unknown, message: error.message}
          end
        end

        probe_github_repo_http(owner: owner, repo: repo, token: token)
      end

      def self.classify_github_repo_info(owner:, repo:, info:)
        full_name = info["full_name"].to_s
        new_owner, new_repo = full_name.split("/", 2)
        if info["redirected"] && !new_owner.to_s.empty? && !new_repo.to_s.empty? &&
            full_name.casecmp("#{owner}/#{repo}") != 0
          return {
            status: :redirect,
            canonical_owner: new_owner,
            canonical_repo: new_repo,
            code: Array(info["redirects"]).first&.fetch(:code, 301) || 301
          }
        end

        {status: :ok, canonical_owner: new_owner || owner, canonical_repo: new_repo || repo}
      end

      def self.probe_github_repo_http(owner:, repo:, token: nil)
        current_url = "https://api.github.com/repos/#{owner}/#{repo}"
        initial_host = URI(current_url).hostname
        permanent_code = nil

        (MAX_REDIRECTS + 1).times do
          uri = URI(current_url)
          req = Net::HTTP::Get.new(uri)
          req["User-Agent"] = "kettle-family/remote-check"
          req["Authorization"] = "token #{token}" if token && !token.empty? && uri.hostname == initial_host
          res = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) { |http| http.request(req) }

          if res.is_a?(Net::HTTPSuccess)
            data = JSON.parse(res.body)
            full_name = data["full_name"].to_s
            new_owner, new_repo = full_name.split("/", 2)
            if permanent_code && !new_owner.to_s.empty? && !new_repo.to_s.empty? &&
                full_name.casecmp("#{owner}/#{repo}") != 0
              return {status: :redirect, canonical_owner: new_owner, canonical_repo: new_repo, code: permanent_code}
            end

            return {status: :ok, canonical_owner: new_owner || owner, canonical_repo: new_repo || repo}
          elsif res.is_a?(Net::HTTPRedirection)
            location = res["location"] || res["Location"]
            return {status: :unknown} if location.to_s.empty?

            code = res.code.to_i
            permanent_code ||= code if PERMANENT_REDIRECT_CODES.include?(code)
            current_url = URI.join(current_url, location).to_s
            next
          elsif res.is_a?(Net::HTTPNotFound)
            return {status: :not_found, message: "GitHub repository #{owner}/#{repo} not found (HTTP 404)"}
          else
            return {status: :unknown}
          end
        end

        {status: :unknown}
      rescue => error
        {status: :unknown, message: error.message}
      end

      def initialize(config:, members:, execute: false, verify_redirects: true, auto_fix: false, probe: nil, **options)
        @config = config
        @members = Array(members)
        @execute = !!execute
        @verify_redirects = !!verify_redirects
        @auto_fix = !!auto_fix
        @probe = probe
        @remotes_by_root = {}
        @git_root_by_path = {}
      end

      def inspect_family
        member_remotes = {}
        member_git_roots = {}
        @members.each do |member|
          git_root = resolve_git_root(member.root)
          member_git_roots[member.name] = git_root
          member_remotes[member.name] = remotes_for_root(git_root)
        end

        expected_org_by_host = compute_expected_orgs(member_git_roots, member_remotes)
        allowed_orgs = allowed_org_set

        members_report = @members.each_with_object({}) do |member, report|
          remotes = member_remotes.fetch(member.name, [])
          gemspec_owners = gemspec_owners_by_host(member)
          origin = remotes.find { |entry| entry[:remote] == "origin" } || remotes.first
          issues = []

          remotes.each do |entry|
            issue = evaluate_remote_offline(
              entry: entry,
              expected_org_by_host: expected_org_by_host,
              gemspec_owners: gemspec_owners,
              allowed_orgs: allowed_orgs
            )
            issues << issue if issue
          end

          report[member.name] = {
            git_root: member_git_roots[member.name],
            remotes: remotes,
            origin_org: origin && origin[:owner],
            issues: issues
          }
        end

        {
          expected_org_by_host: expected_org_by_host,
          members: members_report
        }
      end

      def call
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        inspection = inspect_family
        fixed_lines = []
        blocking_lines = []
        diagnostics = []
        fixed_roots = {}

        @members.each do |member|
          info = inspection.fetch(:members).fetch(member.name)
          info.fetch(:issues).each do |issue|
            outcome = handle_issue(member: member, git_root: info[:git_root], issue: issue, fixed_roots: fixed_roots)
            next unless outcome

            diagnostics << outcome[:diagnostic]
            case outcome[:action]
            when :fixed
              fixed_lines << outcome[:message]
            when :error
              blocking_lines << outcome[:message]
            end
          end
        end

        elapsed = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).round(3)
        if blocking_lines.empty?
          return CommandResult.new(
            member_name: @config.family_name,
            phase: PHASE,
            command: ["internal", "remote-check"],
            workdir: @config.root,
            status: 0,
            success: true,
            stdout: fixed_lines.join("\n"),
            stderr: "",
            elapsed_seconds: elapsed,
            skipped: fixed_lines.empty?,
            reason: fixed_lines.empty? ? nil : "auto-fixed #{fixed_lines.length} redirected remote(s)",
            diagnostics: diagnostics
          )
        end

        CommandResult.new(
          member_name: @config.family_name,
          phase: PHASE,
          command: ["internal", "remote-check"],
          workdir: @config.root,
          status: 1,
          success: false,
          stdout: fixed_lines.join("\n"),
          stderr: blocking_lines.join("\n"),
          elapsed_seconds: elapsed,
          skipped: false,
          reason: "stale or mismatched git remote(s)",
          diagnostics: diagnostics
        )
      end

      def fix
        inspection = inspect_family
        fixed_roots = {}

        @members.map do |member|
          started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          info = inspection.fetch(:members).fetch(member.name)
          issues = info.fetch(:issues)
          if issues.empty?
            elapsed = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).round(3)
            next CommandResult.new(
              member_name: member.name,
              phase: FIX_PHASE,
              command: ["internal", "fix-remotes"],
              workdir: member.root,
              status: 0,
              success: true,
              stdout: "",
              stderr: "",
              elapsed_seconds: elapsed,
              skipped: true,
              reason: "remotes up to date"
            )
          end

          stdout_lines = []
          stderr_lines = []
          diagnostics = []
          ok = true
          skipped = true

          issues.each do |issue|
            outcome = handle_issue(member: member, git_root: info[:git_root], issue: issue, fixed_roots: fixed_roots, report_planned: true)
            next unless outcome

            diagnostics << outcome[:diagnostic]
            case outcome[:action]
            when :fixed
              stdout_lines << outcome[:message]
              skipped = false
            when :planned
              stdout_lines << outcome[:message]
            when :warning
              stdout_lines << outcome[:message]
            when :error
              stderr_lines << outcome[:message]
              ok = false
              skipped = false
            end
          end

          elapsed = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).round(3)
          reason = if !ok
            "remote check failed"
          elsif !skipped
            "updated redirected remote(s)"
          elsif !stdout_lines.empty?
            @execute ? "no redirected remotes to update" : "dry-run; planned remote update(s)"
          else
            "remotes up to date"
          end

          CommandResult.new(
            member_name: member.name,
            phase: FIX_PHASE,
            command: ["internal", "fix-remotes"],
            workdir: member.root,
            status: ok ? 0 : 1,
            success: ok,
            stdout: stdout_lines.join("\n"),
            stderr: stderr_lines.join("\n"),
            elapsed_seconds: elapsed,
            skipped: skipped,
            reason: reason,
            diagnostics: diagnostics
          )
        end
      end

      private

      def resolve_git_root(path)
        return path unless path && Dir.exist?(path)

        @git_root_by_path[path] ||= begin
          stdout, _stderr, status = Open3.capture3("git", "rev-parse", "--show-toplevel", chdir: path)
          (status.success? && !stdout.strip.empty?) ? stdout.strip : path
        rescue SystemCallError
          path
        end
      end

      def remotes_for_root(git_root)
        @remotes_by_root[git_root] ||= self.class.hosted_remotes_for(git_root)
      end

      def explicit_expected_org
        value = @config.respond_to?(:expected_org) ? @config.expected_org : nil
        value = value.to_s.strip
        value.empty? ? nil : value
      end

      def allowed_org_set
        orgs = @config.respond_to?(:allowed_remote_orgs) ? Array(@config.allowed_remote_orgs) : []
        orgs.map { |org| org.to_s.strip.downcase }.reject(&:empty?)
      end

      def compute_expected_orgs(member_git_roots, member_remotes)
        explicit = explicit_expected_org
        return SUPPORTED_HOSTS.each_with_object({}) { |host, map| map[host] = explicit } if explicit

        counts_by_host = Hash.new { |h, k| h[k] = Hash.new(0) }
        roots_seen_by_host = Hash.new { |h, k| h[k] = {} }

        member_remotes.each do |member_name, remotes|
          git_root = member_git_roots[member_name]
          remotes.each do |entry|
            next unless entry[:remote] == "origin" || remotes.none? { |r| r[:remote] == "origin" }

            host = entry[:host]
            next if roots_seen_by_host[host][git_root]

            roots_seen_by_host[host][git_root] = true
            counts_by_host[host][entry[:owner]] += 1
          end
        end

        counts_by_host.each_with_object({}) do |(host, owner_counts), map|
          total = owner_counts.values.sum
          next if total < 2

          leader, count = owner_counts.max_by { |_owner, c| c }
          map[host] = leader if count > (total / 2.0)
        end
      end

      def gemspec_owners_by_host(member)
        path = member.respond_to?(:gemspec_path) ? member.gemspec_path : nil
        return {} unless path && File.file?(path)

        content = File.read(path)
        owners = {}
        SUPPORTED_HOSTS.each do |host|
          match = content.match(%r{https?://#{Regexp.escape(host)}/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)})
          owners[host] = match[1] if match
        end
        owners
      rescue SystemCallError
        {}
      end

      def evaluate_remote_offline(entry:, expected_org_by_host:, gemspec_owners:, allowed_orgs:)
        owner = entry[:owner]
        host = entry[:host]
        return nil if allowed_orgs.include?(owner.downcase)

        explicit = explicit_expected_org
        expected = explicit || gemspec_owners[host] || expected_org_by_host[host]
        return nil unless expected
        return nil if owner.casecmp(expected).zero?

        reason = if explicit
          "remote org '#{owner}' does not match configured org '#{explicit}'"
        elsif gemspec_owners[host] && gemspec_owners[host].casecmp(owner) != 0
          "remote org '#{owner}' does not match gemspec org '#{gemspec_owners[host]}'"
        else
          "remote org '#{owner}' differs from family majority '#{expected}' on #{host}"
        end

        suggested_url = self.class.rewrite_remote_url(entry[:url], expected, entry[:repo])
        {
          "remote" => entry[:remote],
          "host" => host,
          "url" => entry[:url],
          "owner" => owner,
          "repo" => entry[:repo],
          "expected_org" => expected,
          "explicit" => !explicit.nil?,
          "reason" => reason,
          "recommended_command" => "git remote set-url #{entry[:remote]} #{suggested_url}"
        }
      end

      def handle_issue(member:, git_root:, issue:, fixed_roots:, report_planned: false)
        remote = issue.fetch("remote")
        host = issue.fetch("host")
        url = issue.fetch("url")
        owner = issue.fetch("owner")
        repo = issue.fetch("repo")
        explicit = issue.fetch("explicit")

        probe_result = if @verify_redirects && host == "github.com"
          probe_github(owner: owner, repo: repo)
        else
          {status: :unknown}
        end

        case probe_result[:status]
        when :redirect
          canonical_owner = probe_result.fetch(:canonical_owner)
          canonical_repo = probe_result.fetch(:canonical_repo)
          canonical_url = self.class.rewrite_remote_url(url, canonical_owner, canonical_repo)
          fix_cmd = "git remote set-url #{remote} #{canonical_url}"
          key = [git_root, remote]

          if @auto_fix
            unless fixed_roots[key]
              ok, err = apply_remote_set_url(git_root: git_root, remote: remote, canonical_url: canonical_url)
              unless ok
                msg = "#{member.name}: failed to update redirected remote '#{remote}' (#{owner}/#{repo} -> #{canonical_owner}/#{canonical_repo}): #{err}"
                return {
                  action: :error,
                  message: msg,
                  diagnostic: issue.merge("status" => "fix_failed", "canonical_url" => canonical_url, "message" => msg)
                }
              end
              fixed_roots[key] = true
            end
            msg = "#{member.name}: updated redirected remote '#{remote}' from #{owner}/#{repo} to #{canonical_owner}/#{canonical_repo} (#{canonical_url})"
            return {
              action: :fixed,
              message: msg,
              diagnostic: issue.merge("status" => "fixed", "canonical_url" => canonical_url, "recommended_command" => fix_cmd, "message" => msg)
            }
          end

          msg = "#{member.name}: remote '#{remote}' (#{owner}/#{repo}) permanently redirected to #{canonical_owner}/#{canonical_repo}; run `kettle-family fix-remotes --execute` or `#{fix_cmd}`"
          {
            action: report_planned ? :planned : :error,
            message: msg,
            diagnostic: issue.merge("status" => "redirect", "canonical_url" => canonical_url, "recommended_command" => fix_cmd, "message" => msg)
          }
        when :not_found
          msg = "#{member.name}: remote '#{remote}' (#{url}) returned HTTP 404; check repository URL/access or run `#{issue.fetch("recommended_command")}`"
          {
            action: :error,
            message: msg,
            diagnostic: issue.merge("status" => "not_found", "message" => msg)
          }
        else
          if explicit
            msg = "#{member.name}: #{issue.fetch("reason")} (#{url}); run `#{issue.fetch("recommended_command")}`"
            return {
              action: :error,
              message: msg,
              diagnostic: issue.merge("status" => "org_mismatch", "message" => msg)
            }
          end

          if report_planned
            msg = "#{member.name}: #{issue.fetch("reason")} (no permanent redirect detected; left untouched — run `#{issue.fetch("recommended_command")}` manually if intended)"
            return {
              action: :warning,
              message: msg,
              diagnostic: issue.merge("status" => "org_mismatch", "message" => msg)
            }
          end

          nil
        end
      end

      def probe_github(owner:, repo:)
        return @probe.call(owner: owner, repo: repo) if @probe

        self.class.probe_github_repo(owner: owner, repo: repo)
      end

      def apply_remote_set_url(git_root:, remote:, canonical_url:)
        _stdout, stderr, status = Open3.capture3("git", "remote", "set-url", remote, canonical_url, chdir: git_root)
        [status.success?, stderr.strip]
      rescue SystemCallError => error
        [false, error.message]
      end
    end
  end
end
