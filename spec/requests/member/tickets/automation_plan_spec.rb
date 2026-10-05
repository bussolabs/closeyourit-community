# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Member ticket automation plan", type: :request do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let(:ticket) { create(:ticket, organization:, project:, with_agent_workflow: true) }
  let(:workflow) { ticket.agent_workflow }
  let(:account) { create(:account, locale: "it") }
  let(:attempt) { create(:agent_attempt, organization:, workflow:) }

  before do
    create(:membership, :owner, organization:, account:)
    create(:project_membership, project:, account:)
    organization.update!(cto: account)
    post login_path, params: { email: account.email, password: "Secret123!" }
    workflow.update!(triaged_at: 2.minutes.ago, planned_at: Time.current, ticket_snapshot_digest: "snapshot")
  end

  def create_plan
    Agents::Plan.create!(
      workflow:, attempt:, ticket_snapshot_digest: "snapshot", contract_version: 2,
      technical_analysis: "Proiezione leggibile",
      content: {
        "summary" => "Le persone possono valutare il lavoro senza ricostruirlo.",
        "work_items" => [
          { "id" => "WI-1", "title" => "Mostrare le foto", "description" => "Aggiungere lettura e modifica.",
            "files" => [ { "path" => "lib/features/catalog/venue_form.dart", "reason" => "Contiene il modulo." } ],
            "dependencies" => [] }
        ],
        "rationale" => [ "Chi amministra deve correggere ciò che arriva dall'app." ],
        "risks" => [], "open_points" => [],
        "sources" => [ { "path" => "lib/features/catalog/venue_form.dart", "reason" => "Modulo reale." } ]
      },
      scenarios: [
        { "id" => "SC-1", "title" => "Foto del locale", "given" => "un locale con tre foto caricate dall'app",
          "when" => "apro la sua scheda dal pannello", "then" => "vedo le foto e posso cambiarle",
          "expected" => "senza passare dal sito" }
      ],
      definition_of_done: [ { "id" => "DOD-1", "text" => "Le foto sono modificabili dal pannello" } ],
      notes: []
    )
  end

  it "rende il piano strutturato e gli scenari come frasi scansionabili" do
    create_plan

    get member_ticket_path(ticket, tab: "automation")

    page = Nokogiri::HTML(response.body)
    scenario = page.at_css("[data-test='automation-plan-scenario']")
    expect(response).to have_http_status(:ok)
    expect(page.text).to include("Mostrare le foto")
    # CYRA-998 — the path is a hover, not the text.
    expect(page.css("[data-test='automation-plan-file-reference']").map { |node| node["title"] })
      .to include(a_string_starting_with("lib/features/catalog/venue_form.dart"))
    expect(scenario.text.squish).to include(
      "Dato un locale con tre foto caricate dall'app, quando apro la sua scheda dal pannello, " \
      "allora vedo le foto e posso cambiarle, mi aspetto senza passare dal sito"
    )
    expect(scenario.css("strong").map { |node| node.text.strip }).to eq([ "Dato", "quando", "allora", "mi aspetto" ])
    expect(response.body).to include(member_ticket_automation_plan_path(ticket))
  end

  it "shows scenario and done-criterion ids as badges, so they read at a glance" do
    create_plan

    get member_ticket_path(ticket, tab: "automation")

    page = Nokogiri::HTML(response.body)
    expect(page.css("[data-test='automation-plan-scenario-id']").map { |node| node.text.strip }).to eq([ "SC-1" ])
    expect(page.css("[data-test='automation-plan-criterion-id']").map { |node| node.text.strip }).to eq([ "DOD-1" ])
  end

  it "scarica un Markdown generato dallo stesso piano" do
    create_plan

    get member_ticket_automation_plan_path(ticket)

    expect(response).to have_http_status(:ok)
    expect(response.media_type).to eq("text/markdown")
    expect(response.headers.fetch("Content-Disposition")).to include("attachment", "#{ticket.code}-piano-v1.md")
    expect(response.body).to include(
      "# Piano #{ticket.code} · v1",
      "## Interventi",
      "**Dato** un locale con tre foto caricate dall'app, **quando** apro la sua scheda dal pannello",
      "- [ ] **DOD-1** — Le foto sono modificabili dal pannello"
    )
  end

  it "mostra il resoconto v2 come dichiarato e conserva le prove per criterio" do
    create_plan
    create(
      :agent_attempt, organization:, workflow:, phase: "autopilot", status: :approved,
      result: {
        "contract_version" => 2,
        "work_report" => {
          "summary" => "Le foto sono modificabili dal pannello.",
          "commit" => "3f2a91c0d4e6b8079a1c5f3d2e7b4a6c8d0f1e29",
          "changed_files" => [ { "path" => "lib/features/catalog/venue_form.dart", "summary" => "Gestisce le foto." } ],
          "tests" => [ { "command" => "make test", "status" => "passed", "summary" => "Casi 0/1/3 verdi." } ],
          "risks" => [], "deviations" => [],
          "acceptance_evidence" => [ { "criterion_id" => "DOD-1", "status" => "verified",
                                        "evidence" => "Widget test verde.", "source" => "reported" } ]
        }
      }
    )

    # CYRA-883 — the agent's work report is read in the Report tab.
    get member_ticket_path(ticket, tab: "report")

    expect(response).to have_http_status(:ok)
    expect(response.body).to include('data-test="automation-work-report"')
    expect(response.body).to include("dichiarato dall’agente", "DOD-1", "Widget test verde")
  end

  it "non espone il piano di un ticket fuori dallo scope visibile" do
    create_plan
    outsider_org = create(:organization)
    outsider = create(:account)
    create(:membership, :owner, organization: outsider_org, account: outsider)
    post login_path, params: { email: outsider.email, password: "Secret123!" }

    get member_ticket_automation_plan_path(ticket)

    expect(response).to have_http_status(:not_found)
  end
end
