# frozen_string_literal: true

require "rails_helper"

# CYRA-448 — fra gli agenti che producono e le decisioni da smaltire non c'era nessun filo: dalla coda
# non si sapeva quale macchina avesse generato cosa, e dalla scheda di una macchina non si arrivava a
# ciò che aveva lasciato in sospeso.
RSpec.describe "Member — dalla coda all'agente e ritorno (CYRA-448)", type: :request do
  let(:org) { create(:organization) }
  let(:owner) { create(:account) }
  let(:project) { create(:project, organization: org) }
  let(:host) { create(:agent_host, organization: org, hostname: "minion-uno") }

  before do
    create(:membership, account: owner, organization: org, role: :owner)
    org.update_column(:cto_id, owner.id)
    post login_path, params: { email: owner.email, password: "Secret123!" }
  end

  # Un piano che aspetta l'approvazione, prodotto da una macchina precisa.
  def plan_waiting(planner: host)
    ticket = create(:ticket, organization: org, project: project)
    create(:agent_workflow, ticket: ticket, triage_requested_at: 2.hours.ago, triaged_at: 1.hour.ago,
                            planned_at: 30.minutes.ago, planned_by_host_id: planner&.id)
  end

  it "la riga della coda dice quale macchina ha prodotto il lavoro, ed è cliccabile" do
    plan_waiting

    get member_home_approvals_path

    link = Nokogiri::HTML(response.body).at_css("[data-test='approvals-board-agent']")
    expect(link).to be_present
    expect(link.text).to include("minion-uno")
    expect(link["href"]).to eq(member_agent_path(host))
  end

  it "una riga senza macchina lo dichiara, invece di sparire" do
    plan_waiting(planner: nil)

    get member_home_approvals_path

    doc = Nokogiri::HTML(response.body)
    expect(doc.at_css("[data-test='approvals-board-row']")).to be_present
    # CYRA-592 — la colonna dell'agente c'è su ogni riga: senza macchina dice «nessuno» invece di
    # restare vuota, o la riga sembrerebbe incompleta.
    expect(doc.at_css("[data-test='approvals-board-agent']").text.strip)
      .to eq(I18n.t("member.approvals.board.no_agent"))
  end

  it "il filtro per agente resta nell'indirizzo e isola le sue decisioni" do
    altro = create(:agent_host, organization: org, hostname: "minion-due")
    mio = plan_waiting
    allow_n_plus_one { plan_waiting(planner: altro) }

    get member_home_approvals_path(agent_id: host.id)

    # Le chip elencano tutte le macchine (restano cliccabili): il filtro si verifica sulle RIGHE.
    righe = Nokogiri::HTML(response.body).css("[data-test='approvals-board-row']")
    expect(righe.size).to eq(1)
    expect(righe.text).to include(mio.ticket.code)
    expect(righe.text).not_to include("minion-due")
  end

  it "la scheda dell'agente dice quante decisioni aspetta e porta alla coda filtrata" do
    plan_waiting

    get member_agent_path(host)

    doc = Nokogiri::HTML(response.body)
    expect(doc.at_css("[data-test='host-waiting']").text).to include("1")
    expect(doc.at_css("[data-test='host-waiting-link']")["href"]).to eq(member_home_approvals_path(agent_id: host.id))
  end
end
