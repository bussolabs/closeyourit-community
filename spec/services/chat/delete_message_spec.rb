# frozen_string_literal: true

require "rails_helper"

RSpec.describe Chat::DeleteMessage do
  let(:org) { create(:organization) }
  let(:shared) { create(:project, organization: org) }

  def member_seeing(*projects)
    account = create(:account)
    create(:membership, account: account, organization: org, role: :member)
    projects.each { |project| create(:project_membership, account: account, project: project) }
    account
  end

  let(:author) { member_seeing(shared) }
  let(:other) { member_seeing(shared) }
  let(:conversation) do
    Chat::Conversations::FindOrCreateDirect.call(organization: org, account_a: author, account_b: other).value
  end
  let(:message) { conversation.messages.create!(body: "da eliminare", author: author, organization_id: org.id) }

  it "soft-elimina il messaggio" do
    result = described_class.call(message: message)
    expect(result).to be_ok
    expect(message.reload.deleted?).to be(true)
  end

  it "broadcasta la rimozione della bolla sullo stream della conversazione" do
    removals = []
    allow(Turbo::StreamsChannel).to receive(:broadcast_remove_to) { |stream, **opts| removals << [ stream, opts ] }

    described_class.call(message: message)

    expect(removals.length).to eq(1)
    expect(removals.first[0]).to eq(Realtime::Streams.chat_conversation(conversation))
    expect(removals.first[1]).to include(target: ActionView::RecordIdentifier.dom_id(message))
  end
end
