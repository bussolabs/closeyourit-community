# frozen_string_literal: true

require "rails_helper"

# CYRA-470 — l'unico filtro dell'elenco (lo stato) non filtrava nulla con tutte le macchine attive, e
# non c'era modo di raggruppare la flotta: la domanda operativa più frequente, «come sta la
# produzione», non si poteva fare. I gruppi liberi assegnati dal form la rendono possibile, e i filtri
# operativi (disco oltre soglia) portano alle macchine che chiedono attenzione.
RSpec.describe "Member::Monitoring::Servers — gruppi e filtri operativi (CYRA-470)", type: :request do
  let(:org) { create(:organization) }
  let(:owner) { create(:account) }

  before do
    create(:membership, account: owner, organization: org, role: :owner)
    post login_path, params: { email: owner.email, password: "Secret123!" }
  end

  describe "assegnare un gruppo dal modulo di modifica (Scenario 2)" do
    it "salva i gruppi scritti come testo, separati da virgola" do
      host = create(:server_host, organization: org, name: "web-1")

      patch member_monitoring_server_path(host), params: { confirm: "1", name: "web-1", groups: "produzione, database" }

      expect(host.reload.groups).to eq(%w[produzione database])
    end

    it "il modulo di modifica mostra un campo per i gruppi" do
      host = create(:server_host, organization: org, name: "web-1", groups: [ "produzione" ])

      get edit_member_monitoring_server_path(host)

      expect(Nokogiri::HTML(response.body).at_css("[data-test='server-groups-field']")).to be_present
    end

    it "il gruppo assegnato compare nell'elenco ed è offerto come filtro" do
      create(:server_host, organization: org, name: "web-prod", groups: [ "produzione" ])

      get member_monitoring_servers_path

      # The groups filter the list: they are a filter of the toolbar, each with its number of machines.
      group_filter = Nokogiri::HTML(response.body).at_css("[data-test='servers-toolbar'] [data-test='filter-group']")
      expect(group_filter).to be_present
      expect(group_filter.text).to include("produzione (1)")
    end
  end

  describe "guardare solo un gruppo (Scenario 1)" do
    it "mostra solo le macchine del gruppo, e il filtro ne dice il numero" do
      allow_n_plus_one do
        create(:server_host, organization: org, name: "web-prod", groups: [ "produzione" ])
        create(:server_host, organization: org, name: "db-prod", groups: [ "produzione" ])
        create(:server_host, organization: org, name: "web-collaudo", groups: [ "staging" ])
      end

      get member_monitoring_servers_path(group: "produzione")

      expect(response.body).to include("web-prod")
      expect(response.body).to include("db-prod")
      expect(response.body).not_to include("web-collaudo")
      doc = Nokogiri::HTML(response.body)
      expect(doc.at_css("[data-test='servers-group-active']")).to be_nil
      expect(doc.at_css("[data-test='filter-group']").text).to include("produzione (2)")
    end

    it "un gruppo inventato non svuota di nascosto l'elenco: dice che è per il filtro" do
      create(:server_host, organization: org, name: "sola", groups: [ "produzione" ])

      get member_monitoring_servers_path(group: "non-esiste")

      expect(response).to have_http_status(:ok)
      # CYRA-687 — il nessun-risultato è il componente con l'uscita, non più la frase secca.
      expect(response.body).to include('data-test="servers-no-match"')
      expect(response.body).to include('data-test="servers-reset-filters"')
    end
  end

  describe "filtro operativo: disco oltre soglia" do
    before { create(:alerting_rule, organization: org, event_type: :server_disk, name: "Disco", threshold: 80) }

    it "porta solo alle macchine col disco oltre la soglia dell'organizzazione" do
      allow_n_plus_one do
        create(:server_host, :up, organization: org, name: "disco-pieno", disk_pct: 92)
        create(:server_host, :up, organization: org, name: "disco-sgombro", disk_pct: 40)
      end

      get member_monitoring_servers_path(needs: "disk")

      expect(response.body).to include("disco-pieno")
      expect(response.body).not_to include("disco-sgombro")
    end

    it "il riquadro «Da fare» elenca il disco oltre soglia, cliccabile verso quelle macchine" do
      create(:server_host, :up, organization: org, name: "disco-pieno", disk_pct: 92)

      get member_monitoring_servers_path

      doc = Nokogiri::HTML(response.body)
      expect(doc.at_css("[data-test='servers-todo-disk']")).to be_present
      expect(doc.at_css("[data-test='servers-todo-link-disk']")["href"]).to include("needs=disk")
    end
  end
end
