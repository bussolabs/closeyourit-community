# frozen_string_literal: true

require "rails_helper"

# Guidance del PROGETTO (CYRA-75): CRUD locale di references/procedures + preview del contesto effettivo.
# Gate projects.edit (scope progetto), come la tab Settings: la guidance è configurazione, non catalogo
# in lettura libera. Anti-BOLA scoped al progetto visibile.
RSpec.describe "Member::ProjectGuidance", type: :request do
  let(:org) { create(:organization) }
  let(:owner) { create(:account) }
  let(:member) { create(:account) }
  let(:group) { create(:group, organization: org) }
  let(:project) { create(:project, organization: org, group: group) }

  before do
    create(:membership, account: owner, organization: org, role: :owner)
    create(:membership, account: member, organization: org, role: :member)
    create(:project_membership, account: member, project: project)
  end

  def sign_in(account)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  describe "GET show (hub)" do
    it "non autenticato → redirect login" do
      get member_project_guidance_path(project)
      expect(response).to redirect_to(login_path)
    end

    it "owner → 200" do
      sign_in(owner)
      get member_project_guidance_path(project)
      expect(response).to have_http_status(:ok)
    end

    it "member assegnato senza projects.edit → redirect root (gate)" do
      sign_in(member)
      get member_project_guidance_path(project)
      expect(response).to redirect_to(root_path)
    end

    it "progetto di un'altra org → 404 (anti-BOLA)" do
      sign_in(owner)
      foreign = create(:project, organization: create(:organization))
      get member_project_guidance_path(foreign)
      expect(response).to have_http_status(:not_found)
    end

    it "la preview mostra il contesto effettivo con origine e override espliciti (Scenario 2)" do
      create(:guidance_reference, owner: org, key: "repo", location: "git@org")
      create(:guidance_reference, owner: project, key: "repo", location: "git@project")
      create(:guidance_reference, owner: org, key: "legacy")
      create(:guidance_reference, :disabled, owner: project, key: "legacy")
      sign_in(owner)

      get member_project_guidance_path(project)

      expect(response.body).to include('data-test="guidance-preview"')
      expect(response.body).to include("git@project")
      expect(response.body).to include(I18n.t("member.guidance.status.overridden"))
      expect(response.body).to include(I18n.t("member.guidance.status.disabled"))
    end
  end

  describe "references CRUD" do
    it "GET new → 200 per owner, redirect per member" do
      sign_in(owner)
      get new_member_project_guidance_reference_path(project)
      expect(response).to have_http_status(:ok)

      sign_in(member)
      get new_member_project_guidance_reference_path(project)
      expect(response).to redirect_to(root_path)
    end

    it "owner crea una reference locale (owner + org + created_by valorizzati)" do
      sign_in(owner)
      expect do
        post member_project_guidance_references_path(project),
             params: { key: "app-repo", kind: "repository", location: "git@github.com:acme/app.git", required: "1" }
      end.to change(project.guidance_references, :count).by(1)
      reference = project.guidance_references.find_by(key: "app-repo")
      expect(reference.organization).to eq(org)
      expect(reference.created_by).to eq(owner)
      expect(reference.required).to be(true)
      expect(response).to redirect_to(member_project_guidance_path(project))
    end

    it "key invalida → 422, nessuna creazione" do
      sign_in(owner)
      expect do
        post member_project_guidance_references_path(project),
             params: { key: "Bad Key!", kind: "repository", location: "git@x" }
      end.not_to change(Guidance::Reference, :count)
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "member → redirect root, nessuna creazione" do
      sign_in(member)
      expect do
        post member_project_guidance_references_path(project),
             params: { key: "x", kind: "repository", location: "git@x" }
      end.not_to change(Guidance::Reference, :count)
      expect(response).to redirect_to(root_path)
    end

    it "owner aggiorna una reference (la modifica resta nel livello progetto)" do
      reference = create(:guidance_reference, owner: project, key: "repo", location: "git@old")
      sign_in(owner)
      patch member_project_guidance_reference_path(project, reference),
            params: { key: "repo", kind: "repository", location: "git@new" }
      expect(reference.reload.location).to eq("git@new")
      expect(reference.owner).to eq(project)
      expect(response).to redirect_to(member_project_guidance_path(project))
    end

    it "owner elimina una reference locale" do
      reference = create(:guidance_reference, owner: project, key: "repo")
      sign_in(owner)
      expect do
        delete member_project_guidance_reference_path(project, reference)
      end.to change(project.guidance_references, :count).by(-1)
    end

    it "reference di un altro progetto → 404 (anti-BOLA)" do
      foreign = create(:guidance_reference, key: "altrui")
      sign_in(owner)
      patch member_project_guidance_reference_path(project, foreign), params: { key: "altrui", location: "x" }
      expect(response).to have_http_status(:not_found)
    end

    it "reorder assegna le posizioni secondo ordered_ids" do
      a = create(:guidance_reference, owner: project, key: "a", position: 0)
      b = create(:guidance_reference, owner: project, key: "b", position: 1)
      sign_in(owner)
      patch reorder_member_project_guidance_references_path(project), params: { ordered_ids: [ b.id, a.id ] }
      expect(response).to have_http_status(:ok)
      expect(project.guidance_references.order(:position).pluck(:key)).to eq(%w[b a])
    end
  end

  describe "procedures CRUD" do
    it "owner crea una procedura locale" do
      sign_in(owner)
      expect do
        post member_project_guidance_procedures_path(project),
             params: { key: "setup", content: "Installa le dipendenze", application_mode: "inherit", merge_strategy: "override" }
      end.to change(project.guidance_procedures, :count).by(1)
      expect(project.guidance_procedures.find_by(key: "setup").created_by).to eq(owner)
      expect(response).to redirect_to(member_project_guidance_path(project))
    end

    it "content vuoto → 422" do
      sign_in(owner)
      post member_project_guidance_procedures_path(project),
           params: { key: "setup", content: "", application_mode: "inherit" }
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "owner elimina una procedura locale" do
      procedure = create(:guidance_procedure, owner: project, key: "setup")
      sign_in(owner)
      expect do
        delete member_project_guidance_procedure_path(project, procedure)
      end.to change(project.guidance_procedures, :count).by(-1)
    end

    it "member → redirect root, nessuna creazione" do
      sign_in(member)
      expect do
        post member_project_guidance_procedures_path(project),
             params: { key: "x", content: "y", application_mode: "inherit" }
      end.not_to change(Guidance::Procedure, :count)
      expect(response).to redirect_to(root_path)
    end
  end
end
