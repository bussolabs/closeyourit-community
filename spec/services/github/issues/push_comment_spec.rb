# frozen_string_literal: true

require "rails_helper"

# CYRA-1055 — a comment written on CloseYourIt reaches the linked issue, with its writer's name.
RSpec.describe Github::Issues::PushComment do
  let(:link) { create(:github_issue) }
  let(:ticket) { link.ticket }
  let(:client) { instance_double(Github::Client) }

  it "posts the comment on the issue and keeps its GitHub id" do
    comment = create(:ticket_comment, ticket:, author: ticket.reporter, body: "Ci guardo io")
    allow(client).to receive(:create_issue_comment).and_return({ "id" => 9001 })

    described_class.call(comment:, client:)

    expect(client).to have_received(:create_issue_comment)
      .with(link.repository.github_installation_id, link.repository.full_name, link.number,
            body: a_string_including(ticket.reporter.name, "Ci guardo io"))
    expect(comment.reload.github_comment_id).to eq(9001)
  end

  it "leaves a comment born on GitHub where it is" do
    comment = create(:ticket_comment, ticket:, author: ticket.reporter, body: "Da GitHub",
                                      github_comment_id: 1, github_author_login: "bob")
    allow(client).to receive(:create_issue_comment)

    described_class.call(comment:, client:)

    expect(client).not_to have_received(:create_issue_comment)
  end
end
