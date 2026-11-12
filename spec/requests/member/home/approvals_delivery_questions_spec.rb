# frozen_string_literal: true

require "rails_helper"

# CYRA-1288 — the questions a delivery leaves open are answered from its card, one at a time.
RSpec.describe "Member::Home::Approvals delivery questions", type: :request do
  let(:org) { create(:organization) }
  let(:owner) { create(:account) }
  let(:project) { create(:project, organization: org) }
  let(:ticket) do
    create(:ticket, organization: org, project:, reviewer: owner,
                    status: create(:ticket_status, :in_review, organization: org))
  end

  before { create(:membership, account: owner, organization: org, role: :owner) }

  def sign_in(account)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  def page = Nokogiri::HTML(response.body)

  def ask(body, created_at:, options: [])
    create(:ticket_question, :from_agent, ticket:, organization: org, body:, created_at:,
                             options: options.map { |label| { "label" => label } })
  end

  def open_card = get(member_home_approvals_item_path(kind: "review", id: ticket.id))

  it "shows the first open question only, with its proposed answers and how many are left" do
    ask("Teniamo fisse le categorie di sistema?", created_at: 2.minutes.ago, options: %w[Sì No])
    ask("Le etichette delle email restano?", created_at: 1.minute.ago)
    sign_in(owner)

    open_card

    block = page.at_css("[data-test='approvals-delivery-questions']")
    expect(block.text).to include("Teniamo fisse le categorie di sistema?")
    expect(block.text).not_to include("Le etichette delle email restano?")
    expect(block.at_css("[data-test='approvals-question-counter']").text.squish)
      .to eq(I18n.t("member.approvals.delivery_questions.counter", current: 1, total: 2))
    expect(block.css("[data-test^='approvals-question-choice-']").size).to eq(2)
    expect(page.at_css("[data-test='approvals-questions-missing']").text.squish)
      .to eq(I18n.t("member.approvals.delivery_questions.missing", count: 2))
  end

  it "comes back to the card after an answer and moves on to the next question" do
    first = ask("Teniamo fisse le categorie di sistema?", created_at: 2.minutes.ago, options: %w[Sì No])
    ask("Le etichette delle email restano?", created_at: 1.minute.ago)
    sign_in(owner)

    post member_ticket_question_answers_path(ticket, first), params: { choice: 1, approval: "review:#{ticket.id}" }

    expect(response).to redirect_to(member_home_approvals_item_path(kind: "review", id: ticket.id))
    follow_redirect!
    block = page.at_css("[data-test='approvals-delivery-questions']")
    expect(block.at_css("[data-test='approvals-question-current']").text).to include("Le etichette delle email restano?")
    expect(block.at_css("[data-test='approvals-question-answered']").text.squish).to include("Teniamo fisse le categorie di sistema?", "Sì")
  end

  it "ignores a return address that is not an approval card" do
    question = ask("Teniamo fisse le categorie di sistema?", created_at: 1.minute.ago)
    sign_in(owner)

    post member_ticket_question_answers_path(ticket, question), params: { body: "Sì", approval: "https://example.com" }

    expect(response).to redirect_to(member_ticket_path(ticket, tab: "questions"))
  end

  it "says nothing about questions when the delivery left none" do
    sign_in(owner)

    open_card

    expect(page.at_css("[data-test='approvals-delivery-questions']")).to be_nil
    expect(page.at_css("[data-test='approvals-questions-missing']")).to be_nil
  end
end
