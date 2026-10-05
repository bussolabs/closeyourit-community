# frozen_string_literal: true

require "rails_helper"

RSpec.describe Assistant::StartReply do
  let(:conversation) { create(:assistant_conversation) }
  let(:question) do
    conversation.messages.create!(organization: conversation.organization, role: :user, status: :complete,
                                  content: "my tickets?")
  end

  it "creates the empty reply after the question and queues the tool loop (CYRA-908)" do
    result = nil
    expect { result = described_class.call(question: question) }
      .to have_enqueued_job(Assistant::ConverseJob).with(hash_including(question_id: question.id))

    reply = result.value
    expect(reply).to be_role_assistant
    expect(reply).to be_status_streaming
    expect(conversation.reload.last_message_at).to be_within(1.second).of(reply.created_at)
  end

  it "narrows the scope to the project the conversation is fixed on" do
    project = create(:project, organization: conversation.organization)
    create(:project, organization: conversation.organization)
    create(:membership, account: conversation.account, organization: conversation.organization, role: :owner)
    conversation.update!(project: project)

    expect { described_class.call(question: question) }
      .to have_enqueued_job(Assistant::ConverseJob)
      .with(hash_including(project_ids: [ project.id ], group_ids: [], full_access: false))
  end

  it "reads nothing when the project it is fixed on is no longer visible" do
    conversation.update!(project: create(:project, organization: create(:organization)))

    expect { described_class.call(question: question) }
      .to have_enqueued_job(Assistant::ConverseJob).with(hash_including(project_ids: [], full_access: false))
  end

  it "queues the streaming job when the tool loop is off" do
    Settings::Global.instance.update!(ai_assistant_tools_enabled: false)
    expect { described_class.call(question: question) }.to have_enqueued_job(Assistant::StreamReplyJob)
  end
end
