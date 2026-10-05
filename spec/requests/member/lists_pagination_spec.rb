# frozen_string_literal: true

require "rails_helper"

# CYRA-684 — quindici elenchi caricavano tutto in memoria: la pagina delle attenzioni del vault era
# arrivata a 37 schermate. Qui si presidia che gli elenchi bonificati restino a pagine: un primo
# blocco, il pager, e il chip che dice il totale vero (mai il conteggio della sola pagina).
RSpec.describe "Member — elenchi a pagine (CYRA-684)", type: :request do
  let(:org) { create(:organization) }
  let(:owner) { create(:account) }

  # The assistant list leaves out conversations without messages: these have one.
  before do
    create(:membership, account: owner, organization: org, role: :owner)
    post login_path, params: { email: owner.email, password: "Secret123!" }
  end

  it "le conversazioni con l'assistente arrivano a pagine, col totale pieno" do
    allow_n_plus_one do
      create_list(:assistant_conversation, Pagination::DEFAULT_PER + 3, account: owner, organization: org,
                                                                       last_message_at: Time.current)
    end

    get member_assistant_conversations_path

    html = Capybara.string(response.body)
    aggregate_failures do
      expect(html).to have_css("[data-test='assistant-conversation-link']", count: Pagination::DEFAULT_PER)
      expect(html).to have_css("[data-test='assistant-conversations-pagination']")
      expect(html.find("[data-test='stat-conversations']")).to have_text((Pagination::DEFAULT_PER + 3).to_s)
    end
  end

  it "la seconda pagina mostra le conversazioni rimanenti" do
    allow_n_plus_one do
      create_list(:assistant_conversation, Pagination::DEFAULT_PER + 3, account: owner, organization: org,
                                                                       last_message_at: Time.current)
    end

    get member_assistant_conversations_path(page: 2)

    expect(Capybara.string(response.body))
      .to have_css("[data-test='assistant-conversation-link']", count: 3)
  end
end
