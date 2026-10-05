# frozen_string_literal: true

require "rails_helper"

# CYRA-384 — «una segnalazione di sicurezza importante resta nascosta a metà del testo»: su un ticket
# vero l'anomalia (uno script che sondava le credenziali git, un token dentro l'indirizzo di
# download) era testo corrente dentro un paragrafo di 250 parole, in una scheda secondaria.
#
# Qui sale in cima al ticket, in ogni scheda, come avviso. La scrive la macchina in un campo apposta
# del risultato consegnato (decisione del 2026-08-17): non si cerca nel testo libero.
RSpec.describe "Member ticket security findings", type: :request do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let(:ticket) { create(:ticket, organization:, project:, with_agent_workflow: true) }
  let(:workflow) { ticket.agent_workflow }
  let(:host) { create(:agent_host, organization:) }
  let(:account) { create(:account) }

  before do
    create(:membership, :owner, organization:, account:)
    create(:project_membership, project:, account:)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  def segnala(*findings)
    create(:agent_attempt, organization:, workflow:, host:, phase: "autopilot", status: :approved,
                           started_at: 10.minutes.ago, finished_at: 9.minutes.ago,
                           result: { "state" => "blocked", "reason" => "Fermato",
                                     "security_findings" => findings })
  end

  it "mostra la segnalazione come avviso in cima al ticket" do
    segnala({ "title" => "Credenziali git sondate", "detail" => "Uno script legge ~/.git-credentials.",
              "severity" => "high" })

    get member_ticket_path(ticket)

    avviso = Nokogiri::HTML(response.body).at_css("[data-test='ticket-security-findings']")
    expect(avviso).to be_present
    expect(avviso.text).to include("Credenziali git sondate")
    expect(avviso.text).to include("Uno script legge ~/.git-credentials.")
  end

  # Nascosta in una scheda secondaria è esattamente il guasto che il ticket chiude: l'avviso non
  # dipende dalla scheda aperta.
  it "resta in cima anche aprendo un'altra scheda del ticket" do
    segnala({ "title" => "Token nell'indirizzo" })

    get member_ticket_path(ticket, tab: "automation")

    # Sul testo reso: l'apostrofo nell'HTML è `&#39;`.
    expect(Nokogiri::HTML(response.body).at_css("[data-test='ticket-security-findings']").text)
      .to include("Token nell'indirizzo")
  end

  it "un ticket senza segnalazioni non mostra nessun avviso" do
    create(:agent_attempt, organization:, workflow:, host:, phase: "autopilot", status: :approved,
                           started_at: 10.minutes.ago, finished_at: 9.minutes.ago,
                           result: { "state" => "delivered" })

    get member_ticket_path(ticket)

    expect(response.body).not_to include("ticket-security-findings")
  end

  # On the desktop frame the page drops its own padding: a bare line touched the panel edge.
  it "the all-clear line sits in its own panel" do
    segnala

    get member_ticket_path(ticket)

    line = Nokogiri::HTML(response.body).at_css("[data-test='ticket-security-clear']")
    expect(line).to be_present
    expect(line.ancestors("[data-test='ticket-security-clear-panel']")).to be_present
  end

  it "l'avviso precede la decisione da prendere sul ticket" do
    ticket.update!(status: create(:ticket_status, organization:, review_gate: true))
    create(:ticket_report, ticket:, organization:, body: "Fatto e verificato.")
    segnala({ "title" => "Segreto nei log" })

    get member_ticket_path(ticket)

    corpo = response.body
    expect(corpo.index("ticket-security-findings")).to be < corpo.index("ticket-decision-banner")
  end
end
