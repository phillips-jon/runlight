# frozen_string_literal: true

require "open3"

# Runs scripts/php-fixtures-store.mts with the TypeScript SDK, when node is at hand.
module Node
  module_function

  def root
    File.expand_path("../../../..", __dir__)
  end

  # node 22 or later (RUNLIGHT_NODE, the nvm Node 24 the repository uses, or the PATH's), with tsx installed
  # at the repository root or a folder above it (a worktree finds the main checkout's).
  def binary
    return nil unless tsx?

    candidates = [ENV["RUNLIGHT_NODE"], File.join(Dir.home, ".nvm/versions/node/v24.14.1/bin/node"), "node"].compact.reject(&:empty?)
    candidates.find do |node|
      version, status = Open3.capture2(node, "--version")
      status.success? && version.strip.match(/\Av(\d+)\./) && Regexp.last_match(1).to_i >= 22
    rescue SystemCallError
      false
    end
  end

  def tsx?
    dir = root
    loop do
      return true if File.directory?(File.join(dir, "node_modules/tsx"))

      parent = File.dirname(dir)
      return false if parent == dir

      dir = parent
    end
  end

  # The script with these arguments: [exit status, what it wrote, what it said on stderr].
  def store(node, args)
    out, err, status = Open3.capture3(node, "--import", "tsx", "scripts/php-fixtures-store.mts", *args, chdir: root)
    [status.exitstatus, out, err]
  end
end
