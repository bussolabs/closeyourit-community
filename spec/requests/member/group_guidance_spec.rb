# frozen_string_literal: true

require "rails_helper"

# Guidance a livello GRUPPO (macro-progetto, CYRA-75): CRUD locale. Gate project_groups.manage.
# Anti-BOLA: gruppo dell'org corrente + collection scoped al gruppo.
RSpec.describe "Member::GroupGuidance", type: :request do
  let(:org) { create(:organization) }
  let(:owner) { create(:account) }
  let(:member) { create(:account) }
  let(:group) { create(:group, organization: org) }

  before do
    create(:membership, account: owner, organization: org, role: :owner)
    create(:membership, account: member, organization: org, role: :member)
  end

  def sign_in(account)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  describe "GET show (hub)" do
    it "non autenticato → redirect login" do
      get member_group_guidance_path(group)
      expect(response).to redirect_to(login_path)
    end

    it "owner → 200" do
      sign_in(owner)
      get member_group_guidance_path(group)
      expect(response).to have_http_status(:ok)
    end

    it "membro senza project_groups.manage → redirect root (gate)" do
      sign_in(member)
      get member_group_guidance_path(group)
      expect(response).to redirect_to(root_path)
    end

    it "gruppo di un'altra org → 404 (anti-BOLA)" do
      sign_in(owner)
      foreign = create(:group, organization: create(:organization))
      get member_group_guidance_path(foreign)
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "references CRUD" do
    it "owner crea una reference locale (owner = gruppo)" do
      sign_in(owner)
      expect do
        post member_group_guidance_references_path(group),
             params: { key: "group-repo", kind: "repository", location: "git@group" }
      end.to change(group.guidance_references, :count).by(1)
      expect(group.guidance_references.find_by(key: "group-repo").owner).to eq(group)
      expect(response).to redirect_to(member_group_guidance_path(group))
    end

    it "membro → redirect root, nessuna creazione" do
      sign_in(member)
      expect do
        post member_group_guidance_references_path(group),
             params: { key: "x", kind: "repository", location: "git@x" }
      end.not_to change(Guidance::Reference, :count)
      expect(response).to redirect_to(root_path)
    end

    it "reference di un altro gruppo → 404 (anti-BOLA)" do
      other_group = create(:group, organization: org)
      foreign = create(:guidance_reference, owner: other_group, key: "altrui")
      sign_in(owner)
      patch member_group_guidance_reference_path(group, foreign), params: { key: "altrui", location: "x" }
      expect(response).to have_http_status(:not_found)
    end

    it "reorder assegna le posizioni secondo ordered_ids" do
      a = create(:guidance_reference, owner: group, key: "a", position: 0)
      b = create(:guidance_reference, owner: group, key: "b", position: 1)
      sign_in(owner)
      patch reorder_member_group_guidance_references_path(group), params: { ordered_ids: [ b.id, a.id ] }
      expect(response).to have_http_status(:ok)
      expect(group.guidance_references.order(:position).pluck(:key)).to eq(%w[b a])
    end
  end

  describe "procedures CRUD" do
    it "owner crea una procedura locale" do
      sign_in(owner)
      expect do
        post member_group_guidance_procedures_path(group),
             params: { key: "setup", content: "Installa", application_mode: "inherit", merge_strategy: "override" }
      end.to change(group.guidance_procedures, :count).by(1)
      expect(response).to redirect_to(member_group_guidance_path(group))
    end

    it "content vuoto → 422" do
      sign_in(owner)
      post member_group_guidance_procedures_path(group), params: { key: "setup", content: "", application_mode: "inherit" }
      expect(response).to have_http_status(:unprocessable_content)
    end
  end
end
