# frozen_string_literal: true

require "rails_helper"

RSpec.describe Chat::Notifications::Deliver do
  include ActiveJob::TestHelper

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

  def deliver(quiet: false, dedup_key: "chat:#{message.id}:#{recipient.id}:email")
    described_class.email(
      account: recipient, message: message, organization: org,
      event_type: :chat_message, content: content, dedup_key: dedup_key, quiet: quiet
    )
  end

  it "crea la notifica email e accoda il mailer" do
    result = nil
    expect { result = deliver }
      .to have_enqueued_mail(Chat::MessageNotificationsMailer, :notify)
    expect(result).to be_ok
    expect(result.value.status).to eq("pending")
  end

  it "in quiet hours crea la riga trattenuta (:held) e NON accoda il mailer" do
    result = nil
    expect { result = deliver(quiet: true) }
      .not_to have_enqueued_mail(Chat::MessageNotificationsMailer, :notify)
    expect(result).to be_ok
    expect(result.value.status).to eq("held")
  end

  it "dedup_key duplicata → Result.err con AppError R409-CHAT-011, nessun secondo mailer" do
    deliver
    result = nil
    expect { result = deliver }
      .not_to change { Alerting::Notification.where(account_id: recipient.id, via: :email).count }
    expect(result).to be_err
    expect(result.error).to be_a(AppError)
    expect(result.error.code).to eq("R409-CHAT-011")
  end

  it "canale di progetto → la notifica porta il progetto; DM → nil" do
    owner = create(:account)
    create(:membership, account: owner, organization: org, role: :owner)
    channel = Chat::Conversations::FindOrCreateChannel.call(organization: org, contextable: shared, actor: owner).value
    channel_message = channel.messages.create!(body: "nel canale", author: owner, organization_id: org.id)

    dm_result = deliver
    channel_result = described_class.email(
      account: recipient, message: channel_message, organization: org,
      event_type: :chat_message, content: content, dedup_key: "chat:#{channel_message.id}:#{recipient.id}:email"
    )

    expect(dm_result.value.project_id).to be_nil
    expect(channel_result.value.project_id).to eq(shared.id)
  end
end
