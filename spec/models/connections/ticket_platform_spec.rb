# frozen_string_literal: true

require "rails_helper"

RSpec.describe Connections::TicketPlatform, type: :model do
  it "rifiuta lo stesso platform due volte sullo stesso ticket" do
    org = create(:organization)
    platform = create(:platform, organization: org)
    project = create(:project, organization: org)
    project.platforms << platform
    ticket = create(:ticket, organization: org, project: project)
    ticket.platforms << platform

    dup = described_class.new(ticket: ticket, platform: platform)
    expect(dup).not_to be_valid
  end
end
