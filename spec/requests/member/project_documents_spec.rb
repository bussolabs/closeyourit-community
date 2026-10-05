# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Member::ProjectDocuments", type: :request do
  let(:org) { create(:organization) }
  let(:owner) { create(:account) }
  let(:member) { create(:account) }
  let(:project) { create(:project, organization: org) }

  before do
    create(:membership, account: owner, organization: org, role: :owner)
    create(:membership, account: member, organization: org, role: :member)
    # Scoping Fase E: il member vede il progetto solo se assegnato.
    create(:project_membership, account: member, project: project)
  end

  def sign_in(account)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  def grant_manage(account)
    role = create(:role, organization: org, name: "Doc manager")
    create(:role_permission, role: role, permission_key: "documents.manage")
    create(:account_role, account: account, organization: org, role: role)
  end

  def upload(name, declared_type)
    Rack::Test::UploadedFile.new(Rails.root.join("spec/fixtures/files/#{name}"), declared_type)
  end

  describe "GET index" do
    it "non autenticato → redirect login" do
      get member_project_documents_path(project)
      expect(response).to redirect_to(login_path)
    end

    it "owner → 200" do
      sign_in(owner)
      get member_project_documents_path(project)
      expect(response).to have_http_status(:ok)
    end

    it "member assegnato (senza documents.manage) → 200: lettura = visibilità del progetto" do
      sign_in(member)
      get member_project_documents_path(project)
      expect(response).to have_http_status(:ok)
    end

    it "member non assegnato → 404 (scoping)" do
      other = create(:account)
      create(:membership, account: other, organization: org, role: :member)
      sign_in(other)
      get member_project_documents_path(project)
      expect(response).to have_http_status(:not_found)
    end

    it "progetto di un'altra org → 404 (anti-BOLA)" do
      sign_in(owner)
      foreign = create(:project, organization: create(:organization))
      get member_project_documents_path(foreign)
      expect(response).to have_http_status(:not_found)
    end

    it "filtra per tag (overlap multi-select)" do
      legal = create(:document, project: project, tags: %w[legal])
      spec = create(:document, project: project, tags: %w[spec])
      sign_in(owner)
      get member_project_documents_path(project), params: { tag: [ "legal" ] }
      expect(response.body).to include("document-row-#{legal.id}")
      expect(response.body).not_to include("document-row-#{spec.id}")
    end

    it "cerca per title E per filename originale (documento rinominato)" do
      renamed = create(:document, project: project, title: "Rinominato")
      other = create(:document, project: project, title: "Altro documento")
      sign_in(owner)

      get member_project_documents_path(project), params: { q: "spec.pdf" }
      expect(response.body).to include("document-row-#{renamed.id}")

      get member_project_documents_path(project), params: { q: "Altro" }
      expect(response.body).to include("document-row-#{other.id}")
      expect(response.body).not_to include("document-row-#{renamed.id}")
    end

    it "pagina: pagina 1 piena (TABLE_PER_PAGE righe) + footer, resto in pagina 2" do
      sign_in(owner)
      # Fixture bulk nel setup: l'attach della factory fa query attachment per-record — non è un
      # N+1 di produzione (la index preloada con with_attached_file).
      allow_n_plus_one { create_list(:document, App::Constants::TABLE_PER_PAGE + 1, project: project) }

      get member_project_documents_path(project), params: { page: 1 }
      expect(response.body.scan('data-test="document-row-').size).to eq(App::Constants::TABLE_PER_PAGE)
      expect(response.body).to include('data-test="documents-pagination"')

      get member_project_documents_path(project), params: { page: 2 }
      expect(response.body.scan('data-test="document-row-').size).to eq(1)
    end
  end

  describe "POST create (upload)" do
    it "owner: N file → N documenti con title = filename" do
      sign_in(owner)
      expect do
        # Upload batch: una risoluzione attachment per documento CREATO (insert per-record di
        # ActiveStorage) — lineare per natura, non un N+1 di lettura riducibile con preload.
        allow_n_plus_one do
          post member_project_documents_path(project),
               params: { files: [ upload("screenshot.png", "image/png"), upload("notes.txt", "text/plain") ] }
        end
      end.to change(project.documents, :count).by(2)
      expect(response).to redirect_to(member_project_documents_path(project))
      expect(project.documents.pluck(:title)).to contain_exactly("screenshot.png", "notes.txt")
      expect(project.documents.pluck(:created_by_id).uniq).to eq([ owner.id ])
    end

    it "member con documents.manage → ok" do
      grant_manage(member)
      sign_in(member)
      expect do
        post member_project_documents_path(project), params: { files: [ upload("notes.txt", "text/plain") ] }
      end.to change(project.documents, :count).by(1)
    end

    it "member senza documents.manage → redirect root, nessun record" do
      sign_in(member)
      expect do
        post member_project_documents_path(project), params: { files: [ upload("notes.txt", "text/plain") ] }
      end.not_to change(project.documents, :count)
      expect(response).to redirect_to(root_path)
    end

    it "progetto di un'altra org → 404" do
      sign_in(owner)
      foreign = create(:project, organization: create(:organization))
      post member_project_documents_path(foreign), params: { files: [ upload("notes.txt", "text/plain") ] }
      expect(response).to have_http_status(:not_found)
    end

    it "svg spoofato come png → alert, zero record (sniff Marcel)" do
      sign_in(owner)
      expect do
        post member_project_documents_path(project), params: { files: [ upload("diagram.svg", "image/png") ] }
      end.not_to change(project.documents, :count)
      expect(response).to redirect_to(member_project_documents_path(project))
      expect(flash[:alert]).to be_present
    end

    it "batch con un file invalido → zero record (all-or-nothing)" do
      sign_in(owner)
      expect do
        post member_project_documents_path(project),
             params: { files: [ upload("screenshot.png", "image/png"), upload("diagram.svg", "image/svg+xml") ] }
      end.not_to change(project.documents, :count)
    end

    it "senza file → alert" do
      sign_in(owner)
      post member_project_documents_path(project)
      expect(response).to redirect_to(member_project_documents_path(project))
      expect(flash[:alert]).to be_present
    end
  end

  describe "GET edit" do
    let(:document) { create(:document, project: project) }

    it "owner → 200" do
      sign_in(owner)
      get edit_member_project_document_path(project, document)
      expect(response).to have_http_status(:ok)
    end

    it "member senza documents.manage → redirect root" do
      sign_in(member)
      get edit_member_project_document_path(project, document)
      expect(response).to redirect_to(root_path)
    end

    it "documento di un progetto di un'altra org → 404" do
      sign_in(owner)
      foreign = create(:document)
      get edit_member_project_document_path(foreign.project, foreign)
      expect(response).to have_http_status(:not_found)
    end

    it "mostra il blocco Audit e la cronologia attività quando ci sono eventi" do
      Projects::Documents::Save.call(document: document, attributes: { title: "Rinominato" }, actor: owner)
      sign_in(owner)
      get edit_member_project_document_path(project, document)
      expect(response.body).to include("document-audit", "activity-modal")
    end
  end

  describe "PATCH update (rinomina + tag + descrizione)" do
    let(:document) { create(:document, project: project, title: "Vecchio nome") }

    it "owner: rinomina, tagga (csv normalizzato) e descrive" do
      sign_in(owner)
      patch member_project_document_path(project, document),
            params: { title: "  Contratto 2026  ", description: "nota", tags: " Legal, legal ,Q3, " }
      expect(response).to redirect_to(member_project_documents_path(project))
      document.reload
      expect(document.title).to eq("Contratto 2026")
      expect(document.description).to eq("nota")
      expect(document.tags).to eq(%w[legal q3])
    end

    it "title blank → 422 re-render edit" do
      sign_in(owner)
      patch member_project_document_path(project, document), params: { title: "   " }
      expect(response).to have_http_status(:unprocessable_content)
      expect(document.reload.title).to eq("Vecchio nome")
    end

    it "member con documents.manage → ok" do
      grant_manage(member)
      sign_in(member)
      patch member_project_document_path(project, document), params: { title: "Nuovo" }
      expect(document.reload.title).to eq("Nuovo")
    end

    it "member senza documents.manage → redirect root, invariato" do
      sign_in(member)
      patch member_project_document_path(project, document), params: { title: "Nuovo" }
      expect(response).to redirect_to(root_path)
      expect(document.reload.title).to eq("Vecchio nome")
    end
  end

  describe "DELETE destroy" do
    let!(:document) { create(:document, project: project) }

    it "owner: elimina e reindirizza" do
      sign_in(owner)
      expect do
        delete member_project_document_path(project, document)
      end.to change(project.documents, :count).by(-1)
      expect(response).to redirect_to(member_project_documents_path(project))
    end

    it "member senza documents.manage → redirect root, documento intatto" do
      sign_in(member)
      expect do
        delete member_project_document_path(project, document)
      end.not_to change(project.documents, :count)
      expect(response).to redirect_to(root_path)
    end
  end
end
