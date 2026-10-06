# frozen_string_literal: true

require "rails_helper"

# Withdrawing a question drops it for good: the button is the design system's destructive one, the
# same size as «Reply» next to it.
RSpec.describe "Member ticket question withdraw button", type: :request do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let(:ticket) { create(:ticket, organization:, project:) }
  let(:manager) do
    create(:account).tap do |account|
      create(:membership, :owner, organization:, account:)
      create(:project_membership, account:, project:)
    end
  end

  it "renders withdraw as a red design-system button that still asks for confirmation" do
    question = Ticketing::Question.create!(ticket:, author: manager, body: "Which way?")
    post login_path, params: { email: manager.email, password: "Secret123!" }

    get member_ticket_path(ticket, tab: "questions")

    button = Nokogiri::HTML(response.body).at_css("[data-test='ticket-question-close-#{question.id}']")
    expect(button).to be_present
    expect(button["class"]).to include("text-red-600", "h-[34px]")
    expect(button["data-turbo-confirm"]).to eq(I18n.t("member.tickets.questions.close_confirm"))
    expect(button.ancestors("form").first["action"]).to eq(member_ticket_question_closure_path(ticket, question))
  end
end
