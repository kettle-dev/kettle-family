# frozen_string_literal: true

module Kettle
  module Family
    # Adapter seam around the mise binary.
    #
    # Mise is operational glue, not a code dependency: family tooling uses it
    # for `mise trust -C <root>` after materializing managed task files, and
    # for `mise exec -C <member.root> -- <cmd>` when running member commands
    # under the member's declared runtime. It is absent in CI and on mise-less
    # hosts, so every use degrades deliberately:
    #
    # - `trust_argv` returns nil when mise is unavailable (callers skip the
    #   trust phase — it only enables subsequent nested mise runs).
    # - `exec_argv` passes the command through unwrapped when mise is
    #   unavailable (there is no member runtime to activate), preserving env
    #   injection via env(1) (or the portable ruby script on Windows).
    #
    # Specs inject a fake or stubbed adapter rather than spawning the real
    # binary; only these adapter specs exercise the real PATH scan.
    class MiseAdapter
      # Portable env-manipulation wrapper used when commands must run with env
      # changes on Windows (no env(1) there).
      WINDOWS_ENV_EXEC_SCRIPT = <<~RUBY
        unset_count = Integer(ARGV.shift)
        unset_count.times { ENV.delete(ARGV.shift) }
        assignment_count = Integer(ARGV.shift)
        assignment_count.times do
          key, value = ARGV.shift.split("=", 2)
          ENV[key] = value
        end
        abort "missing command after environment arguments" if ARGV.shift != "--"
        exec(*ARGV)
      RUBY

      # Absolute path to the mise executable resolved from the current PATH,
      # or nil when mise is not installed. The absolute path is required for
      # real spawns: CommandRunner's child env strips the orchestrator's
      # Ruby/gem bin dirs from PATH, so a bare "mise" argv is unresolvable
      # whenever the binary lives in one of those directories.
      #
      # @return [String, nil]
      def executable
        ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).each do |dir|
          path = File.join(dir, "mise")
          return path if File.file?(path) && File.executable?(path)
        end
        nil
      end

      # @return [Boolean] whether mise-wrapping and trust are possible
      def available?
        !executable.nil?
      end

      # argv for `mise trust -C <root>`, or nil when mise is unavailable.
      #
      # @param root [String]
      # @return [Array<String>, nil]
      def trust_argv(root)
        exe = executable
        return nil unless exe

        [exe, "trust", "-C", root]
      end

      # Build the argv for running a member command under the member's
      # mise-declared runtime. Passes through unwrapped (preserving env
      # injection) when mise is unavailable.
      #
      # @param member_root [String]
      # @param argv [Array<String>] the normalized command
      # @param unset_env [Array<String>] env keys to unset in the child
      # @param set_env [Hash{String => String}] env assignments for the child
      # @return [Array<String>]
      def exec_argv(member_root:, argv:, unset_env: [], set_env: {})
        injected_env = [
          *unset_env.flat_map { |key| ["-u", key.to_s] },
          *set_env.map { |key, value| "#{key}=#{value}" }
        ]

        exe = executable
        unless exe
          # No mise executable: there is no member runtime to activate, and a
          # wrapped spawn would be an unresolvable bare "mise" (ENOENT under
          # the filtered child PATH). Run unwrapped, preserving env injection.
          return argv if injected_env.empty?

          return windows_env_argv(unset_env: unset_env, set_env: set_env, argv: argv) if Gem.win_platform?

          return ["env", *injected_env, *argv]
        end

        mise_argv = [exe, "exec", "-C", member_root, "--"]
        return [*mise_argv, *argv] if injected_env.empty?

        if Gem.win_platform?
          return [*mise_argv, *windows_env_argv(unset_env: unset_env, set_env: set_env, argv: argv)]
        end

        [*mise_argv, "env", *injected_env, *argv]
      end

      private

      def windows_env_argv(unset_env:, set_env:, argv:)
        [
          "ruby",
          "--disable=rubyopt",
          "-e",
          WINDOWS_ENV_EXEC_SCRIPT,
          "--",
          unset_env.length.to_s,
          *unset_env.map { |key| key.to_s },
          set_env.length.to_s,
          *set_env.map { |key, value| "#{key}=#{value}" },
          "--",
          *argv
        ]
      end
    end
  end
end
