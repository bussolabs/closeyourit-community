# frozen_string_literal: true

require "rails_helper"

# CYRA-914 phase 2 — a new search model for one organization recalculates that organization's data only.
RSpec.describe Embeddings::ReembedOrganizationJob do
  it "queues every embedded kind of record of the organization" do
    ticket = create(:ticket)
    organization = ticket.project.organization
    group = create(:error_group, project: ticket.project)
    idea = create(:idea, organization:, project: ticket.project)
    request = create(:helpdesk_request, project: ticket.project)
    page = create(:knowledge_page, organization:)

    expect { described_class.perform_now(organization_id: organization.id) }
      .to have_enqueued_job(Ticketing::EmbedTicketJob).with(ticket_id: ticket.id)
      .and have_enqueued_job(Errors::EmbedGroupJob).with(group_id: group.id)
      .and have_enqueued_job(Ideas::EmbedIdeaJob).with(idea_id: idea.id)
      .and have_enqueued_job(Helpdesk::EmbedRequestJob).with(request_id: request.id)
      .and have_enqueued_job(Knowledge::EmbedPageJob).with(page_id: page.id)
  end

  it "leaves the other organizations alone" do
    mine = create(:ticket)
    stranger = create(:ticket, project: create(:project, organization: create(:organization)))
    expect(stranger.project.organization_id).not_to eq(mine.project.organization_id)

    expect { described_class.perform_now(organization_id: mine.project.organization_id) }
      .not_to have_enqueued_job(Ticketing::EmbedTicketJob).with(ticket_id: stranger.id)
  end
end
