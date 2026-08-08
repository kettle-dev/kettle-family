# frozen_string_literal: true

require "json"
require "etc"
require "fileutils"
require "open3"
require "rbconfig"
require "rubygems"
require "securerandom"
require "yaml"

module Kettle
  module Family
    class ReleaseStateCheck
      KETTLE_JEM_STATE_PATHS = [
        ".structuredmerge/kettle-jem.lock",
        ".kettle-jem.lock",
        ".structuredmerge/kettle-jem.yml",
        ".kettle-jem.yml"
      ].freeze
      TRANSFER_CHANGELOG_TOTAL_UNSET = Object.new.freeze
      CACHE_MISS = Object.new.freeze

      def initialize(members:, config: nil, jobs: nil)
        @members = members
        @config = config
        @jobs = jobs
        @github_latest_release_by_repo = {}
        @transfer_changelog_status_by_root = {}
        @transfer_changelog_lag_by_key = {}
        @transfer_changelog_total_count = TRANSFER_CHANGELOG_TOTAL_UNSET
        @cache_mutex = Mutex.new
        @transfer_changelog_total_mutex = Mutex.new
      end

      def results(event_handler: nil)
        return branch_results(event_handler: event_handler) unless release_target_branches.empty?
        if shared_changelog?
          results = parallel_map(members) { |member| check_shared_changelog_member_or_local(member, event_handler: event_handler) }
          return normalize_shared_version_bump(results)
        end

        member_results = parallel_map(members) do |member|
          member_branch_results = member_local_branch_results(member, event_handler: event_handler)
          member_branch_results || check_member(member, event_handler: event_handler)
        end
        member_results.flat_map { |result| Array(result) }
      end

      private

      attr_reader :members, :config, :jobs

      def branch_results(event_handler: nil)
        root = git_root
        selected_names = members.map(&:name)
        release_target_branches.each_with_object([]) do |branch, memo|
          with_branch_worktree(root: root, branch: branch) do |worktree_root|
            branch_members = discover_branch_members(worktree_root: worktree_root, selected_names: selected_names)
            if shared_changelog?
              results = parallel_map(branch_members) { |member| check_shared_changelog_member_or_local(member, branch: branch, event_handler: event_handler) }
              memo.concat(normalize_shared_version_bump(results))
              next
            end

            memo.concat(parallel_map(branch_members) { |member| check_member(member, branch: branch, event_handler: event_handler) })
          end
        rescue Error => error
          memo << error_result(branch: branch, error: error)
        end
      end

      def check_member(member, branch: nil, event_handler: nil)
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        command = release_state_command
        emit_event(event_handler, member: member, branch: branch, action: "member_start", status: "running", command: command)
        emit_event(event_handler, member: member, branch: branch, action: "changelog_command", status: "running", command: command)
        stdout, stderr, status = Open3.capture3(release_state_env(member), *command, chdir: release_state_workdir(member))
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
        success = status.success?
        emit_event(event_handler, member: member, branch: branch, action: "changelog_command", status: success ? "ok" : "failed", elapsed_seconds: elapsed, status_code: status.exitstatus)
        state = success ? JSON.parse(stdout) : {}
        emit_event(event_handler, member: member, branch: branch, action: "computed_booleans", status: "running") if success
        state = branch_filtered_state(member, state, branch) if success && branch
        state = state_with_computed_booleans(state) if success
        emit_event(event_handler, member: member, branch: branch, action: "computed_booleans", status: "ok") if success
        emit_event(event_handler, member: member, branch: branch, action: "git_state", status: "running") if success
        state = enrich_git_state(member.root, state, branch: branch) if success
        emit_event(event_handler, member: member, branch: branch, action: "git_state", status: "ok") if success
        emit_event(event_handler, member: member, branch: branch, action: "github_release", status: "running") if success
        state = enrich_github_release(member.root, state, branch: branch) if success
        emit_event(event_handler, member: member, branch: branch, action: "github_release", status: "ok") if success
        emit_event(event_handler, member: member, branch: branch, action: "transfer_changelog", status: "running") if success
        state = enrich_transfer_changelog_lag(member.root, state) if success
        emit_event(event_handler, member: member, branch: branch, action: "transfer_changelog", status: "ok") if success
        result = result(member: member, command: command, stdout: stdout, stderr: stderr, status: status.exitstatus, elapsed: elapsed, success: success, state: state, branch: branch)
        emit_event(event_handler, member: member, branch: branch, action: "member_complete", status: success ? "ok" : "failed", elapsed_seconds: elapsed, status_code: status.exitstatus)
        result
      rescue JSON::ParserError => error
        result = result(member: member, command: command || release_state_command, stdout: stdout, stderr: stderr, status: 1, elapsed: elapsed || 0.0, success: false, state: {}, reason: "invalid release-state JSON: #{error.message}", branch: branch)
        emit_event(event_handler, member: member, branch: branch, action: "member_complete", status: "failed", elapsed_seconds: elapsed || 0.0, status_code: 1, reason: result.reason)
        result
      end

      def release_state_command
        [RbConfig.ruby, "-S", "kettle-changelog", "--release-state", "--json"]
      end

      def check_shared_changelog_member_or_local(member, branch: nil, event_handler: nil)
        return check_member(member, branch: branch, event_handler: event_handler) if member_local_changelog?(member)

        check_shared_changelog_member(member, branch: branch, event_handler: event_handler)
      end

      def check_shared_changelog_member(member, branch: nil, event_handler: nil)
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        command = release_state_command
        emit_event(event_handler, member: member, branch: branch, action: "member_start", status: "running", command: command)
        emit_event(event_handler, member: member, branch: branch, action: "changelog_command", status: "running", command: command)
        stdout, stderr, status = Open3.capture3(shared_changelog_env(member), *command, chdir: config.root)
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
        success = status.success?
        emit_event(event_handler, member: member, branch: branch, action: "changelog_command", status: success ? "ok" : "failed", elapsed_seconds: elapsed, status_code: status.exitstatus)
        state = success ? JSON.parse(stdout) : {}
        state = state_with_computed_booleans(state) if success
        state = branch_filtered_state(member, state, branch) if success && branch
        emit_event(event_handler, member: member, branch: branch, action: "git_state", status: "running") if success
        state = enrich_git_state(member.root, state, branch: branch) if success
        emit_event(event_handler, member: member, branch: branch, action: "git_state", status: "ok") if success
        emit_event(event_handler, member: member, branch: branch, action: "github_release", status: "running") if success
        state = enrich_github_release(member.root, state, branch: branch) if success
        emit_event(event_handler, member: member, branch: branch, action: "github_release", status: "ok") if success
        emit_event(event_handler, member: member, branch: branch, action: "transfer_changelog", status: "running") if success
        state = enrich_transfer_changelog_lag(member.root, state) if success
        emit_event(event_handler, member: member, branch: branch, action: "transfer_changelog", status: "ok") if success
        result = result(
          member: member,
          command: command,
          stdout: stdout,
          stderr: stderr,
          status: status.exitstatus,
          elapsed: elapsed,
          success: success,
          state: state,
          branch: branch
        )
        emit_event(event_handler, member: member, branch: branch, action: "member_complete", status: success ? "ok" : "failed", elapsed_seconds: elapsed, status_code: status.exitstatus)
        result
      rescue JSON::ParserError => error
        result = result(member: member, command: command || release_state_command, stdout: stdout, stderr: stderr, status: 1, elapsed: elapsed || 0.0, success: false, state: {}, reason: "invalid release-state JSON: #{error.message}", branch: branch)
        emit_event(event_handler, member: member, branch: branch, action: "member_complete", status: "failed", elapsed_seconds: elapsed || 0.0, status_code: 1, reason: result.reason)
        result
      rescue Error => error
        result = result(
          member: member,
          command: command || release_state_command,
          stdout: "",
          stderr: error.message,
          status: 1,
          elapsed: 0.0,
          success: false,
          state: {},
          reason: "release state check failed",
          branch: branch
        )
        emit_event(event_handler, member: member, branch: branch, action: "member_complete", status: "failed", elapsed_seconds: elapsed || 0.0, status_code: 1, reason: result.reason)
        result
      end

      def release_state_workdir(member)
        return member.root unless config
        return config.root if config.shared_changelog? && !member_local_changelog?(member)

        config.changelog_workdir(member) || member.root
      end

      def release_state_env(member = nil)
        return member_changelog_env(member) if member && shared_changelog? && member_local_changelog?(member)

        config ? config.changelog_env : {}
      end

      def shared_changelog_env(member)
        env = release_state_env(member).merge("K_CHANGELOG_GEM_NAME" => member.name.to_s)
        env["K_CHANGELOG_VERSION_FILE"] = member.version_file.to_s if member.version_file
        env
      end

      def member_changelog_env(member)
        env = {"K_CHANGELOG_GEM_NAME" => member.name.to_s}
        env["K_CHANGELOG_VERSION_FILE"] = member.version_file.to_s if member.version_file
        env
      end

      def member_local_changelog?(member)
        File.file?(File.join(member.root, "CHANGELOG.md"))
      end

      def branch_filtered_state(member, state, _branch)
        latest_released = branch_latest_released(member, state["latest_changelog_version"])
        return state unless latest_released

        state.merge(
          "latest_released" => latest_released,
          "ahead" => commits_ahead_of_release(member.root, latest_released)
        )
      rescue ArgumentError
        state
      end

      def branch_latest_released(member, line_version)
        target_major = gem_version(line_version).segments.first
        versions = release_tag_versions(member.root).select do |version|
          version.segments.first == target_major
        end
        versions.max&.to_s
      end

      def release_tag_versions(root)
        stdout, stderr, status = Open3.capture3("git", "tag", "--list", "v*", chdir: root)
        raise Error, "could not list release tags for #{root}: #{stderr}" unless status.success?

        stdout.lines.each_with_object([]) do |line, memo|
          tag = line.strip
          next unless tag.start_with?("v")

          begin
            memo << gem_version(tag.delete_prefix("v"))
          rescue ArgumentError
            nil
          end
        end
      end

      def gem_version(value)
        raise ArgumentError, "missing version" if value.to_s.empty?

        Gem::Version.new(value)
      end

      def commits_ahead_of_release(root, version)
        tag = release_tag_for_version(root, version)
        return nil unless tag && git_ref_exists?(root, "HEAD")

        stdout, _stderr, status = Open3.capture3("git", "rev-list", "--count", "#{tag}..HEAD", chdir: root)
        status.success? ? stdout.to_i : nil
      end

      def release_tag_for_version(root, version)
        return nil if version.to_s.empty?

        ["v#{version}", version.to_s].find { |tag| git_ref_exists?(root, "refs/tags/#{tag}^{commit}") }
      end

      def git_ref_exists?(root, ref)
        _stdout, _stderr, status = Open3.capture3("git", "rev-parse", "--verify", "--quiet", ref, chdir: root)
        status.success?
      end

      def enrich_git_state(root, state, branch: nil)
        return state unless git_work_tree?(root)

        enriched = state.dup
        current_branch = branch || git_output(root, "branch", "--show-current")
        enriched["current_branch"] = current_branch unless current_branch.to_s.empty?

        version = state["latest_released"].to_s.empty? ? state["latest_changelog_version"] : state["latest_released"]
        return enriched if version.to_s.empty?

        local_ref = branch || default_branch(root)
        if local_ref
          enriched["default_branch"] = local_ref
          if (counts = release_counts_for_ref(root, version, local_ref))
            enriched["behind"] = counts.fetch(:behind)
            enriched["ahead"] = counts.fetch(:ahead)
          end
        end

        remote_ref = branch ? "origin/#{branch}" : remote_default_branch(root, local_ref)
        if remote_ref && git_ref_exists?(root, "refs/remotes/#{remote_ref}")
          enriched["remote_default_branch"] = remote_ref
          if (counts = release_counts_for_ref(root, version, remote_ref))
            enriched["remote_behind"] = counts.fetch(:behind)
            enriched["remote_ahead"] = counts.fetch(:ahead)
          end
        end

        enriched
      end

      def git_work_tree?(root)
        _stdout, _stderr, status = Open3.capture3("git", "rev-parse", "--is-inside-work-tree", chdir: root)
        status.success?
      end

      def default_branch(root)
        remote_default = remote_default_branch(root)
        branch = remote_default&.delete_prefix("origin/")
        return branch if branch && git_ref_exists?(root, "refs/heads/#{branch}")

        %w[main master].find { |name| git_ref_exists?(root, "refs/heads/#{name}") }
      end

      def remote_default_branch(root, local_default = nil)
        symbolic = git_output(root, "symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD")
        return symbolic if symbolic&.start_with?("origin/")

        "origin/#{local_default}" if local_default && git_ref_exists?(root, "refs/remotes/origin/#{local_default}")
      end

      def release_counts_for_ref(root, version, ref)
        tag = release_tag_for_version(root, version)
        return nil unless tag && git_ref_exists?(root, ref)

        stdout = git_output(root, "rev-list", "--left-right", "--count", "#{tag}...#{ref}")
        parts = stdout.to_s.split
        return nil unless parts.length == 2 && parts.all? { |part| part.match?(/\A\d+\z/) }

        {behind: parts.fetch(0).to_i, ahead: parts.fetch(1).to_i}
      end

      def git_output(root, *args)
        stdout, _stderr, status = Open3.capture3("git", *args, chdir: root)
        status.success? ? stdout.strip : nil
      end

      def family_changelog_state(root)
        changelog = File.expand_path(config.changelog_path, root)
        raise Error, "missing root changelog #{config.changelog_path}" unless File.file?(changelog)

        version = root_changelog_version(root)
        content = File.read(changelog)
        latest_changelog_version = latest_changelog_version(content)
        unreleased_entries = unreleased_entries?(content)
        prepared_release_pending = !version.to_s.empty? && latest_changelog_version == version
        ahead = commits_ahead_of_release(root, latest_changelog_version)
        state = enrich_github_release(root, state_with_computed_booleans(enrich_git_state(root, {
          "gem_name" => config.family_name,
          "version" => version,
          "latest_released" => nil,
          "latest_changelog_version" => latest_changelog_version,
          "ahead" => ahead,
          "unreleased_entries" => unreleased_entries,
          "prepared_release_pending" => prepared_release_pending,
          "pending_release" => unreleased_entries || prepared_release_pending
        })))
        enrich_transfer_changelog_lag(root, state)
      end

      def state_with_computed_booleans(state)
        enriched = state.dup
        enriched["bump_release_pending"] = bump_release_pending?(enriched)
        enriched
      end

      def bump_release_pending?(state)
        state["unreleased_entries"] == true && state["version"].to_s == state["latest_released"].to_s
      end

      def enrich_github_release(root, state, branch: nil)
        tag = branch ? github_release_for_version(root, state["latest_released"]) : github_latest_release(root)
        return state unless tag

        state.merge("github_latest_release" => tag)
      end

      def github_release_for_version(root, version)
        return nil if version.to_s.empty?

        repo = github_repo_slug(root)
        return nil unless repo

        tag = "v#{version.to_s.delete_prefix("v")}"
        stdout, _stderr, status = Open3.capture3("gh", "release", "view", tag, "--repo", repo, "--json", "tagName", "--jq", ".tagName")
        status.success? ? normalize_github_release_tag(stdout) : nil
      rescue SystemCallError
        nil
      end

      def enrich_transfer_changelog_lag(root, state)
        kettle_jem_state = kettle_jem_config_state(root)
        return state unless kettle_jem_state

        status = transfer_changelog_status(root)
        if status
          total = status.key?("total_count") ? status.fetch("total_count") : transfer_changelog_total_count
          return state.merge(
            "transfer_changelog_lag" => status.fetch("missing_count", 0).to_i,
            "transfer_changelog_applicable" => status.fetch("applicable_count", 0).to_i,
            "transfer_changelog_excluded_present" => status.fetch("excluded_present_count", 0).to_i,
            "transfer_changelog_total" => total.to_i
          )
        end

        # Compatibility with already released kettle-jem versions while a
        # workspace is upgraded. New versions use the context-aware status API.
        replay = kettle_jem_state["changelog_replay"]
        replay = replay.is_a?(Hash) ? replay : {}
        last_entry_key = replay["last_entry_key"] || replay[:last_entry_key]
        lag = transfer_changelog_lag(last_entry_key)
        return state unless lag

        state.merge(
          "transfer_changelog_lag" => lag.fetch("missing_count", 0).to_i,
          "transfer_changelog_total" => transfer_changelog_total_count
        )
      end

      def kettle_jem_config_state(root)
        path = KETTLE_JEM_STATE_PATHS.map { |relative| File.join(root.to_s, relative) }.find { |candidate| File.file?(candidate) }
        return nil unless path

        data = YAML.safe_load_file(path, permitted_classes: [], aliases: false)
        state = kettle_jem_state_from_yaml(data)
        state.is_a?(Hash) ? state : {}
      rescue Psych::Exception, SystemCallError
        nil
      end

      def kettle_jem_state_from_yaml(data)
        return nil unless data.is_a?(Hash)

        data["template_state"] || data["kettle-jem"]
      end

      def transfer_changelog_lag(last_entry_key)
        cache_key = last_entry_key.to_s
        cached_value(@transfer_changelog_lag_by_key, cache_key) do
          in_process_transfer_changelog_lag(last_entry_key) || external_transfer_changelog_lag(cache_key)
        end
      rescue
        nil
      end

      def transfer_changelog_status(root)
        cache_key = File.expand_path(root.to_s)
        cached_value(@transfer_changelog_status_by_root, cache_key) do
          in_process_transfer_changelog_status(cache_key) || external_transfer_changelog_status(cache_key)
        end
      rescue
        nil
      end

      def transfer_changelog_total_count
        @transfer_changelog_total_mutex.synchronize do
          return @transfer_changelog_total_count unless @transfer_changelog_total_count.equal?(TRANSFER_CHANGELOG_TOTAL_UNSET)

          total_lag = transfer_changelog_lag(nil)
          @transfer_changelog_total_count = total_lag ? total_lag.fetch("missing_count", 0).to_i : nil
        end
      end

      def in_process_transfer_changelog_lag(last_entry_key)
        return nil unless load_kettle_jem_transfer_api

        normalize_transfer_changelog_lag(::Kettle::Jem.transfer_changelog_lag(last_entry_key))
      rescue
        nil
      end

      def in_process_transfer_changelog_status(root)
        return nil unless load_kettle_jem_transfer_api
        return nil unless ::Kettle::Jem.respond_to?(:transfer_changelog_status)

        normalize_transfer_changelog_lag(::Kettle::Jem.transfer_changelog_status(root))
      rescue
        nil
      end

      def load_kettle_jem_transfer_api
        return true if defined?(::Kettle::Jem) && (::Kettle::Jem.respond_to?(:transfer_changelog_lag) || ::Kettle::Jem.respond_to?(:transfer_changelog_status))

        require "kettle/jem"
        defined?(::Kettle::Jem) && (::Kettle::Jem.respond_to?(:transfer_changelog_lag) || ::Kettle::Jem.respond_to?(:transfer_changelog_status))
      rescue LoadError
        false
      end

      def external_transfer_changelog_lag(cache_key)
        code = <<~RUBY
          last_entry_key = ARGV.fetch(0, "")
          last_entry_key = nil if last_entry_key.empty?
          puts JSON.generate(Kettle::Jem.transfer_changelog_lag(last_entry_key))
        RUBY
        command = [RbConfig.ruby, "-rjson", "-rkettle/jem", "-e", code, cache_key]
        stdout, _stderr, status = if defined?(::Bundler)
          ::Bundler.with_unbundled_env { Open3.capture3(*command) }
        else
          Open3.capture3(*command)
        end
        status.success? ? normalize_transfer_changelog_lag(JSON.parse(stdout)) : nil
      rescue JSON::ParserError, SystemCallError
        nil
      end

      def external_transfer_changelog_status(root)
        code = <<~RUBY
          puts JSON.generate(Kettle::Jem.transfer_changelog_status(ARGV.fetch(0)))
        RUBY
        command = [RbConfig.ruby, "-rjson", "-rkettle/jem", "-e", code, root]
        stdout, _stderr, status = if defined?(::Bundler)
          ::Bundler.with_unbundled_env { Open3.capture3(*command) }
        else
          Open3.capture3(*command)
        end
        status.success? ? normalize_transfer_changelog_lag(JSON.parse(stdout)) : nil
      rescue JSON::ParserError, SystemCallError
        nil
      end

      def normalize_transfer_changelog_lag(lag)
        return nil unless lag.is_a?(Hash)

        lag.each_with_object({}) { |(key, value), memo| memo[key.to_s] = value }
      end

      def github_latest_release(root)
        repo = github_repo_slug(root)
        return nil unless repo

        cached_value(@github_latest_release_by_repo, repo) do
          stdout, _stderr, status = Open3.capture3("gh", "release", "view", "--repo", repo, "--json", "tagName", "--jq", ".tagName")
          status.success? ? normalize_github_release_tag(stdout) : nil
        end
      rescue SystemCallError
        nil
      end

      def cached_value(cache, key)
        cached = @cache_mutex.synchronize { cache.fetch(key, CACHE_MISS) }
        return cached unless cached.equal?(CACHE_MISS)

        value = yield
        @cache_mutex.synchronize do
          cache[key] = value unless cache.key?(key)
          cache.fetch(key)
        end
      end

      def state_jobs(items)
        return 1 if items.length < 2

        requested = jobs || [Etc.nprocessors, 4].min
        requested.to_i.clamp(1, items.length)
      end

      def parallel_map(items, &block)
        return [] if items.empty?

        worker_count = state_jobs(items)
        return items.map { |item| block.call(item) } if worker_count == 1

        queue = Queue.new
        items.each_with_index { |item, index| queue << [index, item] }
        results = Array.new(items.length)
        errors = []
        errors_mutex = Mutex.new
        workers = Array.new(worker_count) do
          Thread.new do # rubocop:disable ThreadSafety/NewThread -- release-state checks intentionally run independently within the jobs limit.
            loop do
              index, item = queue.pop(true)
              results[index] = block.call(item)
            rescue ThreadError
              break
            rescue => error
              errors_mutex.synchronize { errors << error }
              break
            end
          end
        end
        workers.each(&:join)
        raise errors.first unless errors.empty?

        results
      end

      def normalize_github_release_tag(value)
        tag = value.to_s.strip
        return nil if tag.empty?

        tag.start_with?("v") ? tag : "v#{tag}"
      end

      def github_repo_slug(root)
        stdout, _stderr, status = Open3.capture3("git", "remote", "-v", chdir: root)
        return nil unless status.success?

        stdout.each_line.filter_map do |line|
          remote_url = line.split.fetch(1, nil)
          github_slug_from_remote_url(remote_url)
        end.first
      end

      def github_slug_from_remote_url(remote_url)
        return nil unless remote_url&.include?("github.com")

        # Git remote URLs support scp-like SSH syntax as well as URI syntax, so
        # string slicing is more reliable than URI parsing for the full set.
        slug = if remote_url.start_with?("git@github.com:")
          remote_url.delete_prefix("git@github.com:")
        elsif remote_url.include?("github.com/")
          remote_url.split("github.com/", 2).last
        end
        return nil unless slug

        slug = slug.delete_suffix(".git").split(/[?#]/, 2).first.to_s
        parts = slug.split("/")
        return nil if parts.length < 2 || parts.fetch(0).empty? || parts.fetch(1).empty?

        "#{parts.fetch(0)}/#{parts.fetch(1)}"
      end

      def root_changelog_version(root)
        version_file = config.changelog_version_file
        return nil unless version_file

        path = File.expand_path(version_file, root)
        raise Error, "missing changelog version file #{version_file}" unless File.file?(path)

        version_string_node(File.read(path), path).unescaped
      end

      def version_string_node(source, path)
        require_prism
        parse_result = Prism.parse(source)
        raise Error, "could not parse #{path}" unless parse_result.success?

        constant = each_node(parse_result.value).find do |node|
          node.is_a?(Prism::ConstantWriteNode) && node.name == :VERSION && node.value.is_a?(Prism::StringNode)
        end
        raise Error, "could not find string VERSION constant in #{path}" unless constant

        constant.value
      end

      def latest_changelog_version(content)
        content.each_line.filter_map do |line|
          match = line.match(/\A## \[([^\]]+)\]/)
          next unless match

          version = match[1]
          next if version == "Unreleased"

          version
        end.first
      end

      def unreleased_entries?(content)
        lines = content.lines
        start = lines.index { |line| line.start_with?("## [Unreleased]") }
        return false unless start

        following = lines.drop(start + 1)
        block = following.take_while { |line| !line.start_with?("## [") }
        block.any? { |line| line.match?(/\S/) && !line.match?(/\A###? /) }
      end

      def require_prism
        return if defined?(Prism)

        require "prism"
      rescue LoadError => error
        raise Error, "root changelog release-state requires Prism; install the prism gem or run on a Ruby engine that provides it (#{error.message})"
      end

      def each_node(root)
        return enum_for(__method__, root) unless block_given?

        queue = [root]
        until queue.empty?
          node = queue.shift
          yield node
          queue.concat(node.child_nodes.compact) if node.respond_to?(:child_nodes)
        end
      end

      def result(member:, command:, stdout:, stderr:, status:, elapsed:, success:, state:, reason: nil, branch: nil)
        ReleaseStateResult.new(
          member_name: member.name,
          command: command,
          workdir: member.root,
          status: status,
          success: success,
          stdout: stdout,
          stderr: stderr,
          elapsed_seconds: elapsed,
          state: state,
          reason: reason || (success ? nil : "release state check failed"),
          branch: branch
        )
      end

      def error_result(branch:, error:)
        ReleaseStateResult.new(
          member_name: branch,
          command: ["internal", "release-state", branch],
          workdir: config.root,
          status: 1,
          success: false,
          stdout: "",
          stderr: error.message,
          elapsed_seconds: 0.0,
          state: {},
          reason: "branch release state failed",
          branch: branch
        )
      end

      def release_target_branches
        return [] unless config

        config.release_target_branches
      end

      def member_local_branch_results(member, event_handler: nil)
        member_config = member_local_release_config(member)
        return unless member_config

        self.class.new(config: member_config, members: [member]).results(event_handler: event_handler)
      end

      def emit_event(event_handler, member:, branch:, action:, status:, **details)
        return unless event_handler

        event_handler.call({
          "member" => member.name.to_s,
          "branch" => branch,
          "action" => action,
          "status" => status
        }.merge(details.each_with_object({}) { |(key, value), memo| memo[key.to_s] = value }))
      rescue
        nil
      end

      def member_local_release_config(member)
        BranchTargetConfig.member_release_config(member: member, config: config)
      end

      def shared_changelog?
        config&.shared_changelog?
      end

      def normalize_shared_version_bump(results)
        return results unless results.any? { |result| result.ok? && result.state["bump_release_pending"] == true }

        results.map do |result|
          next result unless result.ok?

          result.class.new(
            member_name: result.member_name,
            command: result.command,
            workdir: result.workdir,
            status: result.status,
            success: result.success,
            stdout: result.stdout,
            stderr: result.stderr,
            elapsed_seconds: result.elapsed_seconds,
            state: result.state.merge("bump_release_pending" => true),
            reason: result.reason,
            branch: result.branch
          )
        end
      end

      def git_root
        stdout, stderr, status = Open3.capture3("git", "rev-parse", "--show-toplevel", chdir: config.root)
        raise Error, "could not determine git root for #{config.root}: #{stderr}" unless status.success?

        File.realpath(stdout.strip)
      end

      def with_branch_worktree(root:, branch:)
        base = File.join(root, "tmp", "kettle-family-release-state")
        FileUtils.mkdir_p(base)
        worktree_root = File.join(base, "worktree-#{Process.pid}-#{SecureRandom.hex(8)}")
        add_branch_worktree(root: root, branch: branch, worktree_root: worktree_root)
        yield worktree_root
      ensure
        remove_branch_worktree(root: root, worktree_root: worktree_root)
      end

      def add_branch_worktree(root:, branch:, worktree_root:)
        _stdout, stderr, status = Open3.capture3("git", "worktree", "add", "--detach", worktree_root, branch, chdir: root)
        raise Error, "could not add worktree for #{branch}: #{stderr}" unless status.success?
      end

      def remove_branch_worktree(root:, worktree_root:)
        return unless worktree_root && Dir.exist?(worktree_root)

        Open3.capture3("git", "worktree", "remove", "--force", worktree_root, chdir: root)
      end

      def discover_branch_members(worktree_root:, selected_names:)
        branch_config = Config.load(root: branch_config_root(worktree_root))
        Discovery.new(config: branch_config).members
          .sort_by(&:name)
          .select { |member| selected_names.include?(member.name) }
      end

      def branch_config_root(worktree_root)
        File.join(worktree_root, relative_config_root)
      end

      def relative_config_root
        @relative_config_root ||= begin
          root = git_root
          config_root = File.realpath(config.root)
          if config_root == root
            "."
          elsif config_root.start_with?("#{root}/")
            config_root.delete_prefix("#{root}/")
          else
            raise Error, "configured root #{config.root} is outside git root #{root}"
          end
        end
      end
    end
  end
end
