# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Member::Groups", type: :request do
  let(:org) { create(:organization) }
  let(:owner) { create(:account) }
  let(:admin) { create(:account) }
  let(:member) { create(:account) }

  before do
    create(:membership, account: owner, organization: org, role: :owner)
    create(:membership, account: admin, organization: org, role: :admin)
    create(:membership, account: member, organization: org, role: :member)
  end

  def sign_in(account)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  describe "GET index" do
    it "non autenticato → redirect login" do
      get member_groups_path
      expect(response).to redirect_to(login_path)
    end

    it "membro senza permesso → redirect a root (gate project_groups.view)" do
      sign_in(member)
      create(:group, organization: org, name: "DriverOne")
      get member_groups_path
      expect(response).to redirect_to(root_path)
    end

    it "membro con project_groups.view → 200, vede i gruppi" do
      Authorization::SetAccountPermissions.call(
        organization: org, account: member, allow_keys: [ "project_groups.view" ], actor: owner
      )
      sign_in(member)
      create(:group, organization: org, name: "DriverOne")
      get member_groups_path
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("DriverOne")
    end

    it "filtra i gruppi per ricerca testuale (ramo search_q.present?)" do
      create(:group, organization: org, name: "Searchable Group")
      create(:group, organization: org, name: "Altro")
      sign_in(owner)
      get member_groups_path, params: { q: "Searchable" }
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Searchable Group")
    end

    it "il menu di riga ha un aria-label descrittivo col nome del gruppo (a11y)" do
      sign_in(owner)
      create(:group, organization: org, name: "DriverOne")
      get member_groups_path
      expect(response).to have_http_status(:ok)
      expect(response.body).to include(%(aria-label="#{I18n.t('member.groups.row_menu_label', name: 'DriverOne')}"))
    end
  end

  describe "GET show" do
    it "membro senza permesso → redirect a root (gate project_groups.view)" do
      sign_in(member)
      group = create(:group, organization: org)
      get member_group_path(group)
      expect(response).to redirect_to(root_path)
    end

    it "membro con project_groups.view → 200" do
      Authorization::SetAccountPermissions.call(
        organization: org, account: member, allow_keys: [ "project_groups.view" ], actor: owner
      )
      sign_in(member)
      group = create(:group, organization: org)
      get member_group_path(group)
      expect(response).to have_http_status(:ok)
    end

    it "gruppo di un'altra org → 404 (anti-BOLA)" do
      sign_in(owner)
      foreign = create(:group, organization: create(:organization))
      get member_group_path(foreign)
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "GET new" do
    it "admin → 200" do
      sign_in(owner)
      get new_member_group_path
      expect(response).to have_http_status(:ok)
    end

    it "membro → redirect (gate)" do
      sign_in(member)
      get new_member_group_path
      expect(response).to redirect_to(root_path)
    end
  end

  describe "POST create" do
    it "admin crea un gruppo (created_by = admin)" do
      sign_in(owner)
      expect do
        post member_groups_path, params: { name: "DriverOne", color: "indigo" }
      end.to change(Projects::Group, :count).by(1)
      group = Projects::Group.last
      expect(group.name).to eq("DriverOne")
      expect(group.created_by).to eq(owner)
      expect(response).to redirect_to(member_group_path(group))
    end

    it "membro → redirect, nessun gruppo creato" do
      sign_in(member)
      expect do
        post member_groups_path, params: { name: "X" }
      end.not_to change(Projects::Group, :count)
      expect(response).to redirect_to(root_path)
    end

    it "nome vuoto → 422" do
      sign_in(owner)
      post member_groups_path, params: { name: "" }
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "saves the chosen icon" do
      sign_in(owner)
      post member_groups_path, params: { name: "G", color: "indigo", icon: "rocket" }
      expect(Projects::Group.last.icon).to eq("rocket")
    end

    it "salva l'immagine icona caricata" do
      sign_in(owner)
      file = fixture_file_upload("screenshot.png", "image/png")
      post member_groups_path, params: { name: "G", color: "indigo", icon_image: file }
      expect(Projects::Group.last.icon_image).to be_attached
    end
  end

  describe "GET edit" do
    it "admin → 200" do
      sign_in(owner)
      group = create(:group, organization: org)
      get edit_member_group_path(group)
      expect(response).to have_http_status(:ok)
    end

    it "membro → redirect" do
      sign_in(member)
      group = create(:group, organization: org)
      get edit_member_group_path(group)
      expect(response).to redirect_to(root_path)
    end
  end

  describe "PATCH update" do
    it "admin rinomina" do
      sign_in(owner)
      group = create(:group, organization: org, name: "Old")
      patch member_group_path(group), params: { name: "New" }
      expect(response).to redirect_to(member_group_path(group))
      expect(group.reload.name).to eq("New")
    end

    it "nome vuoto → 422" do
      sign_in(owner)
      group = create(:group, organization: org, name: "Old")
      patch member_group_path(group), params: { name: "" }
      expect(response).to have_http_status(:unprocessable_content)
      expect(group.reload.name).to eq("Old")
    end
  end

  describe "DELETE destroy" do
    it "admin elimina; i progetti sopravvivono e diventano senza gruppo" do
      sign_in(owner)
      group = create(:group, organization: org)
      project = create(:project, organization: org, group: group)
      expect { delete member_group_path(group) }.to change(Projects::Group, :count).by(-1)
      expect(Projects::Project.exists?(project.id)).to be(true)
      expect(project.reload.group_id).to be_nil
      expect(response).to redirect_to(member_groups_path)
    end

    it "membro → redirect, gruppo resta" do
      sign_in(member)
      group = create(:group, organization: org)
      expect { delete member_group_path(group) }.not_to change(Projects::Group, :count)
      expect(response).to redirect_to(root_path)
    end
  end

  # CYRA-26: la nota "eliminare un gruppo mantiene i progetti" era disegnata a mano a
  # fondo tabella → ora è il bulb title_tip accanto al titolo.
  describe "suggerimento nel bulb title_tip (CYRA-26)" do
    before { sign_in(owner) }

    it "no longer shows the hand-drawn note (info icon) at the bottom of the page" do
      get member_groups_path
      expect(response.body).not_to include('data-icon="info"')
    end
  end
  # CYRA-924 — delete asks in a dialog that names the thing, never in the browser box (F16, C77).
  describe "delete confirmation (dialog)" do
    it "opens a dialog that sends the delete" do
      sign_in(owner)
      group = create(:group, organization: org, name: "Clienti")

      get member_groups_path

      html = Nokogiri::HTML(response.body)
      dialog = html.at_css("dialog[data-test='group-delete-dialog-#{group.id}']")
      expect(dialog.text).to include(I18n.t("member.groups.delete_dialog.title", name: "Clienti"))
      expect(dialog.at_css("form")["action"]).to eq(member_group_path(group))
      expect(dialog.at_css("input[name='confirm']")["value"]).to eq("1")
      expect(html.at_css("[data-test='group-row-delete-#{group.id}']")["data-action"]).to eq("ui--dialog#open")
      expect(response.body).not_to include("data-turbo-confirm")
    end
  end
end
