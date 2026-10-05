# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Member::Teams", type: :request do
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

  describe "gate permissions.manage" do
    it "owner → 200" do
      sign_in(owner)
      get member_teams_path
      expect(response).to have_http_status(:ok)
    end

    it "membro senza permesso → redirect" do
      sign_in(member)
      get member_teams_path
      expect(response).to redirect_to(root_path)
    end

    it "index filtra i team per ricerca testuale (ramo search_q.present?)" do
      create(:team, organization: org, name: "Searchable Team")
      create(:team, organization: org, name: "Altro")
      sign_in(owner)
      get member_teams_path, params: { q: "Searchable" }
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Searchable Team")
    end

    # «Scope» era gergo: la pagina dei membri la stessa cosa la chiama già «ambito».
    it "in italiano la colonna si chiama «Ambito», non «Scope»" do
      owner.update!(locale: "it")
      create(:team, organization: org, name: "Senza ambito")
      sign_in(owner)
      get member_teams_path
      expect(response.body).to include("Ambito", "Nessun ambito")
      expect(Capybara.string(response.body).find("main").text).not_to match(/\bscope\b/i)
    end
  end

  describe "GET new" do
    it "owner → 200 con il form vuoto (empty_selection)" do
      sign_in(owner)
      get new_member_team_path
      expect(response).to have_http_status(:ok)
    end
  end

  describe "POST create" do
    it "crea il team con ruoli, membri e scope" do
      role = create(:role, organization: org)
      project = create(:project, organization: org)
      sign_in(owner)
      expect do
        post member_teams_path, params: { confirm: "1", name: "Support", color: "emerald",
                                          role_ids: [ role.id ], member_ids: [ member.id ],
                                          project_ids: [ project.id ], group_ids: [] }
      end.to change(Teams::Team, :count).by(1)
      team = Teams::Team.find_by(organization: org, name: "Support")
      expect(team.roles).to contain_exactly(role)
      expect(team.members).to contain_exactly(member)
      expect(team.scoped_projects).to contain_exactly(project)
      expect(response).to redirect_to(member_teams_path)
    end

    it "nome blank → 422" do
      sign_in(owner)
      post member_teams_path, params: { name: "" }
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "crea il team con un assegnatario di default dei ticket" do
      sign_in(owner)
      post member_teams_path, params: { confirm: "1", name: "Ops", default_assignee_id: member.id,
                                        role_ids: [], member_ids: [], project_ids: [], group_ids: [] }
      expect(response).to redirect_to(member_teams_path)
      expect(Teams::Team.find_by(organization: org, name: "Ops").default_assignee).to eq(member)
    end

    it "rifiuta un default_assignee non membro dell'org → 422" do
      outsider = create(:account)
      sign_in(owner)
      post member_teams_path, params: { name: "Ops", default_assignee_id: outsider.id }
      expect(response).to have_http_status(:unprocessable_content)
    end
  end

  describe "PATCH update" do
    it "riconcilia ruoli/membri/scope" do
      team = create(:team, organization: org, name: "Old")
      role = create(:role, organization: org)
      sign_in(owner)
      patch member_team_path(team), params: { confirm: "1", name: "Support", role_ids: [ role.id ],
                                              member_ids: [ member.id ], project_ids: [], group_ids: [] }
      expect(team.reload.name).to eq("Support")
      expect(team.roles).to contain_exactly(role)
      expect(team.members).to contain_exactly(member)
    end

    it "nome vuoto → 422 e re-render del form (ramo else)" do
      team = create(:team, organization: org, name: "Keep")
      sign_in(owner)
      patch member_team_path(team), params: { name: "", role_ids: [], member_ids: [], project_ids: [], group_ids: [] }
      expect(response).to have_http_status(:unprocessable_content)
      expect(team.reload.name).to eq("Keep")
    end

    it "aggiorna l'assegnatario di default dei ticket" do
      team = create(:team, organization: org, name: "Ops")
      sign_in(owner)
      patch member_team_path(team), params: { confirm: "1", name: "Ops", default_assignee_id: member.id,
                                              role_ids: [], member_ids: [], project_ids: [], group_ids: [] }
      expect(team.reload.default_assignee).to eq(member)
    end
  end

  describe "DELETE destroy" do
    it "elimina il team" do
      team = create(:team, organization: org)
      sign_in(owner)
      expect { delete member_team_path(team), params: { confirm: "1" } }.to change(Teams::Team, :count).by(-1)
    end
  end

  describe "anti-BOLA" do
    it "team di un'altra org → 404" do
      other = create(:team)
      sign_in(owner)
      get edit_member_team_path(other)
      expect(response).to have_http_status(:not_found)
    end
  end

  # CYRA-237: anche via team un delegato con permissions.manage (NON owner) non può concedere
  # progetti che non vede già → l'accesso non viene creato/aggiornato e l'utente vede un permesso negato.
  describe "guard di visibilità sullo scope (CYRA-237)" do
    let(:manager) { create(:account) }
    let(:visible_project) { create(:project, organization: org) }
    let(:hidden_project) { create(:project, organization: org) }

    before do
      create(:membership, account: manager, organization: org, role: :member)
      Authorization::SetAccountPermissions.call(
        organization: org, account: manager, allow_keys: [ "permissions.manage" ], actor: owner
      )
      create(:project_membership, account: manager, project: visible_project)
    end

    it "un delegato non-owner NON può creare un team con un progetto che non vede → alert, team non creato" do
      sign_in(manager)
      expect do
        post member_teams_path, params: { confirm: "1", name: "Ghost", role_ids: [], member_ids: [],
                                          project_ids: [ hidden_project.id ], group_ids: [] }
      end.not_to change(Teams::Team, :count)
      expect(response).to have_http_status(:forbidden)
      expect(Capybara.string(response.body)).to have_field("name", with: "Ghost")
      expect(flash[:alert]).to be_present
    end

    it "un delegato non-owner NON può aggiungere a un team un progetto che non vede → alert, scope invariato" do
      team = create(:team, organization: org)
      sign_in(manager)
      patch member_team_path(team), params: { confirm: "1", name: team.name, role_ids: [], member_ids: [],
                                              project_ids: [ hidden_project.id ], group_ids: [] }
      expect(response).to have_http_status(:forbidden)
      expect(Capybara.string(response.body)).to have_field("name", with: team.name)
      expect(flash[:alert]).to be_present
      expect(team.reload.scoped_projects).to be_empty
    end

    it "un delegato non-owner PUÒ assegnare un progetto che vede → team creato con quel progetto" do
      sign_in(manager)
      post member_teams_path, params: { confirm: "1", name: "Visible", role_ids: [], member_ids: [],
                                        project_ids: [ visible_project.id ], group_ids: [] }
      team = Teams::Team.find_by(organization: org, name: "Visible")
      expect(team).to be_present
      expect(team.scoped_projects).to contain_exactly(visible_project)
    end
  end
  # CYRA-695 — cancellare un team toglie in un colpo a tutti i suoi membri i permessi che arrivavano
  # da lì, senza annullamento e senza dire quante persone tocca.
  describe "conferma prima di eliminare un team (CYRA-695)" do
    before { sign_in(owner) }

    it "the list dialog names the team and says how many people lose its permissions" do
      team = create(:team, organization: org, name: "Rilasci")
      team.members << member

      get member_teams_path
      confirm = Nokogiri::HTML(response.body).at_css("dialog[data-test='team-delete-dialog-#{team.id}']").text
      expect(confirm).to include("Rilasci")
      expect(confirm).to include(I18n.t("member.teams.used_members", count: 1))
    end

    it "il pulsante del modulo di modifica chiede la stessa conferma" do
      team = create(:team, organization: org, name: "Rilasci")

      get edit_member_team_path(team)
      button = Nokogiri::HTML(response.body).at_css("[data-test='team-delete']")
      confirm = button.attr("data-turbo-confirm") || button.ancestors("form").first&.attr("data-turbo-confirm")
      expect(confirm).to be_present
      expect(confirm).to include("Rilasci")
    end
  end
  # CYRA-924 — delete asks in a dialog that names the thing, never in the browser box (F16, C77).
  describe "delete confirmation (dialog)" do
    it "opens a dialog that sends the delete" do
      sign_in(owner)
      team = create(:team, organization: org, name: "Supporto")

      get member_teams_path

      html = Nokogiri::HTML(response.body)
      dialog = html.at_css("dialog[data-test='team-delete-dialog-#{team.id}']")
      expect(dialog.text).to include(I18n.t("member.teams.delete_dialog.title", name: "Supporto"))
      expect(dialog.at_css("form")["action"]).to eq(member_team_path(team))
      expect(dialog.at_css("input[name='confirm']")["value"]).to eq("1")
      expect(html.at_css("[data-test='teams-delete-#{team.id}']")["data-action"]).to eq("ui--dialog#open")
      expect(response.body).not_to include("data-turbo-confirm")
    end
  end
end
