# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Assistant todo and idea proposal tools" do
  let(:organization) { create(:organization) }
  let(:account) do
    create(:account).tap { |a| create(:membership, account: a, organization: organization, role: :owner) }
  end
  let(:project) { create(:project, organization: organization, key: "CYRA") }
  let(:conversation) { Assistant::Conversation.create!(account: account, organization: organization) }
  let(:reply) { conversation.messages.create!(organization: organization, role: :assistant, status: :streaming) }
  let(:context) do
    Assistant::Tools::Context.new(account: account, organization: organization, project_ids: [ project.id ],
                                  group_ids: [], full_access: false, reply_message_id: reply.id)
  end

  def run(tool, args) = tool.new(context: context).call(args)

  it "proposes a todo on the named list" do
    list = create(:todo_list, account: account, organization: organization, name: "Personale")

    expect { run(Assistant::Tools::ProposeTodo, { "title" => "Call the accountant", "list" => "personale" }) }
      .not_to change(Todos::Item, :count)

    expect(reply.proposals.sole.payload).to include("list_id" => list.id, "title" => "Call the accountant")
  end

  it "falls back to the first list" do
    first = create(:todo_list, account: account, organization: organization, name: "Inbox", position: 0)

    run(Assistant::Tools::ProposeTodo, { "title" => "x" })

    expect(reply.proposals.sole.payload["list_id"]).to eq(first.id)
  end

  it "says so when the person has no list" do
    expect(run(Assistant::Tools::ProposeTodo, { "title" => "x" })[:error]).to be_present
  end

  it "proposes an idea with similar ideas" do
    allow(Ideas::FindSimilarIdeas).to receive(:call).and_return(Result.ok([]))

    expect { run(Assistant::Tools::ProposeIdea, { "project" => "CYRA", "title" => "Dark mode", "problem" => "Eyes hurt" }) }
      .not_to change(Ideas::Idea, :count)

    expect(reply.proposals.sole.payload).to include("project_id" => project.id, "similar" => [])
  end
end
