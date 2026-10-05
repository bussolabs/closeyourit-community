# frozen_string_literal: true

require "rails_helper"

RSpec.describe Chat::Taggables::Search do
  let(:org) { create(:organization) }
  let(:shared) { create(:project, organization: org) }

  def member_seeing(*projects)
    account = create(:account)
    create(:membership, account: account, organization: org, role: :member)
    projects.each { |project| create(:project_membership, account: account, project: project) }
    account
  end

  let(:conversation) do
    Chat::Conversations::FindOrCreateDirect.call(
      organization: org, account_a: member_seeing(shared), account_b: member_seeing(shared)
    ).value
  end

  it "restituisce i ticket comuni col token #CODE" do
    ticket = create(:ticket, organization: org, project: shared, title: "Login rotto")
    result = described_class.call(conversation: conversation, query: "Login")
    entry = result.find { |item| item[:type] == "ticket" }
    expect(entry[:id]).to eq(ticket.id)
    expect(entry[:token]).to eq("##{ticket.code}")
  end

  it "filtra per tipo" do
    create(:ticket, organization: org, project: shared, title: "Alpha")
    result = described_class.call(conversation: conversation, query: "", type: "project")
    expect(result.map { |item| item[:type] }.uniq).to eq([ "project" ])
    expect(result.first[:token]).to eq("cyi:project:#{shared.id}")
  end

  it "è vuoto senza progetti in comune" do
    lonely = Chat::Conversation.create!(organization: org, kind: :project,
                                        contextable: create(:project, organization: org))
    # un canale il cui audience (Recipients) non condivide progetti con nessuno → nessun taggabile
    allow(lonely).to receive(:audience).and_return([])
    expect(described_class.call(conversation: lonely, query: "x")).to be_empty
  end

  it "tronca al limite di 8 risultati (9 match → 8)" do
    9.times { |i| create(:ticket, organization: org, project: shared, title: "Limite #{i}") }
    result = described_class.call(conversation: conversation, query: "Limite")
    expect(result.length).to eq(8)
  end
end
