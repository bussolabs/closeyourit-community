# frozen_string_literal: true

require "rails_helper"

# CYRA-694 — i filtri di un elenco si ricordano: aprendo un ticket e tornando all'elenco (dal
# breadcrumb o dalla sidebar, che sono link senza parametri) i filtri scelti tornano
# NELL'INDIRIZZO con un redirect, come già fa il periodo del monitoring (TimeRangeable).
RSpec.describe "Member filtri ricordati", type: :request do
  let(:org) { create(:organization) }
  let(:owner) { create(:account) }
  let(:project) { create(:project, organization: org) }

  before do
    create(:membership, account: owner, organization: org, role: :owner)
    Types::InstallDefaults.call(organization: org)
    post login_path, params: { email: owner.email, password: "Secret123!" }
  end

  def html = Nokogiri::HTML(response.body)

  describe "tornare su un elenco filtrato (scenario 1)" do
    it "dopo aver filtrato, la visita senza parametri riporta i filtri nell'indirizzo" do
      get list_member_tickets_path(kind: [ "bug" ])
      expect(response).to have_http_status(:ok)

      get list_member_tickets_path

      expect(response).to redirect_to(list_member_tickets_path(kind: [ "bug" ]))
      follow_redirect!
      expect(response).to have_http_status(:ok)
    end

    it "ricorda insieme più filtri, la ricerca e l'ordinamento" do
      get list_member_tickets_path(kind: [ "bug" ], q: "pagamenti", sort: "created")
      get list_member_tickets_path

      expect(response).to redirect_to(list_member_tickets_path(kind: [ "bug" ], q: "pagamenti", sort: "created"))
    end

    it "la pagina non viene mai ricordata: si riparte dalla prima" do
      get list_member_tickets_path(kind: [ "bug" ], page: "2")
      get list_member_tickets_path

      expect(response).to redirect_to(list_member_tickets_path(kind: [ "bug" ]))
    end

    it "chi non ha mai filtrato atterra sull'elenco pieno senza rimbalzi" do
      get list_member_tickets_path

      expect(response).to have_http_status(:ok)
    end
  end

  describe "l'indirizzo comanda (scenario 3)" do
    it "un collegamento con filtri dentro vince su quelli ricordati" do
      get list_member_tickets_path(kind: [ "bug" ])
      get list_member_tickets_path(kind: [ "story" ])

      expect(response).to have_http_status(:ok)
      expect(request.params["kind"]).to eq([ "story" ])
    end
  end

  describe "azzerare è dimenticare (scenario 2)" do
    it "il submit della barra con i filtri svuotati cancella la memoria" do
      get list_member_tickets_path(kind: [ "bug" ])
      get list_member_tickets_path(ft: "1")
      expect(response).to have_http_status(:ok)

      get list_member_tickets_path

      expect(response).to have_http_status(:ok)
    end

    it "il marker non finisce mai fra i filtri ricordati" do
      get list_member_tickets_path(kind: [ "bug" ], ft: "1")
      get list_member_tickets_path

      expect(response).to redirect_to(list_member_tickets_path(kind: [ "bug" ]))
    end

    it "la barra offre il collegamento «Azzera filtri» quando un filtro è acceso" do
      get list_member_tickets_path(kind: [ "bug" ])

      azzera = html.at_css('[data-test="tickets-toolbar-reset"]')
      expect(azzera).to be_present
      expect(azzera["href"]).to include("ft=1")
    end

    it "senza filtri accesi il collegamento «Azzera filtri» non c'è" do
      get list_member_tickets_path

      expect(html.at_css('[data-test="tickets-toolbar-reset"]')).to be_nil
    end

    it "il form della barra dichiara sempre i propri filtri col marker" do
      get list_member_tickets_path

      expect(html.at_css('input[type="hidden"][name="ft"]')).to be_present
    end
  end

  describe "memoria per indirizzo" do
    it "bacheca e lista ricordano set indipendenti" do
      get list_member_tickets_path(kind: [ "bug" ])
      # La board fa di proposito una query per colonna (LIMIT per blocco, CYRA-390): col filtro
      # kind le query per colonna si somigliano e prosopite le scambierebbe per N+1.
      allow_n_plus_one { get member_tickets_path(kind: [ "story" ]) }

      allow_n_plus_one { get member_tickets_path }
      expect(response).to redirect_to(member_tickets_path(kind: [ "story" ]))

      get list_member_tickets_path
      expect(response).to redirect_to(list_member_tickets_path(kind: [ "bug" ]))
    end

    it "tiene al più dieci indirizzi: il più vecchio cade" do
      paths = [
        member_platforms_path, member_environments_path, member_agents_path,
        member_groups_path, member_teams_path, member_roles_path,
        member_members_path, member_ideas_path, member_tickets_path,
        list_member_tickets_path, member_projects_path
      ]
      # La bacheca fa di proposito una query per colonna (CYRA-390): con la ricerca
      # attiva le query si somigliano e prosopite le scambierebbe per N+1.
      allow_n_plus_one do
        paths.each { |path| get path, params: { q: "ricordami" } }
      end

      get paths.first
      expect(response).to have_http_status(:ok)

      get paths.last
      expect(response).to redirect_to("#{paths.last}?q=ricordami")
    end

    it "un set di filtri troppo pesante non entra in memoria" do
      get list_member_tickets_path(q: "a" * 700)
      expect(response).to have_http_status(:ok)

      get list_member_tickets_path
      expect(response).to have_http_status(:ok)
    end

    it "un parametro dalla forma sbagliata (hash) non entra mai in memoria" do
      get list_member_tickets_path(q: { furbo: "x" }, kind: [ "bug" ])

      get list_member_tickets_path
      expect(response).to redirect_to(list_member_tickets_path(kind: [ "bug" ]))
    end

    it "un filtro presente ma svuotato (array di blank) conta come nessun filtro" do
      get list_member_tickets_path(kind: [ "bug" ])
      get list_member_tickets_path(kind: [ "" ])
      expect(response).to have_http_status(:ok)

      get list_member_tickets_path
      expect(response).to have_http_status(:ok)
    end
  end

  describe "convivenza col periodo del monitoring" do
    it "periodo e filtri ricordati tornano entrambi nell'indirizzo, al più in due passi" do
      create(:error_group, project:, last_seen_at: 1.hour.ago)

      get member_monitoring_error_groups_path(range: "7d", status: [ "unresolved" ])

      get member_monitoring_error_groups_path
      expect(response).to have_http_status(:redirect)
      follow_redirect!
      follow_redirect! if response.redirect?

      expect(response).to have_http_status(:ok)
      expect(request.params["range"]).to eq("7d")
      expect(request.params["status"]).to eq([ "unresolved" ])
    end
  end

  describe "a new login starts clean" do
    let(:colleague) { create(:account) }

    before { create(:membership, account: colleague, organization: org, role: :admin) }

    it "does not hand the previous account's filters and period to the next one on the same browser" do
      get list_member_tickets_path(kind: [ "bug" ])
      get member_monitoring_error_groups_path(range: "7d")
      delete logout_path
      post login_path, params: { email: colleague.email, password: "Secret123!" }

      get list_member_tickets_path
      expect(response).to have_http_status(:ok)
      get member_monitoring_error_groups_path
      expect(response).to have_http_status(:ok)
    end
  end
end
