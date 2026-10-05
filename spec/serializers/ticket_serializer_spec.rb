# frozen_string_literal: true

require "rails_helper"

RSpec.describe TicketSerializer do
  it "espone code/title/status/priority del ticket" do
    ticket = create(:ticket)
    json = JSON.parse(TicketSerializer.new(ticket).serialize)

    expect(json["id"]).to eq(ticket.id)
    expect(json["code"]).to eq(ticket.code)
    expect(json["title"]).to eq(ticket.title)
    expect(json["status"]).to eq(ticket.status&.label)
    expect(json["priority"]).to eq(ticket.priority&.label)
    expect(json["status_color"]).to eq(ticket.status&.color)
    expect(json["priority_color"]).to eq(ticket.priority&.color)
  end

  it "espone la scadenza (due_at), stesso formato di created_at" do
    ticket = create(:ticket, due_at: Time.zone.local(2026, 8, 1, 17, 0))
    json = JSON.parse(TicketSerializer.new(ticket).serialize)

    expect(Time.zone.parse(json["due_at"])).to eq(ticket.due_at)
  end

  it "è nil-safe quando status/priority sono assenti" do
    ticket = build(:ticket, status: nil, priority: nil)
    json = JSON.parse(TicketSerializer.new(ticket).serialize)

    expect(json["status"]).to be_nil
    expect(json["priority"]).to be_nil
    expect(json["status_color"]).to be_nil
    expect(json["priority_color"]).to be_nil
    expect(json["title"]).to eq(ticket.title)
  end

  it "espone scenari, condizioni DoD e analisi tecnica (corpo completo per la CLI)" do
    ticket = create(:ticket, :with_scenarios, scenarios_count: 2, technical_analysis: "N+1 su Orders#index")
    ticket.conditions.create!(position: 0, text: "la mail parte")
    json = JSON.parse(TicketSerializer.new(ticket.reload).serialize)

    expect(json["technical_analysis"]).to eq("N+1 su Orders#index")
    expect(json["scenarios"].size).to eq(2)
    expect(json["scenarios"].first).to include("title", "step_given", "step_when", "step_then", "step_expected")
    expect(json["conditions"]).to eq([ { "text" => "la mail parte" } ])
  end
end
