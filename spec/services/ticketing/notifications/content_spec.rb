# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ticketing::Notifications::Content do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization: organization, key: "STR") }
  let(:ticket) { create(:ticket, organization: organization, project: project, title: "Login broken") }

  def event(action, data)
    create(:ticket_event, ticket: ticket, action: action, data: data)
  end

  it "created → titolo col codice, corpo col titolo del ticket, url alla show" do
    content = described_class.for(event: event("created", { "status" => "Open" }))
    expect(content.title).to include(ticket.code)
    expect(content.body).to eq("Login broken")
    expect(content.url).to eq("/member/tickets/#{ticket.id}")
  end

  it "assigned → titolo col nome dell'assegnatario" do
    content = described_class.for(event: event("assigned", { "assignee" => { "from" => nil, "to" => "Dana" } }))
    expect(content.title).to include("Dana")
  end

  it "unassigned → titolo col codice del ticket" do
    content = described_class.for(event: event("unassigned", { "assignee" => { "from" => "Dana", "to" => nil } }))
    expect(content.title).to include(ticket.code)
  end

  it "status_changed → titolo con from → to" do
    content = described_class.for(event: event("status_changed", { "status" => { "from" => "Open", "to" => "Done" } }))
    expect(content.title).to include("Open").and(include("Done"))
  end

  it "milestone_changed (set) → titolo col nome della milestone" do
    content = described_class.for(event: event("milestone_changed", { "milestone" => { "from" => nil, "to" => "v1.0" } }))
    expect(content.title).to include("v1.0")
  end

  it "milestone_changed (removed) → titolo col codice, senza nome" do
    content = described_class.for(event: event("milestone_changed", { "milestone" => { "from" => "v1.0", "to" => nil } }))
    expect(content.title).to include(ticket.code)
  end

  it "azione non mappata → titolo = solo il codice del ticket (ramo else difensivo)" do
    content = described_class.for(event: event("attached", {}))
    expect(content.title).to eq(ticket.code)
  end
end
