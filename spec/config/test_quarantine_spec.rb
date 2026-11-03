# frozen_string_literal: true

require "rails_helper"
require "prism"

# CYRA-1166 — a test may be skipped, pending or focused only under a `# quarantine: CYRA-123`
# comment; fixed sleeps and real clock reads may only go down. The boot check lives in spec_helper.
RSpec.describe TestQuarantine do
  # Counts per file on 2026-11-03: the baseline file may only shrink below these.
  INITIAL_BASELINE_CYRA1166 = {
    "skip" => {
      "spec/config/parallel_runtime_log_spec.rb" => 1,
      "spec/config/repository_hygiene_spec.rb" => 1,
      "spec/requests/cli/v1/artifacts/proguard_maps_spec.rb" => 1,
      "spec/services/artifacts/proguard_maps/concurrency_spec.rb" => 1,
      "spec/services/errors/symbolication/java/resolve_spec.rb" => 1,
      "spec/support/js_system.rb" => 1,
      "spec/support/native_symbol_fixture.rb" => 1,
      "spec/system/member/sidebar_overflow_spec.rb" => 1,
      "spec/system/ui/select_panel_overflow_spec.rb" => 1,
      "spec/system/ui/tooltip_position_spec.rb" => 1
    },
    "sleep" => {
      "spec/services/artifacts/native_symbols/concurrency_spec.rb" => 1,
      "spec/services/coworkers/mcp_spec.rb" => 1,
      "spec/services/crashes/concurrency_spec.rb" => 1,
      "spec/services/seo/fetch_spec.rb" => 3,
      "spec/support/streaming_body_server.rb" => 1,
      "spec/support/system_wait_helpers.rb" => 1
    },
    "wall_clock" => {
      "spec/installer/apply_update_request_spec.rb" => 1
    }
  }.freeze

  def kinds_and_lines(source)
    described_class.scan(source, "fake_spec.rb").map { |finding| [ finding.kind, finding.line ] }
  end

  describe ".scan" do
    it "finds every form of skip, pending and focus" do
      source = <<~RUBY
        xit "a" do; end
        xdescribe "b" do; end
        xcontext "c" do; end
        xspecify "d" do; end
        fit "e" do; end
        fdescribe "f" do; end
        fcontext "g" do; end
        focus "h" do; end
        RSpec.xdescribe "i" do; end
        it "j", :skip do; end
        it "k", skip: "broken" do; end
        describe "l", :pending do; end
        context "m", focus: true do; end
        before { skip "no browser" }
        pending "not done yet" if flag
        skip("no git") unless ok
      RUBY

      expect(kinds_and_lines(source)).to eq((1..16).map { |line| [ "skip", line ] })
    end

    it "does not flag words that only look like a skip" do
      source = <<~RUBY
        described_class.pending
        create(:move, status: :pending)
        pending = create(:host)
        expect(pending).to be_present
        offenders(skip: %w[app/components])
        expect(job).to have_received(:call).with(hash_including(focus: project))
        it "keeps the pending state" do; end
        execute("SELECT pg_sleep(1)")
        Time.current
      RUBY

      expect(kinds_and_lines(source)).to be_empty
    end

    it "accepts a skip with a quarantine comment right above" do
      source = <<~RUBY
        # quarantine: CYRA-123
        xit "a" do; end
          # quarantine: CYAU-179
          pending "waits for the planner marker"
      RUBY

      expect(kinds_and_lines(source)).to be_empty
    end

    it "rejects a quarantine comment that is not right above or names no ticket" do
      source = <<~RUBY
        # quarantine: CYRA-123

        xit "a" do; end
        # quarantine: soon
        xit "b" do; end
        # TODO CYRA-123
        xit "c" do; end
      RUBY

      expect(kinds_and_lines(source)).to eq([ [ "skip", 3 ], [ "skip", 5 ], [ "skip", 7 ] ])
    end

    it "counts fixed sleeps and real clock reads, whatever their shape" do
      source = <<~RUBY
        sleep 1.5
        Kernel.sleep(1)
        sleep(
          WAIT
        )
        Time.now
        ::Time.now.to_i
      RUBY

      expect(kinds_and_lines(source)).to eq([ [ "sleep", 1 ], [ "sleep", 2 ], [ "sleep", 3 ], [ "wall_clock", 6 ], [ "wall_clock", 7 ] ])
    end
  end

  describe "the real spec tree" do
    let(:findings) { described_class.tree_findings }
    let(:baseline) { described_class.baseline }

    it "has no skip, sleep or clock read beyond the baseline" do
      expect(described_class.violations(findings, baseline)).to be_empty
    end

    it "keeps no baseline entry above what the tree still has" do
      expect(described_class.stale_entries(findings, baseline)).to be_empty
    end

    it "only ever shrinks the baseline" do
      grown = baseline.flat_map do |kind, counts|
        counts.filter_map do |path, count|
          "#{kind} #{path}: #{count}" if count > INITIAL_BASELINE_CYRA1166.fetch(kind, {}).fetch(path, 0)
        end
      end

      expect(grown).to be_empty, "baseline grew past the 2026-11-03 counts: #{grown.join(', ')}"
    end
  end

  describe "the violation message" do
    let(:finding) { TestQuarantine::Finding.new("spec/new_spec.rb", 4, "skip") }

    it "names file, line and the comment to add" do
      message = described_class.violations([ finding ], {}).join

      expect(message).to include("spec/new_spec.rb:4").and include("# quarantine: CYRA-123")
    end

    it "lets a baselined skip through and flags a stale entry" do
      expect(described_class.violations([ finding ], { "skip" => { "spec/new_spec.rb" => 1 } })).to be_empty
      expect(described_class.stale_entries([], { "skip" => { "spec/new_spec.rb" => 1 } }).join)
        .to include("spec/new_spec.rb")
    end
  end

  describe "spec_helper" do
    let(:calls) do
      found = []
      visit = lambda do |node|
        found << node if node.is_a?(Prism::CallNode)
        node.compact_child_nodes.each { |child| visit.call(child) }
      end
      visit.call(Prism.parse_file(Rails.root.join("spec/spec_helper.rb").to_s).value)
      found
    end

    it "runs the check before any example, whatever the selection" do
      expect(calls.map(&:slice)).to include("TestQuarantine.verify!")
    end

    it "keeps the focus filter off" do
      filters = calls.select { |call| call.name.to_s.start_with?("filter_run") }

      expect(filters).to be_empty, "a focus filter would let a focused test hide the rest of the suite"
    end
  end
end
