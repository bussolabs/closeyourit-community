# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Valhalla::Organizations", type: :request do
  let(:god) { create(:account, god: true) }

  # CYRA-170: il god in Valhalla passa dal 2FA (sign_in_god lo attiva al volo + completa il 2° fattore).
  before { sign_in_god(god) }

  describe "GET index" do
    it "risponde 200" do
      create(:organization)
      get valhalla_organizations_path
      expect(response).to have_http_status(:ok)
    end

    it "filtra per query" do
      match = create(:organization, name: "Findable Co")
      other = create(:organization, name: "Hidden Inc")
      get valhalla_organizations_path, params: { q: "findable" }
      expect(response.body).to include("Findable Co")
      expect(response.body).not_to include("Hidden Inc")
    end

    it "filtra per stato sospeso" do
      active = create(:organization, name: "Still Running", suspended_at: nil)
      suspended = create(:organization, name: "On Pause", suspended_at: Time.current)
      get valhalla_organizations_path, params: { status: [ "suspended" ] }
      expect(response.body).to include("On Pause")
      expect(response.body).not_to include("Still Running")
    end

    it "filtra per stato attivo (solo non sospese)" do
      create(:organization, name: "Still Running", suspended_at: nil)
      create(:organization, name: "On Pause", suspended_at: Time.current)
      get valhalla_organizations_path, params: { status: [ "active" ] }
      expect(response.body).to include("Still Running")
      expect(response.body).not_to include("On Pause")
    end

    it "pagina (seconda pagina con oltre TABLE_PER_PAGE organizzazioni)" do
      create_list(:organization, App::Constants::TABLE_PER_PAGE + 1)
      get valhalla_organizations_path, params: { page: 2 }
      expect(response).to have_http_status(:ok)
      # TABLE_PER_PAGE + 1 org → 1 sola riga in pagina 2.
      expect(response.body.scan("valhalla-organization-row").size).to eq(1)
    end

    it "sort=organization (LOWER name) asc/desc" do
      create(:organization, name: "zephyr labs")
      create(:organization, name: "Acme co")

      get valhalla_organizations_path, params: { sort: "organization" }
      expect(response.body.index("Acme co")).to be < response.body.index("zephyr labs")

      get valhalla_organizations_path, params: { sort: "-organization" }
      expect(response.body.index("zephyr labs")).to be < response.body.index("Acme co")
    end

    it "sort=-members: subquery COUNT sulle membership" do
      big = create(:organization, name: "Big org")
      create_list(:membership, 2, organization: big)
      create(:organization, name: "Small org")

      get valhalla_organizations_path, params: { sort: "-members" }
      expect(response.body.index("Big org")).to be < response.body.index("Small org")
    end
  end

  describe "GET show" do
    it "risponde 200" do
      get valhalla_organization_path(create(:organization))
      expect(response).to have_http_status(:ok)
    end

    # CYRA-924 — every member column sorts (C9).
    it "sorts members by account both ways and offers every column" do
      organization = create(:organization)
      create(:membership, organization: organization, account: create(:account, name: "Zeno Last"))
      create(:membership, organization: organization, account: create(:account, name: "alba First"))

      get valhalla_organization_path(organization), params: { sort: "account" }
      expect(response.body.index("alba First")).to be < response.body.index("Zeno Last")
      get valhalla_organization_path(organization), params: { sort: "-account" }
      expect(response.body.index("Zeno Last")).to be < response.body.index("alba First")
      %w[account email role].each { |key| expect(response.body).to include("sort=#{key}").or include("sort=-#{key}") }
    end

    it "filtra i membri per query" do
      organization = create(:organization)
      match = create(:account, name: "Mara Visible", email: "mara@demo.test")
      other = create(:account, name: "Carlo Hidden", email: "carlo@demo.test")
      create(:membership, organization: organization, account: match)
      create(:membership, organization: organization, account: other)

      get valhalla_organization_path(organization), params: { q: "mara" }
      expect(response.body).to include("Mara Visible")
      expect(response.body).not_to include("Carlo Hidden")
    end

    it "il ruolo dei membri è tradotto e il conteggio va al singolare con un membro solo" do
      god.update!(locale: "it")
      organization = create(:organization)
      create(:membership, organization: organization, role: :owner)

      get valhalla_organization_path(organization)

      doc = Nokogiri::HTML(response.body)
      expect(doc.at_css('[data-test="valhalla-org-member-role"]').text.strip).to eq("Proprietario")
      # CYRA-924 — the count sits beside the section title, never in the bar (C63).
      expect(doc.at_css('[data-test="valhalla-org-members-count"]').text.strip).to eq("1 membro")
      expect(doc.at_css('[data-test="valhalla-org-members-toolbar"]').text).not_to include("1 membro")
    end

    it "pagina i membri (seconda pagina con oltre TABLE_PER_PAGE membri)" do
      organization = create(:organization)
      create_list(:membership, App::Constants::TABLE_PER_PAGE + 1, organization: organization)
      get valhalla_organization_path(organization), params: { page: 2 }
      expect(response).to have_http_status(:ok)
      # TABLE_PER_PAGE + 1 membri → 1 sola riga in pagina 2.
      expect(response.body.scan("valhalla-org-member-row").size).to eq(1)
    end

    it "i numeri statistici (membri/progetti/ticket) sono in mono, non font-display" do
      get valhalla_organization_path(create(:organization))
      doc = Nokogiri::HTML(response.body)
      # Le 3 card statistiche condividono la dimensione text-[28px] — marcatore unico su questa pagina.
      stat_numbers = doc.css("p").select { |p| p["class"].to_s.include?("text-[28px]") }
      expect(stat_numbers.size).to eq(3)
      stat_numbers.each do |stat|
        expect(stat["class"]).to include("font-mono")
        expect(stat["class"]).not_to include("font-display")
      end
    end
  end

  describe "GET new" do
    it "risponde 200" do
      get new_valhalla_organization_path
      expect(response).to have_http_status(:ok)
    end
  end

  describe "POST create" do
    it "provisiona organizzazione + owner" do
      expect {
        post valhalla_organizations_path, params: { name: "Acme Inc", owner_email: "owner@acme.test" }
      }.to change(Organizations::Organization, :count).by(1)
      organization = Organizations::Organization.find_by(slug: "acme-inc")
      expect(response).to redirect_to(valhalla_organization_path(organization))
    end

    it "nome mancante → 422" do
      post valhalla_organizations_path, params: { name: "", owner_email: "x@acme.test" }
      expect(response).to have_http_status(:unprocessable_content)
    end
  end

  describe "edit / update" do
    it "edit risponde 200" do
      get edit_valhalla_organization_path(create(:organization))
      expect(response).to have_http_status(:ok)
    end

    it "update rinomina" do
      organization = create(:organization, name: "Old")
      patch valhalla_organization_path(organization), params: { name: "New", slug: organization.slug }
      expect(response).to redirect_to(valhalla_organization_path(organization))
      expect(organization.reload.name).to eq("New")
    end

    it "update con nome vuoto → 422 render edit" do
      organization = create(:organization, name: "Keep")
      patch valhalla_organization_path(organization), params: { name: "", slug: organization.slug }
      expect(response).to have_http_status(:unprocessable_content)
      expect(organization.reload.name).to eq("Keep")
    end
  end

  describe "PATCH suspend" do
    it "sospende e riattiva" do
      organization = create(:organization)
      patch suspend_valhalla_organization_path(organization)
      expect(organization.reload).to be_suspended
      patch suspend_valhalla_organization_path(organization)
      expect(organization.reload).not_to be_suspended
    end

    # CYRA-722 — chi ha la pagina già aperta non fa più richieste: senza questo, il suo canale in
    # tempo reale continuerebbe a consegnargli messaggi e aggiornamenti finché non ricarica.
    it "chiude i canali in tempo reale già aperti dell'organizzazione sospesa" do
      organization = create(:organization)
      connessioni = instance_double(ActionCable::RemoteConnections::RemoteConnection, disconnect: true)
      allow(ActionCable.server.remote_connections).to receive(:where)
        .with(current_organization: organization).and_return(connessioni)

      patch suspend_valhalla_organization_path(organization)

      expect(connessioni).to have_received(:disconnect).with(reconnect: false)
    end

    it "riattivare non chiude niente: non c'è nessuno da mandare via" do
      organization = create(:organization, suspended_at: Time.current)
      allow(ActionCable.server.remote_connections).to receive(:where)

      patch suspend_valhalla_organization_path(organization)

      expect(ActionCable.server.remote_connections).not_to have_received(:where)
    end
  end

  describe "DELETE destroy" do
    it "elimina l'organizzazione" do
      organization = create(:organization)
      expect { delete valhalla_organization_path(organization) }.to change(Organizations::Organization, :count).by(-1)
    end
  end

  context "come account non-god" do
    before do
      delete logout_path
      post login_path, params: { email: create(:account, god: false).email, password: "Secret123!" }
    end

    it "non accede (redirect home)" do
      get valhalla_organizations_path
      expect(response).to redirect_to(root_path)
    end
  end
  # CYRA-924 — delete asks in a dialog that names the thing, never in the browser box (F16, C77).
  describe "delete confirmation (dialog)" do
    it "opens a dialog that sends the delete" do
      organization = create(:organization, name: "Acme")

      get valhalla_organizations_path

      html = Nokogiri::HTML(response.body)
      dialog = html.at_css("dialog[data-test='valhalla-organization-delete-dialog-#{organization.id}']")
      expect(dialog.text).to include(I18n.t("valhalla.organizations.delete_dialog.title", name: "Acme"))
      expect(dialog.at_css("form")["action"]).to eq(valhalla_organization_path(organization))
      expect(dialog.at_css("input[name='confirm']")["value"]).to eq("1")
      expect(dialog.ancestors.first.at_css("[data-test='valhalla-organization-delete']")["data-action"]).to eq("ui--dialog#open")
      expect(response.body).not_to include("data-turbo-confirm")
    end
  end
end
