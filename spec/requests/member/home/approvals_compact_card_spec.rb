# frozen_string_literal: true

require "rails_helper"

# CYRA-702 — la card nella coda è compatta: risponde a «cosa succede se approvo, cosa rischio,
# perché è stata respinta». Il documento per esteso (scenari, criteri, note, analisi) vive solo
# sulla pagina intera e nel Markdown: qui restano il brief e i conteggi.
RSpec.describe "Member::Home::Approvals card compatta", type: :request do
  let(:org) { create(:organization) }
  let(:owner) { create(:account) }
  let(:project) { create(:project, organization: org) }

  before do
    create(:membership, account: owner, organization: org, role: :owner)
    org.update_column(:cto_id, owner.id)
  end

  def sign_in(account)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  def planned_workflow(**attributes)
    ticket = create(:ticket, organization: org, project:, **attributes)
    create(:agent_workflow, ticket:, triage_requested_at: 2.days.ago, triaged_at: 1.day.ago,
                            planned_at: Time.current)
  end

  def plan_for(workflow, decision_brief: nil, decision_card: nil)
    attempt = create(:agent_attempt, workflow:, organization: org, phase: "planner",
                                     result: decision_card ? { "decision_card" => decision_card } : {})
    Agents::Plan.create!(
      workflow:, attempt:, ticket_snapshot_digest: "snapshot", contract_version: 2,
      technical_analysis: "Analisi tecnica proiettata.", decision_brief:,
      content: {
        "summary" => "Ampliare `events_controller.rb` con le cinque azioni admin.",
        "work_items" => [ { "id" => "WI-1", "title" => "Endpoint eventi", "description" => "Aggiungere le azioni.",
                            "files" => [ { "path" => "app/controllers/events_controller.rb", "reason" => "Sede." } ],
                            "dependencies" => [] } ],
        "rationale" => [ "Il wizard esiste già." ],
        "risks" => [ { "id" => "R-1", "title" => "Merge status", "impact" => "Gli eventi restano in attesa.",
                       "mitigation" => "Riusare il service del pannello." } ],
        "open_points" => [ "Il lavoro risulta già consegnato altrove: verificare prima di rifarlo." ],
        "sources" => [ { "path" => "config/routes.rb", "reason" => "Rotte attuali." } ]
      },
      scenarios: [ { "id" => "SC-1", "title" => "Creazione", "given" => "sono amministratore con più date",
                     "when" => "salvo dall'app", "then" => "l'evento nasce approvato", "expected" => "lo ritrovo in elenco" },
                   { "id" => "SC-2", "title" => "Modifica", "given" => "un evento esistente",
                     "when" => "lo correggo", "then" => "le modifiche restano", "expected" => "resta approvato" } ],
      definition_of_done: [ { "id" => "DOD-1", "text" => "Si crea un evento dall'app" },
                            { "id" => "DOD-2", "text" => "Si corregge un evento esistente" },
                            { "id" => "DOD-3", "text" => "Nessuna regressione sulle rotte" } ],
      notes: [ "consulted: CLAUDE.md e kb Valhalla" ]
    )
  end

  describe "card del piano nella coda" do
    # CYRA-885 — with the agent's card the approver reads one sentence, up to three points and the risk.
    context "with a decision card" do
      let(:card) do
        { "headline" => "L'app potrà creare gli eventi come dal computer.",
          "points" => [ { "label" => "Cosa cambia", "text" => "Cinque azioni nuove per l'app." },
                        { "label" => "Perché", "text" => "Oggi il server risponde che la pagina non esiste." } ],
          "risk_level" => "low", "risk" => "Gli eventi creati dall'app restano in attesa se manca l'approvazione." }
      end

      it "shows headline, points and risk instead of the brief" do
        workflow = planned_workflow(title: "Eventi dall'app")
        plan_for(workflow, decision_brief: "Brief lungo che non deve comparire.", decision_card: card)
        sign_in(owner)

        get member_home_approvals_path(item: "agent_plan:#{workflow.id}")

        page = Nokogiri::HTML(response.body)
        expect(page.at_css("[data-test='approvals-decision-card-headline']").text).to include(card["headline"])
        expect(page.css("[data-test='approvals-decision-card-point']").map { |node| node.text.squish })
          .to eq([ "→ Cosa cambia Cinque azioni nuove per l'app.", "→ Perché Oggi il server risponde che la pagina non esiste." ])
        expect(page.at_css("[data-test='approvals-decision-card-risk']").text).to include(card["risk"])
        expect(page.at_css("[data-test='approvals-decision-card-level']").text)
          .to include(I18n.t("member.approvals.decision_card.risk_levels.low"))
        expect(response.body).not_to include("Brief lungo che non deve comparire.")
        expect(page.at_css("[data-test='approvals-compact-first-warning']")).to be_nil
        expect(page.at_css("[data-test='approvals-compact-warnings-count']")).to be_present
      end
    end

    it "col brief mostra quello, i conteggi, e mai il documento per esteso" do
      workflow = planned_workflow(title: "Eventi dall'app")
      plan_for(workflow, decision_brief: "L'app potrà creare e correggere gli eventi come dal computer.")
      sign_in(owner)

      get member_home_approvals_path(item: "agent_plan:#{workflow.id}")

      expect(response.body).to include('data-test="approvals-compact-brief"')
      expect(response.body).to include("L'app potrà creare e correggere gli eventi come dal computer.")
      expect(response.body).to include('data-test="approvals-compact-counts"')
      expect(response.body).to include(I18n.t("member.approvals.compact.counts.scenarios", count: 2))
      expect(response.body).to include(I18n.t("member.approvals.compact.counts.criteria", count: 3))
      expect(response.body).not_to include("sono amministratore con più date")
      expect(response.body).not_to include("Si crea un evento dall'app")
      expect(response.body).not_to include("kb Valhalla")
      expect(response.body).not_to include('data-test="automation-plan-work-item"')
    end

    it "senza brief ripiega sulla sintesi, sempre senza scenari e note" do
      workflow = planned_workflow(title: "Eventi dall'app")
      plan_for(workflow)
      sign_in(owner)

      get member_home_approvals_path(item: "agent_plan:#{workflow.id}")

      expect(response.body).to include("Ampliare")
      expect(response.body).not_to include("sono amministratore con più date")
      expect(response.body).not_to include("kb Valhalla")
    end

    it "senza brief mostra solo il primo paragrafo della sintesi, tagliato, e lo dichiara" do
      workflow = planned_workflow(title: "Eventi dall'app")
      plan = plan_for(workflow)
      long_summary = "Primo paragrafo #{'lungo ' * 80}\n\nSecondo paragrafo da non mostrare."
      plan.update!(content: plan.content.merge("summary" => long_summary))
      sign_in(owner)

      get member_home_approvals_path(item: "agent_plan:#{workflow.id}")

      summary = Nokogiri::HTML(response.body).at_css("[data-test='approvals-compact-summary']").text.strip
      expect(summary.length).to be <= 281
      expect(response.body).not_to include("Secondo paragrafo da non mostrare.")
      expect(response.body).to include(I18n.t("member.approvals.compact.no_brief"))
    end

    # CYRA-884 — the first risk is the danger the decision is about: it is read without a click.
    it "shows the first risk without a click and keeps the warning count visible" do
      workflow = planned_workflow(title: "Eventi dall'app")
      plan_for(workflow, decision_brief: "Brief breve.")
      sign_in(owner)

      get member_home_approvals_path(item: "agent_plan:#{workflow.id}")

      page = Nokogiri::HTML(response.body)
      first = page.at_css("[data-test='approvals-compact-first-warning']")
      expect(first.text).to include("Merge status")
      expect(first.ancestors("details")).to be_empty
      count = page.at_css("[data-test='approvals-compact-warnings-count']").text
      expect(count).to include(I18n.t("member.approvals.compact.open_points_count", count: 1))
      expect(count).to include(I18n.t("member.approvals.compact.risks_count", count: 1))
      more = page.at_css("details[data-test='approvals-compact-more-warnings']")
      expect(more).to be_present
      expect(more["open"]).to be_nil
    end

    it "i punti aperti e i rischi restano in card: sono il pericolo su cui si decide" do
      workflow = planned_workflow(title: "Eventi dall'app")
      plan_for(workflow, decision_brief: "Brief breve.")
      sign_in(owner)

      get member_home_approvals_path(item: "agent_plan:#{workflow.id}")

      expect(response.body).to include('data-test="approvals-compact-open-points"')
      expect(response.body).to include("Il lavoro risulta già consegnato altrove: verificare prima di rifarlo.")
      expect(response.body).to include('data-test="approvals-compact-risks"')
      expect(response.body).to include("Gli eventi restano in attesa.")
    end

    it "sulla pagina intera il documento resta per esteso" do
      workflow = planned_workflow(title: "Eventi dall'app")
      plan_for(workflow, decision_brief: "Brief breve.")
      sign_in(owner)

      get member_home_approvals_item_path(kind: "agent_plan", id: workflow.id)

      expect(response.body).to include("sono amministratore con più date")
      expect(response.body).to include("Si crea un evento dall'app")
      expect(response.body).to include("kb Valhalla")
    end
  end

  describe "card di review nella coda" do
    def review_ticket(**attributes)
      create(:ticket, organization: org, project:,
                      status: create(:ticket_status, :in_review, organization: org), reviewer: owner, **attributes)
    end

    it "mostra il primo paragrafo del verbale e rimanda alla pagina intera per il resto" do
      ticket = review_ticket(title: "Da revisionare", description: "Descrizione lunga del ticket.",
                             technical_analysis: "Analisi tecnica con nomi di classi.")
      create(:ticket_report, ticket:, organization: org,
                             body: "Ho corretto il salvataggio e aggiunto le prove.\n\nDettaglio tecnico: concern e macro.")
      sign_in(owner)

      get member_home_approvals_path(item: "review:#{ticket.id}")

      expect(response.body).to include("Ho corretto il salvataggio e aggiunto le prove.")
      expect(response.body).not_to include("Dettaglio tecnico: concern e macro.")
      expect(response.body).not_to include("Descrizione lunga del ticket.")
      expect(response.body).not_to include("Analisi tecnica con nomi di classi.")
      expect(response.body).to include('data-test="approvals-compact-more"')
    end

    it "senza verbale mostra il primo paragrafo della descrizione, tagliato" do
      ticket = review_ticket(title: "Da revisionare",
                             description: "Il pulsante salva non risponde.\n\nPassi per riprodurre lunghi.")
      sign_in(owner)

      get member_home_approvals_path(item: "review:#{ticket.id}")

      expect(response.body).to include('data-test="approvals-detail-report-none"')
      expect(response.body).to include('data-test="approvals-compact-ticket-gist"')
      expect(response.body).to include("Il pulsante salva non risponde.")
      expect(response.body).not_to include("Passi per riprodurre lunghi.")
    end

    it "sulla pagina intera restano verbale integrale, descrizione e analisi" do
      ticket = review_ticket(title: "Da revisionare", description: "Descrizione lunga del ticket.",
                             technical_analysis: "Analisi tecnica con nomi di classi.")
      create(:ticket_report, ticket:, organization: org,
                             body: "Ho corretto il salvataggio e aggiunto le prove.\n\nDettaglio tecnico: concern e macro.")
      sign_in(owner)

      get member_home_approvals_item_path(kind: "review", id: ticket.id)

      expect(response.body).to include("Dettaglio tecnico: concern e macro.")
      expect(response.body).to include("Descrizione lunga del ticket.")
      expect(response.body).to include("Analisi tecnica con nomi di classi.")
    end

    it "senza verbale continua a dichiararlo anche in card compatta" do
      ticket = review_ticket(title: "Da revisionare")
      sign_in(owner)

      get member_home_approvals_path(item: "review:#{ticket.id}")

      expect(response.body).to include(I18n.t("member.approvals.delivered.none"))
    end
  end
end
