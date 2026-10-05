# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ticketing::Ticket, "piattaforme colpite", type: :model do
  let(:org) { create(:organization) }
  let(:ios) { create(:platform, organization: org, code: "ios") }
  let(:web) { create(:platform, organization: org, code: "web") }
  # progetto che dichiara SOLO ios
  let(:project) { create(:project, organization: org).tap { |p| p.platforms << ios } }
  let(:ticket) { create(:ticket, organization: org, project: project) }

  it "è valido senza piattaforme (bug platform-agnostico)" do
    ticket.platforms = []
    expect(ticket).to be_valid
  end

  it "è valido con una piattaforma dichiarata dal progetto" do
    ticket.platforms = [ ios ]
    expect(ticket).to be_valid
  end

  it "è invalido con una piattaforma NON dichiarata dal progetto (subset)" do
    ticket.platforms = [ web ]
    expect(ticket).not_to be_valid
    expect(ticket.errors[:platforms]).to be_present
  end

  it "è invalido se anche una sola piattaforma è fuori dal progetto" do
    ticket.platforms = [ ios, web ]
    expect(ticket).not_to be_valid
  end
end
