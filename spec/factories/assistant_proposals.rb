# frozen_string_literal: true

FactoryBot.define do
  factory :assistant_proposal, class: "Assistant::Proposal" do
    message { association :assistant_message, role: :assistant, status: :complete, content: "ok" }
    organization { message.organization }
    account { message.conversation.account }
    kind { :create_todo }
    payload { { "title" => "Call the accountant", "list_id" => nil, "list_name" => "Personal" } }
  end
end
