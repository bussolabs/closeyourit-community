# frozen_string_literal: true

require "rails_helper"

RSpec.describe Chat::PostMessage do
  let(:org) { create(:organization) }
  let(:shared) { create(:project, organization: org) }
  let(:private_a) { create(:project, organization: org) }

  def member_seeing(*projects)
    account = create(:account)
    create(:membership, account: account, organization: org, role: :member)
    projects.each { |project| create(:project_membership, account: account, project: project) }
    account
  end

  let(:account_a) { member_seeing(shared, private_a) }
  let(:account_b) { member_seeing(shared) }
  # DM tra A e B → audience = [A, B], intersezione = [shared].
  let(:conversation) do
    Chat::Conversations::FindOrCreateDirect.call(organization: org, account_a: account_a, account_b: account_b).value
  end

  it "crea il messaggio e aggiorna last_message_at" do
    result = described_class.call(conversation: conversation, author: account_a, params: { body: "ciao" })
    expect(result).to be_ok
    message = result.value
    expect(message.body).to eq("ciao")
    expect(conversation.reload.last_message_at).to eq(message.created_at)
  end

  it "persiste solo le risorse taggate nell'intersezione" do
    common_ticket = create(:ticket, organization: org, project: shared)
    private_ticket = create(:ticket, organization: org, project: private_a)
    body = "vedi ##{common_ticket.code} e ##{private_ticket.code}"

    result = described_class.call(conversation: conversation, author: account_a, params: { body: body })
    expect(result).to be_ok
    referables = result.value.references.map(&:referable)
    expect(referables).to contain_exactly(common_ticket)
  end

  it "senza tag non crea riferimenti" do
    result = described_class.call(conversation: conversation, author: account_a, params: { body: "solo testo" })
    expect(result.value.references).to be_empty
  end

  it "rifiuta un messaggio vuoto (R422-CHAT-010)" do
    result = described_class.call(conversation: conversation, author: account_a, params: { body: "   " })
    expect(result).to be_err
    expect(result.error.code).to eq("R422-CHAT-010")
  end

  it "accoda il fan-out delle notifiche" do
    expect do
      described_class.call(conversation: conversation, author: account_a, params: { body: "ciao" })
    end.to have_enqueued_job(Chat::NotifyJob)
  end
end
