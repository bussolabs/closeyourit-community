# frozen_string_literal: true

require "rails_helper"

RSpec.describe Chat::UpdateMessage do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let(:author) { create(:account) }
  let(:recipient) { create(:account) }
  let(:conversation) do
    Chat::Conversations::FindOrCreateDirect.call(organization:, account_a: author, account_b: recipient).value
  end
  let(:message) { create(:chat_message, conversation:, author:, body: "Original") }

  before do
    [ author, recipient ].each do |account|
      create(:membership, account:, organization:, role: :member)
      create(:project_membership, account:, project:)
    end
  end

  def update(body:, actor: author, stamp: message.updated_at.iso8601(6))
    described_class.call(message:, author: actor, body:, expected_updated_at: stamp)
  end

  it "replaces references with resources visible to the whole audience" do
    ticket = create(:ticket, organization:, project:)
    private_project = create(:project, organization:)
    create(:project_membership, account: author, project: private_project)
    private_ticket = create(:ticket, organization:, project: private_project)

    expect(update(body: "See ##{ticket.code} and ##{private_ticket.code}")).to be_ok
    expect(message.references.reload.map(&:referable)).to contain_exactly(ticket)
    expect(update(body: "No references")).to be_ok
    expect(message.references.reload).to be_empty
  end

  it "does not change the conversation order or send another notification" do
    original_time = 1.day.ago
    conversation.update!(last_message_at: original_time)
    message
    expect { expect(update(body: "Corrected")).to be_ok }.not_to have_enqueued_job(Chat::NotifyJob)
    expect(conversation.reload.last_message_at).to be_within(0.000001).of(original_time)
  end

  it "broadcasts only the content so existing author controls survive" do
    expect(Turbo::StreamsChannel).to receive(:broadcast_replace_to).with(
      Realtime::Streams.chat_conversation(conversation),
      target: ActionView::RecordIdentifier.dom_id(message, :content),
      partial: "member/chat_conversations/message_content", locals: { message: }
    )
    expect(update(body: "Corrected")).to be_ok
  end

  it "rejects edits by another participant in the service too" do
    expect(update(body: "Changed", actor: recipient)).to be_err
    expect(message.reload.body).to eq("Original")
  end

  it "rejects missing concurrency tokens" do
    expect(update(body: "Changed", stamp: nil)).to be_err
    expect(message.reload.body).to eq("Original")
  end

  it "allows removing text when the message still has an attachment" do
    message.files.attach(io: StringIO.new("fixture"), filename: "note.txt", content_type: "text/plain")
    message.reload

    expect(update(body: "")).to be_ok
    expect(message.reload.body).to be_nil
    expect(message.files).to be_attached
  end

  it "rejects a message deleted after the form was opened" do
    stamp = message.updated_at.iso8601(6)
    message.soft_delete!
    expect(update(body: "Changed", stamp:)).to be_err
    expect(message.reload).to be_deleted
  end
end
