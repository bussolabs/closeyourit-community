# frozen_string_literal: true

require "prism"
require "yaml"

# CYRA-1166 — reads the spec tree's syntax (not its text) for skips without a quarantine ticket,
# fixed sleeps and real clock reads. Loaded by spec_helper before Rails: plain Ruby only.
module TestQuarantine
  ROOT = File.expand_path("..", __dir__)
  BASELINE_PATH = File.join(ROOT, "spec/config/test_quarantine_baseline.yml")
  QUARANTINE_COMMENT = /\A#\s*quarantine:\s*[A-Z][A-Z0-9]*-\d+\b/

  SKIP_CALLS = %i[
    skip pending focus
    xit xspecify xexample xscenario xdescribe xcontext xfeature
    fit fspecify fexample fscenario fdescribe fcontext ffeature
  ].freeze
  EXAMPLE_CALLS = %i[it specify example scenario its describe context feature].freeze
  SKIP_METADATA = %w[skip pending focus].freeze

  # Cheap text prefilter: only files that could hold a finding are parsed.
  CANDIDATE = /\b(?:#{(SKIP_CALLS + %i[sleep now]).join("|")})\b/

  Finding = Struct.new(:path, :line, :kind)

  MESSAGES = {
    "skip" => "skips, pends or focuses a test without a ticket. Put `# quarantine: CYRA-123` on the line " \
              "right above, naming the ticket that will fix it.",
    "sleep" => "waits a fixed time. Wait for a condition instead.",
    "wall_clock" => "reads the real clock with Time.now. Freeze time (travel_to, freeze_time) instead."
  }.freeze

  class << self
    def verify!
      problems = violations(tree_findings, baseline)
      return if problems.empty?

      raise "Test quarantine check failed (CYRA-1166):\n#{problems.join("\n")}"
    end

    def tree_findings(root = ROOT)
      Dir.glob("spec/**/*.rb", base: root).sort.flat_map do |path|
        source = File.read(File.join(root, path))
        CANDIDATE.match?(source) ? scan(source, path) : []
      end
    end

    def baseline
      YAML.safe_load_file(BASELINE_PATH) || {}
    end

    # One message per finding in a file whose count is above its baseline.
    def violations(findings, baseline)
      grouped(findings).flat_map do |(kind, path), found|
        next [] if found.size <= baseline.fetch(kind, {}).fetch(path, 0)

        found.map { |finding| "#{finding.path}:#{finding.line} #{MESSAGES.fetch(kind)}" }
      end
    end

    # Baseline counts the tree no longer reaches: they must be lowered.
    def stale_entries(findings, baseline)
      counts = grouped(findings).transform_values(&:size)
      baseline.flat_map do |kind, entries|
        entries.filter_map do |path, allowed|
          actual = counts.fetch([ kind, path ], 0)
          "#{kind} #{path}: baseline #{allowed}, now #{actual}. Lower it in #{BASELINE_PATH}." if actual < allowed
        end
      end
    end

    def scan(source, path)
      result = Prism.parse(source)
      comments = result.comments.to_h { |comment| [ comment.location.start_line, comment.slice ] }
      findings = []
      visit = lambda do |node|
        kind = kind_of(node) if node.is_a?(Prism::CallNode)
        findings << Finding.new(path, node.location.start_line, kind) if kind
        node.compact_child_nodes.each { |child| visit.call(child) }
      end
      visit.call(result.value)
      findings.uniq.reject { |finding| finding.kind == "skip" && QUARANTINE_COMMENT.match?(comments[finding.line - 1].to_s) }
    end

    private

    def grouped(findings)
      findings.group_by { |finding| [ finding.kind, finding.path ] }
    end

    def kind_of(call)
      return "sleep" if call.name == :sleep
      return "wall_clock" if call.name == :now && call.receiver&.slice&.delete_prefix("::") == "Time"
      return unless rspec_receiver?(call)

      "skip" if SKIP_CALLS.include?(call.name) || (EXAMPLE_CALLS.include?(call.name) && skip_metadata?(call))
    end

    def rspec_receiver?(call)
      call.receiver.nil? || call.receiver.slice.delete_prefix("::") == "RSpec"
    end

    def skip_metadata?(call)
      Array(call.arguments&.arguments).any? do |argument|
        case argument
        when Prism::SymbolNode then SKIP_METADATA.include?(argument.unescaped)
        when Prism::KeywordHashNode, Prism::HashNode
          argument.elements.any? { |pair| pair.is_a?(Prism::AssocNode) && pair.key.is_a?(Prism::SymbolNode) && SKIP_METADATA.include?(pair.key.unescaped) }
        end
      end
    end
  end
end
