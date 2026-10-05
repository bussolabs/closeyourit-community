# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Assistant proposal cards", type: :system do
  let(:org) { create(:organization) }
  let(:account) { create(:account).tap { |a| create(:membership, account: a, organization: org, role: :owner) } }
  let(:project) { create(:project, organization: org, key: "CYFL") }
  let(:conversation) { Assistant::Conversation.create!(account: account, organization: org) }
  let(:reply) do
    conversation.messages.create!(organization: org, role: :assistant, status: :complete, content: "Two actions ready.")
  end

  def label(key) = I18n.t("member.assistant.proposals.#{key}", locale: account.effective_locale)

  before do
    driven_by(:rack_test)
    create(:ticket_status, organization: org, code: "open", label: "Open")
    create(:ticket_priority, organization: org, code: "medium", label: "Medium")
    %w[First Second].each do |title|
      Assistant::Proposal.create!(message: reply, organization: org, account: account, kind: :create_ticket,
                                  payload: { "project_id" => project.id, "project_key" => "CYFL", "title" => title,
                                             "description" => "Body", "ticket_kind" => "bug", "similar" => [] })
    end
    sign_in_as(account)
  end

  it "confirms both cards with one click" do
    visit member_assistant_conversation_path(conversation)

    find("[data-test='assistant-proposals-confirm-all']").click
    visit member_assistant_conversation_path(conversation)

    expect(page).to have_css("[data-test='assistant-proposal'][data-status='confirmed']", count: 2)
    expect(project.tickets.pluck(:title)).to contain_exactly("First", "Second")
  end

  it "discards a card and brings it back" do
    visit member_assistant_conversation_path(conversation)

    within(first("[data-test='assistant-proposal']")) { click_button label("discard") }
    expect(page).to have_css("[data-status='discarded']", count: 1)
    click_button label("restore")
    expect(page).to have_no_css("[data-status='discarded']")
  end
end
