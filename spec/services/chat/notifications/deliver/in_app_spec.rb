# frozen_string_literal: true

require "rails_helper"

RSpec.describe Chat::Notifications::Deliver do
  let(:org) { create(:organization) }
  let(:shared) { create(:project, organization: org) }

  def member_seeing(*projects)
    account = create(:account)
    create(:membership, account: account, organization: org, role: :member)
    projects.each { |project| create(:project_membership, account: account, project: project) }
    account
  end

  let(:author) { member_seeing(shared) }
  let(:recipient) { member_seeing(shared) }
  let(:conversation) do
    Chat::Conversations::FindOrCreateDirect.call(organization: org, account_a: author, account_b: recipient).value
  end
  let(:message) { conversation.messages.create!(body: "ciao", author: author, organization_id: org.id) }
  let(:content) do
    Chat::Notifications::Content.new(title: "Nuovo messaggio", body: "ciao", url: "/member/chat/conversations/#{conversation.id}")
  end

  def deliver(dedup_key: "chat:#{message.id}:#{recipient.id}:in_app")
    described_class.in_app(
      account: recipient, message: message, organization: org,
      event_type: :chat_message, content: content, dedup_key: dedup_key
    )
  end

  it "crea la notifica in-app già sent" do
    result = deliver
    expect(result).to be_ok
    expect(result.value.via).to eq("in_app")
    expect(result.value.status).to eq("sent")
  end

  it "broadcasta la riga E il badge sullo stream per-account delle notifiche" do
    prepends = []
    replaces = []
    allow(Turbo::StreamsChannel).to receive(:broadcast_prepend_to) { |stream, **opts| prepends << [ stream, opts ] }
    allow(Turbo::StreamsChannel).to receive(:broadcast_replace_to) { |stream, **opts| replaces << [ stream, opts ] }

    deliver

    stream = "alerting:notifications:#{recipient.id}"
    expect(prepends.length).to eq(1)
    expect(prepends.first[0]).to eq(stream)
    expect(prepends.first[1]).to include(target: "notifications",
                                         partial: "member/alerting_notifications/notification")
    expect(replaces.length).to eq(1)
    expect(replaces.first[0]).to eq(stream)
    expect(replaces.first[1]).to include(target: "alerting_notification_badge",
                                         partial: "member/alerting_notifications/badge")
    expect(replaces.first[1][:locals]).to include(count: 1)
  end

  it "dedup_key duplicata → Result.err con AppError R409-CHAT-011, nessun secondo broadcast" do
    deliver
    prepends = []
    allow(Turbo::StreamsChannel).to receive(:broadcast_prepend_to) { |stream, **opts| prepends << [ stream, opts ] }

    result = deliver
    expect(result).to be_err
    expect(result.error).to be_a(AppError)
    expect(result.error.code).to eq("R409-CHAT-011")
    expect(prepends).to be_empty
  end
end
