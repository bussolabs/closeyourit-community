# frozen_string_literal: true

require "rails_helper"

# Guidance a livello ORGANIZZAZIONE (CYRA-75): CRUD locale, base della catena ereditata. Gate
# organization.manage. Owner = Current.organization (nessun id nel path); anti-BOLA sulla collection.
RSpec.describe "Member::OrganizationGuidance", type: :request do
  let(:org) { create(:organization) }
  let(:owner) { create(:account) }
  let(:member) { create(:account) }

  before do
    create(:membership, account: owner, organization: org, role: :owner)
    create(:membership, account: member, organization: org, role: :member)
  end

  def sign_in(account)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  describe "GET show (hub)" do
    it "non autenticato → redirect login" do
      get member_organization_guidance_path
      expect(response).to redirect_to(login_path)
    end

    it "owner → 200" do
      sign_in(owner)
      get member_organization_guidance_path
      expect(response).to have_http_status(:ok)
    end

    it "membro senza organization.manage → redirect root (gate)" do
      sign_in(member)
      get member_organization_guidance_path
      expect(response).to redirect_to(root_path)
    end

    it "spiega riferimenti e procedure senza «puntatori», «path» e «livelli»" do
      owner.update!(locale: "it")
      sign_in(owner)
      get member_organization_guidance_path
      text = Capybara.string(response.body).find("main").text
      expect(text).to include("Dove l'assistente trova il contesto")
      expect(text).not_to match(/puntatori|\bpath\b|componibili/i)
    end
  end

  describe "references CRUD" do
    it "owner crea una reference locale (owner = org, created_by)" do
      sign_in(owner)
      expect do
        post member_organization_guidance_references_path,
             params: { confirm: "1", key: "org-repo", kind: "repository", location: "git@org" }
      end.to change(org.guidance_references, :count).by(1)
      reference = org.guidance_references.find_by(key: "org-repo")
      expect(reference.owner).to eq(org)
      expect(reference.created_by).to eq(owner)
      expect(response).to redirect_to(member_organization_guidance_path)
    end

    it "membro → redirect root, nessuna creazione" do
      sign_in(member)
      expect do
        post member_organization_guidance_references_path,
             params: { key: "x", kind: "repository", location: "git@x" }
      end.not_to change(Guidance::Reference, :count)
      expect(response).to redirect_to(root_path)
    end

    it "key invalida → 422" do
      sign_in(owner)
      post member_organization_guidance_references_path,
           params: { key: "Bad Key!", kind: "repository", location: "git@x" }
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "owner elimina" do
      reference = create(:guidance_reference, owner: org, key: "org-repo")
      sign_in(owner)
      expect do
        delete member_organization_guidance_reference_path(reference), params: { confirm: "1" }
      end.to change(org.guidance_references, :count).by(-1)
    end

    it "reference di un'altra org → 404 (anti-BOLA)" do
      foreign = create(:guidance_reference, owner: create(:organization), key: "altrui")
      sign_in(owner)
      patch member_organization_guidance_reference_path(foreign), params: { confirm: "1", key: "altrui", location: "x" }
      expect(response).to have_http_status(:not_found)
    end

    it "reorder assegna le posizioni secondo ordered_ids" do
      a = create(:guidance_reference, owner: org, key: "a", position: 0)
      b = create(:guidance_reference, owner: org, key: "b", position: 1)
      sign_in(owner)
      patch reorder_member_organization_guidance_references_path, params: { confirm: "1", ordered_ids: [ b.id, a.id ] }
      expect(response).to have_http_status(:ok)
      expect(org.guidance_references.order(:position).pluck(:key)).to eq(%w[b a])
    end
  end

  describe "procedures CRUD" do
    it "owner crea una procedura locale" do
      sign_in(owner)
      expect do
        post member_organization_guidance_procedures_path,
             params: { confirm: "1", key: "setup", content: "Installa", application_mode: "inherit", merge_strategy: "override" }
      end.to change(org.guidance_procedures, :count).by(1)
      expect(response).to redirect_to(member_organization_guidance_path)
    end

    it "content vuoto → 422" do
      sign_in(owner)
      post member_organization_guidance_procedures_path, params: { key: "setup", content: "", application_mode: "inherit" }
      expect(response).to have_http_status(:unprocessable_content)
    end
  end
end
