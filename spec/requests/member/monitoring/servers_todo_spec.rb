# frozen_string_literal: true

require "rails_helper"

# CYRA-475 — nessuna pagina proponeva un passo successivo, eppure i dati per rispondere c'erano già,
# sparsi: riavvii in attesa, aggiornamenti di sicurezza, servizi caduti. Il prodotto raccoglieva le
# informazioni giuste e lasciava a chi legge il lavoro di metterle insieme.
RSpec.describe "Member::Monitoring::Servers — da fare sulla flotta (CYRA-475)", type: :request do
  let(:org) { create(:organization) }
  let(:owner) { create(:account) }

  before do
    create(:membership, account: owner, organization: org, role: :owner)
    post login_path, params: { email: owner.email, password: "Secret123!" }
  end

  it "riassume cosa richiede attenzione, coi numeri" do
    allow_n_plus_one do
      create(:server_host, organization: org, name: "da-riavviare", reboot_required: true)
      create(:server_host, organization: org, name: "anche-questa", reboot_required: true)
      create(:server_host, organization: org, name: "aggiornamenti", security_updates_available: 4)
    end

    get member_monitoring_servers_path

    doc = Nokogiri::HTML(response.body)
    # It floats over the frame and can be closed; what it lists is part of its key, so a new kind of
    # problem brings it back.
    notice = doc.at_css("[data-test='servers-todo']")
    expect(notice["data-controller"]).to eq("ui--floating-notice")
    expect(notice["data-ui--floating-notice-key-value"]).to eq("servers_todo:reboot,security_updates")
    # Things to fix, not an explanation: the warning tone.
    expect(notice["class"]).to include("bg-amber-50")
    expect(doc.at_css("[data-test='servers-todo-reboot']").text).to include("2")
    expect(doc.at_css("[data-test='servers-todo-security_updates']").text).to include("1")
  end

  it "il numero sta nella frase, non ripetuto una seconda volta in fondo alla riga" do
    allow_n_plus_one do
      create(:server_host, organization: org, name: "da-riavviare", reboot_required: true)
      create(:server_host, organization: org, name: "anche-questa", reboot_required: true)
    end

    get member_monitoring_servers_path

    riga = Nokogiri::HTML(response.body).at_css("[data-test='servers-todo-reboot']")
    expect(riga.text.scan("2").size).to eq(1)
  end

  it "ogni voce porta esattamente a quelle macchine" do
    allow_n_plus_one do
      create(:server_host, organization: org, name: "da-riavviare", reboot_required: true)
      create(:server_host, organization: org, name: "tranquilla", reboot_required: false)
    end

    get member_monitoring_servers_path(needs: "reboot")

    expect(response.body).to include("da-riavviare")
    expect(response.body).not_to include("tranquilla")
  end

  it "senza niente da fare il riquadro non compare: uno sempre acceso si smette di leggerlo" do
    create(:server_host, organization: org, name: "tranquilla")

    get member_monitoring_servers_path

    expect(Nokogiri::HTML(response.body).at_css("[data-test='servers-todo']")).to be_nil
  end

  it "un filtro inventato non svuota l'elenco" do
    create(:server_host, organization: org, name: "tranquilla")

    get member_monitoring_servers_path(needs: "non-esiste")

    expect(response.body).to include("tranquilla")
  end
end
