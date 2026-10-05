# frozen_string_literal: true

require "rails_helper"

# CYRA-845 — collegamenti fra idee dalla pagina idea.
RSpec.describe "Member::Ideas::Links", type: :request do
  let(:org) { create(:organization) }
  let(:owner) { create(:account) }
  let(:member) { create(:account) }
  let(:project) { create(:project, organization: org) }
  let(:idea) { create(:idea, organization: org, project: project) }
  let(:other) { create(:idea, organization: org, project: project, title: "Idea cugina") }

  before do
    create(:membership, account: owner, organization: org, role: :owner)
    create(:membership, account: member, organization: org, role: :member)
    create(:project_membership, account: member, project: project)
  end

  def sign_in(account)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  describe "POST create" do
    it "owner collega due idee alla pari → redirect con notice" do
      sign_in(owner)
      expect do
        post member_idea_links_path(idea), params: { target_id: other.id }
      end.to change(Ideas::Link, :count).by(1)
      expect(response).to redirect_to(member_idea_path(idea))
      expect(idea.reload.related_ideas).to eq([ other ])
    end

    it "l'autore dell'idea collega (bypass permessi)" do
      author = idea.author
      create(:project_membership, account: author, project: project)
      sign_in(author)
      expect do
        post member_idea_links_path(idea), params: { target_id: other.id }
      end.to change(Ideas::Link, :count).by(1)
    end

    it "membro senza ideas.edit (non autore) → negato" do
      sign_in(member)
      expect do
        post member_idea_links_path(idea), params: { target_id: other.id }
      end.not_to change(Ideas::Link, :count)
      expect(response).to have_http_status(:redirect)
    end

    it "target di un altro progetto → nessun link, redirect con alert (anti-BOLA)" do
      foreign = create(:idea, organization: org)
      sign_in(owner)
      expect do
        post member_idea_links_path(idea), params: { target_id: foreign.id }
      end.not_to change(Ideas::Link, :count)
      expect(flash[:alert]).to be_present
    end
  end

  describe "DELETE destroy" do
    it "scollega anche dal lato che non ha scritto la riga" do
      create(:idea_link, source: other, target: idea)
      sign_in(owner)
      expect do
        delete member_idea_link_path(idea, other)
      end.to change(Ideas::Link, :count).by(-1)
      expect(response).to redirect_to(member_idea_path(idea))
    end
  end

  describe "pagina idea" do
    it "mostra evoluzioni, idee collegate e il filo verso la base" do
      base = create(:idea, organization: org, project: project, title: "Idea madre")
      create(:idea_link, :evolution, source: idea, target: base)
      create(:idea_link, source: other, target: idea)
      sign_in(owner)

      get member_idea_path(idea)
      expect(response.body).to include('data-test="idea-parent"', "Idea madre", "Idea cugina")
      # Un'evoluzione non ha il pulsante «Proponi evoluzione» (un solo livello).
      expect(response.body).not_to include('data-test="idea-propose-evolution"')

      get member_idea_path(base)
      expect(response.body).to include('data-test="idea-propose-evolution"')
      expect(response.body).to include("member-idea-evolution-#{idea.id}")
    end

    it "monetizzazione e rischi compaiono come pannelli, e non se vuoti" do
      sign_in(owner)
      get member_idea_path(idea)
      expect(response.body).not_to include('data-test="idea-monetization"')

      idea.update!(monetization: "Boost a pagamento", risks: "Serve la moderazione")
      get member_idea_path(idea)
      expect(response.body).to include('data-test="idea-monetization"', "Boost a pagamento",
                                       'data-test="idea-risks"', "Serve la moderazione")
    end
  end

  describe "proporre un'evoluzione dal form" do
    it "GET new con evolves_id mostra il banner e blocca il progetto" do
      sign_in(owner)
      get new_member_idea_path(evolves_id: idea.id)
      expect(response.body).to include('data-test="idea-evolution-banner"', idea.title, 'data-test="idea-project-locked"')
    end

    it "POST create con evolves_id crea l'idea già collegata, con monetizzazione e rischi" do
      sign_in(owner)
      post member_ideas_path, params: { project_id: project.id, title: "Tavoli", problem: "Con chi ci vado?",
                                        monetization: "Boost", risks: "Moderazione", evolves_id: idea.id }
      created = Ideas::Idea.order(:created_at).last
      expect(created.parent).to eq(idea)
      expect(created).to have_attributes(monetization: "Boost", risks: "Moderazione")
      expect(response).to redirect_to(member_idea_path(created))
    end

    it "evolves_id di un'altra org viene ignorato in GET e rifiutato in POST" do
      foreign = create(:idea)
      sign_in(owner)
      get new_member_idea_path(evolves_id: foreign.id)
      expect(response.body).not_to include('data-test="idea-evolution-banner"')

      expect do
        post member_ideas_path, params: { project_id: project.id, title: "x", problem: "y", evolves_id: foreign.id }
      end.not_to change(Ideas::Idea, :count)
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "la lista mostra la chip Evoluzione" do
      base = create(:idea, organization: org, project: project)
      create(:idea_link, :evolution, source: idea, target: base)
      sign_in(owner)
      get member_ideas_path
      expect(response.body.scan('data-test="idea-evolution-chip"').size).to eq(1)
    end
  end
end
