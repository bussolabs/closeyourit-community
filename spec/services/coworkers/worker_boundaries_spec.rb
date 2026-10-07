# frozen_string_literal: true

require "rails_helper"

RSpec.describe Coworkers::Worker do
  let(:run) { Coworkers::Run.new(kind: "chat", status: "running", output: "", runtime_state: {}, tools: []) }

  it "rejects malformed batch numbers, collections and excess events" do
    [ [ 0, [] ], [ "1", [] ], [ 1, nil ], [ 1, Array.new(101) ] ].each do |sequence, events|
      expect { described_class.validate_batch!(sequence, events) }.to raise_error(described_class::InvalidEvent)
    end
    expect { described_class.validate_batch!(1, Array.new(100)) }.not_to raise_error
  end

  it "rejects invalid event shapes, proposals and results before changing output" do
    [ nil, { "type" => "delta", "text" => nil }, { "type" => "proposal", "proposal" => {} },
      { "type" => "result", "success" => "true", "output" => "text" }, { "type" => "result", "success" => true, "output" => nil } ].each do |event|
      expect { described_class.apply(run, event) }.to raise_error(described_class::InvalidEvent)
    end
    run.status = "completed"
    expect { described_class.apply(run, { "type" => "delta", "text" => "late" }) }.to raise_error(described_class::InvalidEvent)
    expect(run.output).to eq("")
  end

  it "clears the streamed text when the runtime takes back a made-up turn" do
    described_class.apply(run, { "type" => "delta", "text" => "DASH has 30 tickets." })
    described_class.apply(run, { "type" => "reset" })
    described_class.apply(run, { "type" => "delta", "text" => "DASH has 4 tickets." })
    expect(run.output).to eq("DASH has 4 tickets.")
  end

  it "limits tool identifiers and prevents duplicate or unauthorized chat tools" do
    [ { "id" => "x", "name" => "browser_read" }, { "id" => nil, "name" => "propose_task" },
      { "id" => "x" * 129, "name" => "propose_task" } ].each do |event|
      expect { described_class.tool(run, event) }.to raise_error(described_class::InvalidEvent)
    end
    event = { "id" => "one", "name" => "mcp__coworkers__propose_task" }
    described_class.tool(run, event)
    expect { described_class.tool(run, event) }.to raise_error(described_class::InvalidEvent)
    expect(run.tools.size).to eq(1)
  end

  it "keeps an interrupted run failed without erasing partial output" do
    run.output = "Partial answer"
    described_class.complete(run, { "code" => 0 })
    expect(run).to have_attributes(status: "failed", output: "Partial answer", error_code: "runtime_failed")
  end
end
