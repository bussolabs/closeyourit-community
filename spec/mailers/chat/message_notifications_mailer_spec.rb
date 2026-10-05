# frozen_string_literal: true

require "rails_helper"

RSpec.describe Chat::MessageNotificationsMailer, type: :mailer do
  it "renderizza la notifica dalla view sotto mails/chat/ (path proc)" do
    org = create(:organization)
    author = create(:account, name: "Alice")
    recipient = create(:account)
    [ author, recipient ].each { |account| create(:membership, account: account, organization: org, role: :member) }

    conversation = create(:chat_conversation, :direct, organization: org)
    create(:chat_participant, conversation: conversation, account: recipient)
    message = create(:chat_message, conversation: conversation, author: author, body: "ciao mondo")

    notification = Alerting::Notification.create!(
      organization: org, account: recipient, subject: message, rule: nil, via: :email,
      event_type: :chat_message, title: "Nuovo messaggio da Alice", body: "ciao mondo",
      url: Rails.application.routes.url_helpers.member_chat_conversation_path(conversation),
      dedup_key: "chat:#{message.id}:#{recipient.id}:email", status: :pending
    )

    mail = described_class.notify(notification)
    expect(mail.to).to eq([ recipient.email ])
    expect(mail.body.encoded).to include("Nuovo messaggio da Alice")
    expect(mail.body.encoded).to include("ciao mondo")
    expect(mail.html_part.decoded).to include(%(href="http://example.com#{notification.url}"))
    expect(mail.text_part.decoded).to include("http://example.com#{notification.url}")
  end

  it "gestisce un messaggio senza autore (account cancellato)" do
    org = create(:organization)
    recipient = create(:account)
    create(:membership, account: recipient, organization: org, role: :member)
    conversation = create(:chat_conversation, :direct, organization: org)
    message = create(:chat_message, conversation: conversation)
    message.update_columns(author_id: nil) # simula autore cancellato (nullify)

    notification = Alerting::Notification.create!(
      organization: org, account: recipient, subject: message.reload, rule: nil, via: :email,
      event_type: :chat_message, title: "Nuovo messaggio", body: "orfano", url: "/x",
      dedup_key: "chat:#{message.id}:#{recipient.id}:email", status: :pending
    )

    mail = described_class.notify(notification)
    expect(mail.to).to eq([ recipient.email ])
  end
end
