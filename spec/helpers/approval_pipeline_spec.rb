# frozen_string_literal: true

require "rails_helper"

# CYRA-591 — la striscia dei passaggi in cima alla scheda di una lavorazione.
#
# PERCHÉ UNA SPEC A PARTE: passando solo dalla pagina si prova UNA disposizione per volta, e la prima
# stesura fu verde su entrambe le disposizioni che provava mentre sbagliava le altre. Qui si copre
# ogni stato che aspetta una persona (`Queue::HUMAN_GATED_PHASES`) e i due modi in cui una
# lavorazione ferma può presentarsi.
RSpec.describe HomeHelper, type: :helper do
  let(:org) { create(:organization) }
  let(:project) { create(:project, organization: org) }

  def ticket = create(:ticket, organization: org, project:)

  def card_for(workflow, phase:, attempt: nil)
    Home::Approvals::Detail::Card.new(
      kind: "agent_plan", key: "agent_plan:#{workflow.id}", record: workflow, ticket: workflow.ticket,
      project:, phase:, plan: nil, attempt:, report: nil, delivery_attempt: nil,
      candidate: nil, decisions: [], url: "/"
    )
  end

  def stati(card) = helper.approval_pipeline(card).to_h { |s| [ s[:phase], s[:state] ] }

  describe "ogni stato che aspetta una persona segna il SUO passaggio" do
    it "il piano da approvare accende la pianificazione" do
      workflow = create(:agent_workflow, ticket:, triaged_at: 1.day.ago, planned_at: Time.current)

      expect(stati(card_for(workflow, phase: "awaiting_approval"))["plan_to_approve"]).to eq("current")
    end

    it "il lavoro consegnato accende la lavorazione" do
      workflow = create(:agent_workflow, ticket:, triaged_at: 2.days.ago, planned_at: 1.day.ago,
                                         approved_at: 1.day.ago, autopilot_completed_at: Time.current)

      expect(stati(card_for(workflow, phase: "awaiting_autopilot_approval"))["to_review"]).to eq("current")
    end

    # CYRA-629 — qui c'era anche «il rilascio da autorizzare accende la produzione». Il terzo
    # permesso non esiste più: conclusa la prova di staging il rilascio parte da solo, quindi non è
    # più uno stato che aspetta una persona e non ha più posto in questo elenco. Che il passaggio
    # «closing» si accenda lo prova la lavorazione in coda per la produzione, più sotto.

    # CYRA-619 — il guard che tiene insieme la striscia e il vocabolario del dominio: uno stato nuovo
    # che aspetta una persona, senza il suo passaggio, non deve poter passare in silenzio.
    it "nessuno stato che aspetta una persona resta senza il suo passaggio" do
      ammessi = Agents::Workflows::PhaseResolver::STEPS + [ "blocked" ]

      Home::Approvals::Queue::HUMAN_GATED_PHASES.each do |stato|
        expect(ammessi).to include(Agents::Workflows::PhaseResolver.stage(stato)), stato
      end
    end
  end

  # Il difetto peggiore della prima stesura: su una lavorazione FERMA la striscia dipingeva «sei qui»
  # su un passaggio, mentre il corpo appena sotto diceva che era morta. Nessun passaggio è in corso
  # quando nessuno ci sta lavorando.
  describe "la lavorazione ferma" do
    it "segna respinto il passaggio scritto dal dominio, e NIENTE è in corso" do
      workflow = create(:agent_workflow, ticket:, triaged_at: 2.days.ago, planned_at: 1.day.ago,
                                         approved_at: 1.day.ago, blocked_at: Time.current,
                                         blocked_phase: "autopilot", blocked_kind: "attempt_limit")

      stato = stati(card_for(workflow, phase: "review_blocked"))

      expect(stato["in_progress"]).to eq("failed")
      expect(stato.values).not_to include("current")
    end

    # Quando l'host muore i tentativi restano `stale`: nessuno risulta respinto, e leggendo solo
    # quelli la striscia non avrebbe niente di rosso da mostrare su una lavorazione morta.
    it "vale anche senza nessun tentativo respinto da leggere" do
      workflow = create(:agent_workflow, ticket:, triaged_at: 2.days.ago, planned_at: 1.day.ago,
                                         approved_at: 1.day.ago, blocked_at: Time.current,
                                         blocked_phase: "autopilot", blocked_kind: "attempt_limit")

      stato = stati(card_for(workflow, phase: "review_blocked", attempt: nil))

      expect(stato["in_progress"]).to eq("failed")
    end

    # E una bocciatura VECCHIA, di un passaggio poi superato, non deve tingere di rosso un passaggio
    # che invece è stato approvato: comanda la colonna del dominio, non l'ultimo tentativo trovato.
    it "una bocciatura superata non segna respinto un passaggio poi concluso" do
      workflow = create(:agent_workflow, ticket:, triaged_at: 2.days.ago, planned_at: 1.day.ago,
                                         approved_at: 1.day.ago, blocked_at: Time.current,
                                         blocked_phase: "autopilot", blocked_kind: "attempt_limit")
      vecchio = create(:agent_attempt, workflow:, organization: org, phase: "planner", status: :review_failed)

      stato = stati(card_for(workflow, phase: "review_blocked", attempt: vecchio))

      expect(stato["plan_to_approve"]).to eq("pending")
      expect(stato["in_progress"]).to eq("failed")
    end
  end

  # Ogni stato che la striscia può emettere dev'essere scrivibile a parole: senza il suo testo
  # resterebbe distinguibile solo dal colore, e la pagina dichiara WCAG AA. Si guarda ciò che ESCE
  # davvero da lavorazioni vere, non un elenco ricopiato — quello proverebbe solo sé stesso.
  it "ogni stato che esce ha un testo che lo dice, non solo un colore" do
    lavorazioni = [
      card_for(create(:agent_workflow, ticket:, triaged_at: 1.day.ago, planned_at: Time.current),
               phase: "awaiting_approval"),
      card_for(create(:agent_workflow, :closer_staging_completed, ticket:),
               phase: "closer_production_queued"),
      card_for(create(:agent_workflow, ticket:, triaged_at: 2.days.ago, planned_at: 1.day.ago,
                                       approved_at: 1.day.ago, blocked_at: Time.current,
                                       blocked_phase: "autopilot", blocked_kind: "attempt_limit"), phase: "review_blocked")
    ]
    emessi = lavorazioni.flat_map { |c| helper.approval_pipeline(c).map { |s| s[:state] } }.uniq

    expect(emessi).to include("done", "current", "pending", "failed")
    emessi.each do |stato|
      expect(I18n.t("member.approvals.phase_state.#{stato}", default: "")).to be_present,
                                                                             "manca il testo per lo stato #{stato}"
    end
  end

  it "senza una lavorazione automatica dietro non c'è nessuna striscia da mostrare" do
    card = Home::Approvals::Detail::Card.new(
      kind: "secret_change", key: "secret_change:#{SecureRandom.uuid}", record: nil, ticket: nil,
      project:, phase: nil, plan: nil, attempt: nil, report: nil, delivery_attempt: nil,
      candidate: nil, decisions: [], url: "/"
    )

    expect(helper.approval_pipeline(card)).to be_nil
  end
end
