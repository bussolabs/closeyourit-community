# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Member::Ideas::Comments", type: :request do
  let(:org) { create(:organization) }
  let(:owner) { create(:account) }
  let(:member) { create(:account) }
  let(:outsider) { create(:account) }
  let(:project) { create(:project, organization: org) }
  let(:idea) { create(:idea, organization: org, project: project) }

  before do
    create(:membership, account: owner, organization: org, role: :owner)
    create(:membership, account: member, organization: org, role: :member)
    create(:membership, account: outsider, organization: org, role: :member)
    create(:project_membership, account: member, project: project)
  end

  def sign_in(account)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  describe "POST create" do
    it "non autenticato → redirect login" do
      post member_idea_comments_path(idea), params: { body: "ciao" }
      expect(response).to redirect_to(login_path)
    end

    it "membro con accesso commenta → comments_count +1" do
      sign_in(member)
      expect do
        post member_idea_comments_path(idea), params: { body: "Ottima idea" }
      end.to change { idea.reload.comments_count }.by(1)
      expect(response).to redirect_to(member_idea_path(idea))
    end

    # CYRA-371 — prima il campo si fermava allo spazio di un messaggio brevissimo e un intervento
    # argomentato tornava indietro come errore dopo essere stato scritto.
    it "un intervento argomentato di qualche migliaio di caratteri viene salvato per intero" do
      sign_in(member)
      testo = "x" * 3_000

      expect do
        post member_idea_comments_path(idea), params: { body: testo }
      end.to change { idea.reload.comments_count }.by(1)

      expect(flash[:alert]).to be_nil
      expect(Ideas::Comment.last.body).to eq(testo)
    end

    # Il testo rifiutato torna nel campo con la pagina resa sul posto: passandolo per il cookie di
    # sessione (com'era prima) un intervento di qualche migliaio di caratteri sfonderebbe i 4 KB del
    # cookie e la risposta sarebbe un errore del server.
    it "oltre il tetto → nessun commento, pagina riproposta col testo ancora nel campo" do
      sign_in(member)
      testo = "x" * (Ideas::Constants::COMMENT_MAX_CHARS + 1)

      expect do
        post member_idea_comments_path(idea), params: { body: testo }
      end.not_to change(Ideas::Comment, :count)

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include(testo)
      expect(flash[:alert]).to be_present
    end

    it "un testo lungo ma rifiutato per altro motivo non fa saltare la sessione" do
      sign_in(member)
      frozen = create(:idea, :archived, organization: org, project: project)

      post member_idea_comments_path(frozen), params: { body: "x" * 3_000 }

      expect(response).to have_http_status(:unprocessable_content)
      expect(flash[:alert]).to be_present
    end

    it "corpo vuoto → nessun commento, pagina riproposta con alert" do
      sign_in(member)
      expect do
        post member_idea_comments_path(idea), params: { body: "   " }
      end.not_to change(Ideas::Comment, :count)
      expect(response).to have_http_status(:unprocessable_content)
      expect(flash[:alert]).to be_present
    end

    it "idea congelata → nessun commento (R422-IDEA-002 dal service)" do
      frozen = create(:idea, :archived, organization: org, project: project)
      sign_in(member)
      expect do
        post member_idea_comments_path(frozen), params: { body: "tardi" }
      end.not_to change(Ideas::Comment, :count)
      expect(response).to have_http_status(:unprocessable_content)
      expect(flash[:alert]).to be_present
    end

    it "membro senza accesso al progetto → 404 (BOLA)" do
      sign_in(outsider)
      post member_idea_comments_path(idea), params: { body: "x" }
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "DELETE destroy" do
    let!(:comment) { create(:idea_comment, idea: idea, organization: org) }

    it "l'autore del commento lo elimina" do
      author = comment.author
      create(:project_membership, account: author, project: project)
      sign_in(author)
      expect { delete member_idea_comment_path(idea, comment) }.to change(Ideas::Comment, :count).by(-1)
    end

    it "un altro membro senza ideas.comment.delete_any NON elimina" do
      sign_in(member)
      expect { delete member_idea_comment_path(idea, comment) }.not_to change(Ideas::Comment, :count)
      expect(flash[:alert]).to be_present
    end

    it "owner (delete_any) elimina il commento altrui" do
      sign_in(owner)
      expect { delete member_idea_comment_path(idea, comment), params: { confirm: "1" } }
        .to change(Ideas::Comment, :count).by(-1)
    end

    it "idea congelata → il commento resta (fonte della sintesi AI)" do
      idea.update!(status: :archived)
      sign_in(owner)
      expect { delete member_idea_comment_path(idea, comment), params: { confirm: "1" } }
        .not_to change(Ideas::Comment, :count)
      expect(flash[:alert]).to be_present
    end
  end
end
