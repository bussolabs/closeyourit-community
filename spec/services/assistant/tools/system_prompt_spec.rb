# frozen_string_literal: true

require "rails_helper"

RSpec.describe Assistant::Tools::SystemPrompt do
  let(:function) do
    Assistant::BuildCatalog::Function.new(key: "tickets", label: "Ticket",
                                          description: "Board of the tickets", path: "/member/tickets")
  end

  it "keeps the read-only prompt without a catalog" do
    prompt = described_class.call

    expect(prompt).not_to include(described_class::CATALOG_RULE.strip)
    expect(prompt).not_to include("/member/tickets")
  end

  it "lists the pages and the link rule when a catalog is given" do
    prompt = described_class.call(catalog: [ function ])

    expect(prompt).to include(described_class::CATALOG_RULE.strip)
    expect(prompt).to include("- Ticket: Board of the tickets (path: /member/tickets)")
  end

  it "keeps the scope rule together with the catalog" do
    prompt = described_class.call(scope_reduced: true, catalog: [ function ])

    expect(prompt).to include(described_class::SCOPE_REDUCED_RULE.strip)
    expect(prompt).to include(described_class::CATALOG_RULE.strip)
  end

  it "adds the proposal rule only when proposals are on" do
    expect(described_class.call).not_to include(described_class::PROPOSAL_RULE.strip)
    expect(described_class.call(proposals: true)).to include(described_class::PROPOSAL_RULE.strip)
  end

  it "names the project the conversation is fixed on, and only then" do
    project = build_stubbed(:project, key: "DASH", name: "Dashboard")

    expect(described_class.call).not_to include("fixed on ONE project")
    expect(described_class.call(focus: project)).to include("fixed on ONE project: Dashboard (key DASH)")
  end

  # Earlier replies reach the model as plain text without their tool calls, so it imitated
  # "I prepared the card" without calling the tool (seen live twice on 2026-10-01). CYRA-908
  it "tells the model that earlier cards never cover a new request" do
    rule = described_class::PROPOSAL_RULE
    expect(rule).to include("in THIS turn")
    expect(rule).to include("earlier replies never cover")
  end
end
