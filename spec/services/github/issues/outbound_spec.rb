# frozen_string_literal: true

require "rails_helper"

# CYRA-1055 — a change made on CloseYourIt leaves for GitHub; one that arrived from GitHub does not bounce back.
RSpec.describe Github::Issues::Outbound do
  let(:link) { create(:github_issue) }
  let(:ticket) { link.ticket }
  let(:organization) { ticket.project.organization }
  let(:in_progress) { create(:ticket_status, organization:, category: :in_progress) }

  def change_status(target = ticket)
    Ticketing::ChangeStatus.call(organization:, ticket: target, status_id: in_progress.id, channel: :web,
                                 actor: target.reporter)
  end

  it "a status change on a linked ticket queues the push to its issue" do
    expect { change_status }.to have_enqueued_job(Github::Issues::PushJob).with(ticket_id: ticket.id)
  end

  it "a change applied from GitHub queues nothing back" do
    expect { described_class.suppress { change_status } }.not_to have_enqueued_job(Github::Issues::PushJob)
  end

  it "a ticket without an issue queues nothing" do
    other = create(:ticket, project: ticket.project)

    expect { change_status(other) }.not_to have_enqueued_job(Github::Issues::PushJob)
  end

  it "a comment written here on a linked ticket queues its push" do
    expect do
      Ticketing::AddComment.call(ticket:, author: ticket.reporter, params: { body: "Ci guardo io" })
    end.to have_enqueued_job(Github::Issues::PushCommentJob)
  end
end
