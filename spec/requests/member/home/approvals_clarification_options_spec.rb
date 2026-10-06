# frozen_string_literal: true

require "rails_helper"

# CYRA-887 — the agent proposes answers; the approver picks one with a click.
RSpec.describe "Member::Home::Approvals clarification options", type: :request do
  let(:org) { create(:organization) }
  let(:owner) { create(:account) }
  let(:project) { create(:project, organization: org) }
  let(:questions) do
    [ { "body" => "Il resoconto va spedito per email o solo mostrato?",
        "options" => [ { "label" => "Solo mostrato", "recommended" => true }, { "label" => "Email ogni lunedì" } ] },
      "La settimana parte da lunedì?" ]
  end

  before do
    create(:membership, account: owner, organization: org, role: :owner)
    org.update_column(:cto_id, owner.id)
  end

  def sign_in(account)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  def page = Nokogiri::HTML(response.body)

  def clarification
    @clarification ||= begin
      ticket = create(:ticket, organization: org, project:, reviewer: owner)
      workflow = create(:agent_workflow, ticket:, triage_requested_at: 1.day.ago, triage_started_at: 1.day.ago)
      attempt = create(:agent_attempt, workflow:, organization: org, phase: "triage",
                                       result: { "contract_version" => 2, "questions" => questions })
      create(:agent_clarification, workflow:, attempt:, answered_at: nil,
                                   questions: questions)
    end
  end

  it "offers the proposed answers with the recommended one already picked" do
    sign_in(owner)

    get member_home_approvals_item_path(kind: "clarification", id: clarification.id)

    radios = page.css("input[type='radio'][name='answers[1]']")
    expect(radios.map { |radio| radio["value"] }).to eq([ "Solo mostrato", "Email ogni lunedì", "" ])
    expect(radios.first["checked"]).to be_present
    expect(radios.map { |radio| radio["form"] }.uniq).to eq([ "approvals-reply-form" ])
    expect(page.css("input[name='answers[2]']")).to be_empty
    expect(page.at_css("[data-test='approvals-reply-text']")["required"]).to be_nil
  end

  # CYRA-1033 — up to four proposed answers, and one line on why the recommended one.
  context "with four proposed answers and a reason" do
    let(:questions) do
      [ { "body" => "Cosa succede se il peso manca?",
          "options" => [ { "label" => "Errore chiaro", "recommended" => true, "reason" => "Il prezzo negativo fa già così." },
                         { "label" => "Costo zero" }, { "label" => "Peso minimo" }, { "label" => "Chiedi il peso" } ] } ]
    end

    it "offers all four and shows the reason" do
      sign_in(owner)

      get member_home_approvals_item_path(kind: "clarification", id: clarification.id)

      values = page.css("input[type='radio'][name='answers[1]']").map { |radio| radio["value"] }
      expect(values).to eq([ "Errore chiaro", "Costo zero", "Peso minimo", "Chiedi il peso", "" ])
      expect(page.at_css("[data-test='approvals-clarification-reason']").text).to eq("Il prezzo negativo fa già così.")
    end
  end

  it "turns the picked answers and the free text into one reply" do
    sign_in(owner)
    clarification

    # Each answered question re-checks the author's membership (tenant validation, at most 3 per round).
    allow_n_plus_one do
      post member_home_approvals_decision_path,
           params: { item: "clarification:#{clarification.id}", decision: "reply",
                     answers: { "1" => "Solo mostrato" }, text: "2. Sì, da lunedì." }
    end

    expect(clarification.workflow.ticket.comments.order(:created_at).last.body).to eq("1. Solo mostrato\n2. Sì, da lunedì.")
  end

  it "still requires some text when nothing was picked" do
    sign_in(owner)
    clarification

    expect do
      post member_home_approvals_decision_path,
           params: { item: "clarification:#{clarification.id}", decision: "reply", answers: { "1" => "" }, text: "" }
    end.not_to change(Ticketing::Comment, :count)
  end
end
