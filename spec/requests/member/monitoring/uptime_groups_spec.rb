# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Member::Monitoring::UptimeGroups", type: :request do
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

  def grant(*keys)
    Authorization::SetAccountPermissions.call(
      organization: org, account: member, allow_keys: keys, actor: owner
    )
  end

  describe "GET index" do
    it "non autenticato → redirect login" do
      get member_monitoring_uptime_groups_path
      expect(response).to redirect_to(login_path)
    end

    it "membro senza permesso → redirect a root (gate uptime_groups.view)" do
      sign_in(member)
      create(:uptime_group, organization: org, name: "Servizi Critici")
      get member_monitoring_uptime_groups_path
      expect(response).to redirect_to(root_path)
    end

    it "membro con uptime_groups.view → 200, vede i gruppi" do
      grant("uptime_groups.view")
      sign_in(member)
      create(:uptime_group, organization: org, name: "Servizi Critici")
      get member_monitoring_uptime_groups_path
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Servizi Critici")
    end

    it "owner → 200 e filtra per ricerca testuale" do
      create(:uptime_group, organization: org, name: "Cercabile")
      create(:uptime_group, organization: org, name: "Altro")
      sign_in(owner)
      get member_monitoring_uptime_groups_path, params: { q: "Cercabile" }
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Cercabile")
    end
  end

  describe "GET show" do
    it "membro senza permesso → redirect a root" do
      sign_in(member)
      group = create(:uptime_group, organization: org)
      get member_monitoring_uptime_group_path(group)
      expect(response).to redirect_to(root_path)
    end

    it "owner → 200" do
      sign_in(owner)
      group = create(:uptime_group, organization: org)
      get member_monitoring_uptime_group_path(group)
      expect(response).to have_http_status(:ok)
    end

    it "gruppo di un'altra organizzazione → 404 (anti-BOLA)" do
      sign_in(owner)
      altrui = create(:uptime_group, organization: create(:organization))
      get member_monitoring_uptime_group_path(altrui)
      expect(response).to have_http_status(:not_found)
    end

    it "lo stato monitor non è veicolato dal solo colore: badge con label testuale (a11y)" do
      sign_in(owner)
      project = create(:project, organization: org).tap do |p|
        p.project_platforms.create!(platform: create(:platform, :uptime_capable, organization: org))
      end
      environment = create(:environment, organization: org).tap { |e| project.environments << e }
      group = create(:uptime_group, organization: org)
      monitor = create(:uptime_monitor, project:, environment:, group:, current_status: :up)
      get member_monitoring_uptime_group_path(group)

      # uptime_status_label(monitor) per un monitor attivo/up → "Up" (vedi UptimeHelper).
      row = Nokogiri::HTML(response.body).at_css("[data-test='uptime-group-monitor-#{monitor.id}']")
      expect(row.text).to include("Up")
    end
  end

  describe "GET new / POST create" do
    it "membro senza uptime_groups.manage → redirect a root" do
      sign_in(member)
      get new_member_monitoring_uptime_group_path
      expect(response).to redirect_to(root_path)
    end

    it "owner → 200 su new" do
      sign_in(owner)
      get new_member_monitoring_uptime_group_path
      expect(response).to have_http_status(:ok)
    end

    it "crea un gruppo con dati validi" do
      sign_in(owner)
      expect do
        post member_monitoring_uptime_groups_path, params: { confirm: "1", name: "API pubbliche", color: "indigo" }
      end.to change(Uptime::Group, :count).by(1)
      group = Uptime::Group.order(:created_at).last
      expect(response).to redirect_to(member_monitoring_uptime_group_path(group))
      expect(group.name).to eq("API pubbliche")
      expect(group.slug).to eq("api-pubbliche")
      expect(group.created_by).to eq(owner)
    end

    it "nome vuoto → 422 senza creare" do
      sign_in(owner)
      expect do
        post member_monitoring_uptime_groups_path, params: { name: "" }
      end.not_to change(Uptime::Group, :count)
      expect(response).to have_http_status(:unprocessable_content)
    end
  end

  describe "PATCH update" do
    it "aggiorna il nome" do
      group = create(:uptime_group, organization: org, name: "Vecchio")
      sign_in(owner)
      patch member_monitoring_uptime_group_path(group), params: { confirm: "1", name: "Nuovo" }
      expect(response).to redirect_to(member_monitoring_uptime_group_path(group))
      expect(group.reload.name).to eq("Nuovo")
    end

    it "membro senza manage → redirect a root" do
      group = create(:uptime_group, organization: org)
      grant("uptime_groups.view")
      sign_in(member)
      patch member_monitoring_uptime_group_path(group), params: { name: "X" }
      expect(response).to redirect_to(root_path)
    end
  end

  describe "DELETE destroy" do
    it "elimina il gruppo e nullifica i monitor" do
      group = create(:uptime_group, organization: org)
      project = create(:project, organization: org)
      monitor = create(:uptime_monitor, group: group, project: project)
      sign_in(owner)
      expect do
        delete member_monitoring_uptime_group_path(group), params: { confirm: "1" }
      end.to change(Uptime::Group, :count).by(-1)
      expect(response).to redirect_to(member_monitoring_uptime_groups_path)
      expect(monitor.reload.group_id).to be_nil
    end
  end

  describe "PATCH publish / unpublish (status page pubblica del gruppo)" do
    it "pubblica la status page del gruppo" do
      group = create(:uptime_group, organization: org)
      sign_in(owner)
      patch publish_member_monitoring_uptime_group_path(group), params: { confirm: "1" }
      expect(response).to redirect_to(member_monitoring_uptime_group_path(group, tab: "public"))
      expect(group.reload.public_status_enabled?).to be(true)
    end

    it "rimuove la status page del gruppo" do
      group = create(:uptime_group, :published, organization: org)
      sign_in(owner)
      patch unpublish_member_monitoring_uptime_group_path(group), params: { confirm: "1" }
      expect(group.reload.public_status_enabled?).to be(false)
    end

    it "membro senza uptime_groups.manage → redirect a root, flag invariato" do
      group = create(:uptime_group, organization: org)
      grant("uptime_groups.view")
      sign_in(member)
      patch publish_member_monitoring_uptime_group_path(group)
      expect(response).to redirect_to(root_path)
      expect(group.reload.public_status_enabled?).to be(false)
    end

    it "pubblicato → la show offre i due codici da incollare (riquadro e pagina intera)" do
      group = create(:uptime_group, :published, organization: org)
      sign_in(owner)
      get member_monitoring_uptime_group_path(group, tab: "public")

      expect(response.body).to include('data-test="uptime-group-embed"')
      expect(response.body).to include('data-test="uptime-group-embed-dialog"')
      # Gli snippet sono testo da copiare, quindi nel body arrivano ESCAPATI.
      expect(response.body).to include(ERB::Util.html_escape(
        %(<iframe src="#{public_group_status_badge_url(org.slug, group.slug)}" width="280" height="36")
      ))
      expect(response.body).to include(ERB::Util.html_escape(
        %(<iframe src="#{public_group_status_url(org.slug, group.slug)}" width="100%" height="800")
      ))
    end

    it "NON pubblicato → nessun pulsante Incorpora" do
      group = create(:uptime_group, organization: org)
      sign_in(owner)
      get member_monitoring_uptime_group_path(group, tab: "public")
      expect(response.body).not_to include('data-test="uptime-group-embed"')
    end
  end

  # CYRA-26: la nota "eliminare un gruppo mantiene i monitor" era disegnata a mano a
  # fondo tabella → ora è il bulb title_tip accanto al titolo.
  describe "suggerimento nel bulb title_tip (CYRA-26)" do
    before { sign_in(owner) }

    it "no longer renders the hand-drawn note (info icon) at the bottom of the page" do
      get member_monitoring_uptime_groups_path
      expect(response.body).not_to include('data-icon="info"')
    end
  end
  # CYRA-924 — delete asks in a dialog that names the thing, never in the browser box (F16, C77).
  describe "delete confirmation (dialog)" do
    it "opens a dialog that sends the delete" do
      sign_in(owner)
      group = create(:uptime_group, organization: org, name: "Siti clienti")

      get member_monitoring_uptime_groups_path

      html = Nokogiri::HTML(response.body)
      dialog = html.at_css("dialog[data-test='uptime-group-delete-dialog-#{group.id}']")
      expect(dialog.text).to include(I18n.t("member.uptime_groups.delete_dialog.title", name: "Siti clienti"))
      expect(dialog.at_css("form")["action"]).to eq(member_monitoring_uptime_group_path(group))
      expect(dialog.at_css("input[name='confirm']")["value"]).to eq("1")
      expect(html.at_css("[data-test='uptime-group-row-delete-#{group.id}']")["data-action"]).to eq("ui--dialog#open")
      expect(response.body).not_to include("data-turbo-confirm")
    end
  end
end
