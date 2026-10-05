# frozen_string_literal: true

require "rails_helper"

# CYRA-624 — quello che vedi mentre il sistema guarda: la scheda dice «In chiusura» e dice anche che
# non aspetta niente da te. Prima qui non c'era niente, perché il ticket era già «Fatto».
RSpec.describe "Member::Tickets — controllo del rilascio", type: :request do
  let(:org) { create(:organization) }
  let(:project) { create(:project, organization: org) }
  let!(:fatto) { create(:ticket_status, :done, organization: org) }
  let(:in_progress) { create(:ticket_status, :in_progress, organization: org) }
  let(:ticket) { create(:ticket, organization: org, project:, status: in_progress, with_agent_workflow: true) }
  let(:workflow) { ticket.agent_workflow }
  let(:cto) do
    create(:account).tap do |account|
      create(:membership, account:, organization: org, role: :owner)
      create(:project_membership, account:, project:)
    end
  end

  before do
    org.update!(cto:)
    pronta_per!(workflow, "closer_production")
    workflow.update!(closer_production_completed_at: Time.current)
    workflow.probes.create!(kind: "deploy_smoke", bound_at: 2.minutes.ago, next_check_at: 1.minute.from_now,
                            checks_count: 3, last_error_code: "R502-GITHUB-001",
                            expected: { "version" => "v0.30.0", "sha" => "a" * 40, "repo" => "x/y" })
    post login_path, params: { email: cto.email, password: "Secret123!" }
  end

  it "dice che sta guardando, quante volte ha provato e con che esito" do
    get member_ticket_path(ticket, tab: "automation")

    expect(response.body).to include("automation-release-proof")
    expect(response.body).to include("R502-GITHUB-001")
  end

  # La riga «perché si è fermata» deve dire che non aspetta niente: è il punto del ticket, e una
  # frase sbagliata qui manda una persona a cercare una decisione che non esiste.
  it "la riga «perché si è fermata» dice che non è ferma" do
    # CYRA-626 — senza un guasto in corso la riga è quella della fase: quando invece il sistema non
    # riesce a leggere, la stessa riga lo dice, e quel caso ha la sua prova.
    workflow.probes.sole.update!(last_error_code: nil)

    get member_ticket_path(ticket, tab: "automation")

    riga = Nokogiri::HTML(response.body).at_css('[data-test="automation-summary"]').text.squish
    expect(riga).to include(I18n.t("member.tickets.automation.summary.stopped.awaiting_production_proof",
                                   locale: I18n.locale).squish)
  end

  it "il pulsante «segna come rilasciato» porta il ticket a Fatto e chiude la prova" do
    get member_ticket_path(ticket, tab: "automation")
    expect(response.body).to include("automation-release-mark")

    post member_ticket_automation_release_mark_path(ticket)

    expect(ticket.reload.status).to eq(fatto)
    expect(workflow.reload.completed_at).to be_present
    expect(workflow.probes.live).to be_empty
  end

  it "chi non decide su quel progetto non vede il pulsante" do
    altro = create(:account).tap do |account|
      create(:membership, account:, organization: org, role: :member)
      create(:project_membership, account:, project:)
    end
    post login_path, params: { email: altro.email, password: "Secret123!" }

    get member_ticket_path(ticket, tab: "automation")

    expect(response.body).to include("automation-release-proof")
    expect(response.body).not_to include("automation-release-mark")
  end
end
