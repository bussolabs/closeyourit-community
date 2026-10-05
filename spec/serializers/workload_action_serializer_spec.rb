# frozen_string_literal: true

require "rails_helper"

RSpec.describe WorkloadActionSerializer, type: :serializer do
  it "serializza i campi scalari, il team, il ticket_code, created_by e i partecipanti" do
    organization = create(:organization)
    team = create(:team, organization: organization, name: "Marketing")
    creator = create(:account, name: "Ada")
    action = create(:workload_action, :with_participants, :with_ticket,
                    team: team, organization: organization, created_by: creator, title: "Fiera")

    json = JSON.parse(described_class.new(action).serialize)

    expect(json["title"]).to eq("Fiera")
    expect(json["status"]).to eq("planned")
    expect(json["team"]).to eq("Marketing")
    expect(json["team_id"]).to eq(team.id)
    expect(json["created_by"]).to eq("Ada")
    expect(json["ticket_code"]).to eq(action.ticket.code)
    expect(json["participants"].size).to eq(2)
  end

  it "espone ticket_code nullo e nessun partecipante quando assenti" do
    action = create(:workload_action)

    json = JSON.parse(described_class.new(action).serialize)

    expect(json["ticket_code"]).to be_nil
    expect(json["participants"]).to eq([])
  end
end
