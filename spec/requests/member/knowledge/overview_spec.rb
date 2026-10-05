# frozen_string_literal: true

require "rails_helper"

# CYRA-415 — La pagina d'ingresso dell'area Conoscenza è un indice che INSEGNA, non tre voci parallele
# senza spiegazione. Per ciascun passo del flusso — Revisione, Conoscenza, Book, nell'ordine d'uso reale
# — una definizione di una riga, un contatore vivo e l'azione tipica. Sola lettura; i contatori seguono
# lo scoping per-membro (nessun conteggio dei progetti che l'utente non vede).
RSpec.describe "Member::Knowledge::Overview", type: :request do
  let(:org) { create(:organization) }
  let(:owner) { create(:account) }
  let(:member) { create(:account) }
  let(:project) { create(:project, organization: org) }

  before do
    create(:membership, account: owner, organization: org, role: :owner)
    create(:membership, account: member, organization: org, role: :member)
    create(:project_membership, account: member, project: project)
  end

  def sign_in(account)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  describe "GET /member/knowledge" do
    it "ogni voce porta alla sua sezione con un clic" do
      sign_in(owner)

      get member_knowledge_root_path

      expect(response.body).to include(member_knowledge_reviews_path)
      expect(response.body).to include(member_knowledge_pages_path)
      expect(response.body).to include(member_knowledge_books_path)
    end

    it "i contatori rispettano lo scoping: un membro non conta i progetti che non vede" do
      hidden = create(:project, organization: org)
      create(:knowledge_page, organization: org, project: hidden, title: "Pagina segreta")
      create(:knowledge_book, organization: org, project: hidden, title: "Book segreto")
      sign_in(member)

      get member_knowledge_root_path

      expect(response).to have_http_status(:ok)
      doc = Nokogiri::HTML(response.body)
      expect(doc.at_css('[data-test="knowledge-overview-stat-pages"]').text).to include("0")
      expect(doc.at_css('[data-test="knowledge-overview-stat-books"]').text).to include("0")
      expect(doc.at_css(%([data-test="knowledge-row-#{hidden.id}"]))).to be_nil
    end
  end

  describe "sidebar dell'area Conoscenza" do
    it "apre con la Panoramica e poi le tre voci nell'ordine del percorso" do
      sign_in(owner)

      get member_knowledge_root_path

      body = response.body
      pos_overview  = body.index('data-test="member-nav-knowledge-overview"')
      pos_review    = body.index('data-test="member-nav-knowledge-review"')
      pos_knowledge = body.index('data-test="member-nav-knowledge"')
      pos_book      = body.index('data-test="member-nav-book"')
      expect([ pos_overview, pos_review, pos_knowledge, pos_book ]).to all(be_present)
      expect(pos_overview).to be < pos_review
      expect(pos_review).to be < pos_knowledge
      expect(pos_knowledge).to be < pos_book
    end
  end
end
