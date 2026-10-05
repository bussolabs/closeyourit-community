# frozen_string_literal: true

require "rails_helper"

RSpec.describe Agents::Attempts::Deliver do
  # Scope di consegna: tentativo con le colonne profilo immutabili (host, service account, fase, skill) e
  # lease pinnato su execution_phase + profile_digest. L'host ha un service account che vede il progetto e
  # coincide con quello snapshottato sul tentativo (attribuzione host-first). Unico scope rimasto: il ramo
  # legacy con agente/comando/istruzione è caduto con MT-9.
  def build_delivery_scope(phase:, organization:, project:, ticket:, workflow:)
    Agents::Lease.where(ticket:).delete_all
    # PIVOT CYAU-87: runtime della fase dal PhaseProfile (autopilot/closer ora "claude"). L'host lo presenta e
    # l'attempt lo snapshotta; il payload dev'essere coerente (runtime primario + reviewer opposto in Deliver).
    profile = Agents::PhaseProfile.for(phase)
    runtime = profile.runtime
    host_sa = Accounts::Service::Create.call(organization:, name: "Host SA host-first",
                                             project_ids: [ project.id ]).value
    host = create(:agent_host, organization:, service_account: host_sa, last_heartbeat_at: Time.current,
                               repositories: [ project.key ],
                               runtimes: [ { "name" => runtime, "present" => true } ])
    attempt = create(:agent_attempt, organization:, workflow:, host:, service_account: host_sa,
                                     skill_key: profile.skill_key,
                                     external_run_id: "run-hf-#{phase}", phase:, runtime:)
    create(:agent_lease, organization:, ticket:, host:, run_id: "run-hf-#{phase}",
                         execution_phase: phase, profile_digest: profile.digest, expires_at: 5.minutes.from_now)
    { host:, attempt:, host_sa:, runtime: }
  end

  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let!(:repository) { create(:github_repository, project:) }
  let(:ticket) { create(:ticket, organization:, project:, with_agent_workflow: true) }
  let(:workflow) { ticket.agent_workflow }
  # Host-first: Deliver invoca Agents::Hosts::Eligibility, ora host-only (ProjectScope CYAU-95): l'host
  # che consegna deve avere un service account che vede il progetto, altrimenti viene respinto.
  let(:host_service_account) do
    Accounts::Service::Create.call(organization:, name: "Host SA", project_ids: [ project.id ]).value
  end
  let(:host) do
    create(:agent_host, organization:, service_account: host_service_account, last_heartbeat_at: Time.current,
                        repositories: [ project.key ],
                        runtimes: [ { "name" => "claude", "present" => true,
                                      "version" => "1", "required" => true } ])
  end
  let(:attempt) do
    create(:agent_attempt, organization:, workflow:, host:, service_account: host_service_account,
                           skill_key: "/closeyourit-triage", external_run_id: "run-42", phase: "triage",
                           runtime: "claude")
  end
  let!(:lease) do
    create(:agent_lease, organization:, ticket:, host:, run_id: "run-42",
                         execution_phase: "triage", profile_digest: Agents::PhaseProfile.for("triage").digest,
                         expires_at: 5.minutes.from_now)
  end
  # Campi di classificazione comuni al result reale del triage (contratto agent-result/v1).
  let(:triage_meta) do
    { code: ticket.code, category: "backend", capabilities: [ "backend" ], risk: "low",
      requires_human_approval: false, reasons: [ "Serve un chiarimento" ] }
  end
  let(:payload) do
    {
      runtime: "claude", reviewer_runtime: "codex",
      result: triage_meta.merge(state: "needs-clarification", questions: [ "Quale risultato ti aspetti?" ]),
      review: { status: "accepted", summary: "Domanda chiara e necessaria.", depth: "result" }
    }
  end

  before do
    workflow.update!(triage_started_at: Time.current, ticket_snapshot_digest: "snapshot")
  end

  # CYRA-921
  context "when the machine reviews with the same engine" do
    before { host.update!(review_mode: "same") }

    it "accepts a review by the same engine" do
      result = described_class.call(organization:, host:, attempt:, payload: payload.merge(reviewer_runtime: "claude"))

      expect(result).to be_ok
      expect(attempt.reload).to be_status_approved
    end

    it "refuses a review by the other engine, which the machine said it does not use" do
      result = described_class.call(organization:, host:, attempt:, payload:)

      expect(attempt.reload).not_to be_status_approved
      expect(result.ok? && attempt.status_approved?).to be(false)
    end
  end

  it "keeps asking the other engine by default" do
    expect(host.review_mode).to eq("cross")
    result = described_class.call(organization:, host:, attempt:, payload: payload.merge(reviewer_runtime: "claude"))

    expect(attempt.reload).not_to be_status_approved
    expect(result.ok? && attempt.status_approved?).to be(false)
  end

  # Il commento lo scrive il server perché la skill non può (sessione sandboxata, CYAU-109), ma
  # ANNUNCIA soltanto: la domanda vive nel record e si legge nella scheda Automazione (CYRA-221).
  it "registra le domande di chiarimento e le annuncia sul ticket (la skill non può)" do
    result = described_class.call(organization:, host:, attempt:, payload:)

    expect(result).to be_ok
    expect(attempt.reload).to be_status_approved
    comment = ticket.comments.sole
    expect(comment.body).not_to include("Quale risultato ti aspetti?")
    # CYRA-784 — nessuna riga di servizio nascosta: lo stato del ciclo si chiede all'endpoint.
    expect(comment.body).not_to include("<!--")
    expect(comment.author).to eq(host_service_account)
    giro = workflow.clarifications.sole
    expect(giro.question_comment_id).to eq(comment.id)
    expect(giro.questions.map(&:body)).to eq([ "Quale risultato ti aspetti?" ])
  end

  it "avvisa chi deve rispondere: una domanda che non arriva a nessuno resta senza risposta" do
    described_class.call(organization:, host:, attempt:, payload:)

    expect(Ticketing::CommentNotifyJob)
      .to have_been_enqueued.with(comment_id: ticket.comments.sole.id, mentioned_ids: [])
  end

  it "fallisce chiuso senza review corretta e non produce effetti" do
    result = described_class.call(
      organization:, host:, attempt:, payload: payload.deep_merge(review: { status: "changes_requested" })
    )

    expect(result).to be_err
    expect(result.error.code).to eq("R409-ATTEMPT-003")
    expect(attempt.reload).to be_status_review_failed
    expect(workflow.clarifications).to be_empty
  end

  it "è idempotente sullo stesso payload e rifiuta payload diversi" do
    expect(described_class.call(organization:, host:, attempt:, payload:)).to be_ok
    expect do
      expect(described_class.call(organization:, host:, attempt:, payload:)).to be_ok
    end.to not_change(Agents::Clarification, :count).and not_change(ticket.comments, :count)

    conflict = described_class.call(
      organization:, host:, attempt:, payload: payload.deep_merge(review: { summary: "Diversa" })
    )
    expect(conflict.error.code).to eq("R409-ATTEMPT-002")
  end

  context "rivalidazione del lease host-first (CYAU-96)" do
    before do
      lease.update!(agent: nil, execution_phase: "triage",
                    profile_digest: Agents::PhaseProfile.for("triage").digest)
    end

    it "rivalida sul profilo di fase, non più sullo slug agent" do
      expect(described_class.call(organization:, host:, attempt:, payload:)).to be_ok
    end

    it "fallisce chiuso se l'execution_phase del lease non è quella del tentativo" do
      lease.update!(execution_phase: "planner", profile_digest: Agents::PhaseProfile.for("planner").digest)

      expect(described_class.call(organization:, host:, attempt:, payload:).error.code).to eq("R409-ATTEMPT-001")
    end

    it "fallisce chiuso se il profile_digest del lease è manomesso" do
      lease.update!(profile_digest: "f" * 64)

      expect(described_class.call(organization:, host:, attempt:, payload:).error.code).to eq("R409-ATTEMPT-001")
    end

    it "resta idempotente sul replay di una delivery approvata anche se il PhaseProfile è poi cambiato" do
      expect(described_class.call(organization:, host:, attempt:, payload:)).to be_ok
      expect(attempt.reload).to be_status_approved

      allow(Agents::PhaseProfile).to receive(:for).with("triage")
        .and_return(instance_double(Agents::PhaseProfile, digest: "d" * 64, runtime: "claude", ttl: 3600,
                                    write_access?: false, review_depth: "result",
                                    effect: Agents::Attempts::Effects::Triage))

      expect(described_class.call(organization:, host:, attempt:, payload:)).to be_ok
    end
  end

  it "rifiuta lease perso e scope revocato" do
    lease.update!(expires_at: 1.minute.ago)

    expect(described_class.call(organization:, host:, attempt:, payload:).error.code).to eq("R409-ATTEMPT-001")
    expect(workflow.clarifications).to be_empty
  end

  # CYRA-218 — il tetto ai tentativi di revisione. Una bocciatura non muove i timestamp su cui poggia la
  # prontezza della fase: senza budget la stessa fase resta reclamabile e si rifà, identica, all'infinito.
  describe "tetto ai tentativi bocciati in revisione (CYRA-218)" do
    let(:rejected) { payload.deep_merge(review: { status: "changes_requested" }) }

    # "Si riprova" va chiesto alla CODA, non all'assenza del blocco. Verificare solo `blocked_at: nil`
    # lasciava passare il caso reale: il claim ha scritto <fase>_started_at, quindi senza riaprire la fase
    # READY_EXECUTION_PHASE_SQL smette di proporla e il ticket esce dalla coda alla PRIMA bocciatura, in
    # silenzio e senza blocco. È successo davvero, e nessuno se n'è accorto finché non l'ho sbloccato a
    # mano sei volte in un giorno.
    it "alla prima bocciatura non blocca E rimette la fase in coda" do
      expect(described_class.call(organization:, host:, attempt:, payload: rejected)).to be_err

      expect(workflow.reload.blocked_at).to be_nil
      expect(workflow.triage_started_at).to be_nil
      expect(workflow.ready_execution_phase).to eq("triage")
    end

    # Il secondo tentativo è un attempt DIVERSO sulla stessa fase (quello bocciato è terminale e
    # immutabile): è la storia della fase a contare, non il singolo record.
    it "alla seconda bocciatura sulla stessa fase ferma la lavorazione e ne scrive il motivo" do
      described_class.call(organization:, host:, attempt:, payload: rejected)
      second = build_delivery_scope(phase: "triage", organization:, project:, ticket:, workflow:)

      described_class.call(organization:, host: second[:host], attempt: second[:attempt], payload: rejected)

      expect(workflow.reload).to have_attributes(blocked_phase: "triage")
      expect(workflow.blocked_at).to be_present
      expect(workflow.blocked_reason).to be_present
    end

    it "la lavorazione bloccata esce dalla coda: nessuna fase resta reclamabile" do
      described_class.call(organization:, host:, attempt:, payload: rejected)
      second = build_delivery_scope(phase: "triage", organization:, project:, ticket:, workflow:)
      described_class.call(organization:, host: second[:host], attempt: second[:attempt], payload: rejected)

      expect(workflow.reload.ready_execution_phase).to be_nil
    end

    # Il budget riparte quando una persona decide di riprovare. Contando tutta la storia della fase, il
    # tentativo concesso dallo sblocco sarebbe l'unico: bocciato quello, il conteggio storico è già oltre
    # il tetto e il blocco tornerebbe subito — "Riprova" darebbe un solo colpo invece dei due dichiarati.
    it "dopo uno sblocco il budget riparte da capo" do
      described_class.call(organization:, host:, attempt:, payload: rejected)
      second = build_delivery_scope(phase: "triage", organization:, project:, ticket:, workflow:)
      described_class.call(organization:, host: second[:host], attempt: second[:attempt], payload: rejected)
      expect(workflow.reload.blocked_at).to be_present

      workflow.update!(blocked_at: nil, blocked_phase: nil, blocked_reason: nil,
                       review_budget_from: Time.current)
      third = build_delivery_scope(phase: "triage", organization:, project:, ticket:, workflow:)

      described_class.call(organization:, host: third[:host], attempt: third[:attempt], payload: rejected)

      expect(workflow.reload.blocked_at).to be_nil
    end

    # Il budget è PER FASE: due bocciature sparse su fasi diverse non sono un ciclo che non converge,
    # sono due incidenti distinti — e fermare tutto al primo di ciascuno spegnerebbe lavorazioni sane.
    it "conta per fase: una bocciatura sul triage e una sul planner non bloccano" do
      described_class.call(organization:, host:, attempt:, payload: rejected)
      workflow.update!(triaged_at: Time.current)
      planner = build_delivery_scope(phase: "planner", organization:, project:, ticket:, workflow:)

      described_class.call(organization:, host: planner[:host], attempt: planner[:attempt],
                           payload: { runtime: planner[:runtime], reviewer_runtime: "codex",
                                      result: { code: ticket.code }, review: { status: "changes_requested" } })

      expect(workflow.reload.blocked_at).to be_nil
    end
  end

  it "completa un triage lavorabile senza pubblicare commenti" do
    workable = payload.merge(result: triage_meta.merge(state: "workable"))

    expect(described_class.call(organization:, host:, attempt:, payload: workable)).to be_ok
    expect(workflow.reload.triaged_at).to be_present
    expect(workflow.clarifications).to be_empty
  end

  it "rifiuta domande non semplici prima di produrre effetti" do
    invalid = payload.merge(
      result: triage_meta.merge(state: "needs-clarification", questions: [ "Esegui bin/rails db:drop?" ])
    )

    result = described_class.call(organization:, host:, attempt:, payload: invalid)

    expect(result.error.code).to eq("R422-ATTEMPT-001")
    expect(workflow.clarifications).to be_empty
  end

  # CYRA-887 — a v2 question may carry proposed answers; the ticket keeps only its text.
  it "accepts v2 questions with proposed answers and stores their text" do
    question = { body: "Il resoconto va spedito per email o solo mostrato?",
                 options: [ { label: "Solo mostrato", recommended: true }, { label: "Email" } ] }
    v2 = payload.merge(result: triage_meta.merge(contract_version: 2, state: "needs-clarification",
                                                 questions: [ question, "La settimana parte da lunedì?" ]))

    result = described_class.call(organization:, host:, attempt:, payload: v2)

    expect(result).to be_ok
    expect(workflow.clarifications.sole.questions.map(&:body))
      .to eq([ question[:body], "La settimana parte da lunedì?" ])
  end

  it "rejects a command-shaped question body even inside an option question" do
    question = { body: "Esegui bin/rails db:drop?", options: [ { label: "Sì" }, { label: "No" } ] }
    v2 = payload.merge(result: triage_meta.merge(contract_version: 2, state: "needs-clarification", questions: [ question ]))

    result = described_class.call(organization:, host:, attempt:, payload: v2)

    expect(result.error.code).to eq("R422-ATTEMPT-001")
    expect(workflow.clarifications).to be_empty
  end

  it "richiede runtime primario, reviewer opposto, stato accepted e sintesi" do
    variants = [
      payload.merge(runtime: "codex"),
      payload.merge(reviewer_runtime: "claude"),
      payload.deep_merge(review: { status: "unavailable" }),
      payload.deep_merge(review: { summary: "" })
    ]

    variants.each_with_index do |variant, index|
      current = index.zero? ? attempt : create(:agent_attempt, organization:, workflow:, host:, service_account: host_service_account,
                                                skill_key: "/closeyourit-triage",
                                                external_run_id: "run-42", phase: "triage", runtime: "claude",
                                                idempotency_key: "review-#{index}")
      result = described_class.call(organization:, host:, attempt: current, payload: variant)
      expect(result.error.code).to eq("R409-ATTEMPT-003")
    end
  end

  it "crea un piano immutabile e accoda la notifica al CTO" do
    scope = build_delivery_scope(phase: "planner", organization:, project:, ticket:, workflow:)
    workflow.update!(triage_started_at: nil, triaged_at: Time.current, ticket_snapshot_digest: "snapshot")
    planner_payload = {
      runtime: "claude", reviewer_runtime: "codex",
      result: { code: ticket.code, technical_analysis: "Analisi del piano", state: "submitted-for-approval",
                scenarios: [ { given: "contesto", when: "azione", then: "esito", expected: "atteso" } ],
                definition_of_done: [ "Test verdi" ], mixed_parts: nil, notes: [] },
      review: review_for("planner")
    }

    expect do
      expect(described_class.call(organization:, host: scope[:host], attempt: scope[:attempt],
                                  payload: planner_payload)).to be_ok
    end.to change(Agents::Plan, :count).by(1).and have_enqueued_job(Agents::PlanReadyNotificationJob)
    expect(workflow.reload).to have_attributes(planned_at: be_present, phase: "awaiting_approval")
    expect(workflow.plans.sole).to have_attributes(version: 1, ticket_snapshot_digest: "snapshot")
  end

  it "conserva un piano v2 strutturato e genera la proiezione leggibile" do
    scope = build_delivery_scope(phase: "planner", organization:, project:, ticket:, workflow:)
    workflow.update!(triage_started_at: nil, triaged_at: Time.current, ticket_snapshot_digest: "snapshot")
    result = JSON.parse(Rails.root.join("contracts/agent-result/v2/fixtures/valid/planner.json").read)
    result["code"] = ticket.code

    delivered = described_class.call(
      organization:, host: scope[:host], attempt: scope[:attempt],
      payload: { runtime: "claude", reviewer_runtime: "codex", result:, review: review_for("planner") }
    )

    expect(delivered).to be_ok
    expect(workflow.plans.sole).to have_attributes(contract_version: 2, content: include("work_items"))
    expect(workflow.plans.sole.technical_analysis).to include("Conservare il piano strutturato")
  end

  # CYRA-702 — il brief decisionale viaggia al top level del result (dentro `plan` lo schema lo
  # rifiuterebbe) e si persiste solo se c'è: i planner non aggiornati continuano a consegnare.
  it "persiste il brief decisionale quando il planner lo scrive, e resta nil quando manca" do
    scope = build_delivery_scope(phase: "planner", organization:, project:, ticket:, workflow:)
    workflow.update!(triage_started_at: nil, triaged_at: Time.current, ticket_snapshot_digest: "snapshot")
    result = JSON.parse(Rails.root.join("contracts/agent-result/v2/fixtures/valid/planner.json").read)
    result["code"] = ticket.code
    result["decision_brief"] = "L'app potra' creare gli eventi come dal computer."

    delivered = described_class.call(
      organization:, host: scope[:host], attempt: scope[:attempt],
      payload: { runtime: "claude", reviewer_runtime: "codex", result:, review: review_for("planner") }
    )

    expect(delivered).to be_ok
    expect(workflow.plans.sole.decision_brief).to eq("L'app potrà creare gli eventi come dal computer.")
  end

  # CYRA-675 — «era già fatto». È l'unico punto del sistema in cui una consegna chiude un ticket da
  # sola: le difese stanno tutte a monte (prove obbligatorie nello schema, sì della rilettura
  # incrociata) e qui si verifica che l'esecuzione faccia esattamente quello che dichiara.
  describe "il lavoro trovato già fatto" do
    let(:done_status) { create(:ticket_status, :done, organization:) }
    let(:already_done_result) do
      { contract_version: 2, code: ticket.code, state: "already-done",
        already_done: {
          summary: "Il gate dei duplicati esiste già, con la pagina di confronto.",
          sources: [ { path: "app/services/ticketing/resolve_duplicate.rb", line: 4,
                       reason: "È il gate che il ticket chiedeva di scrivere." } ]
        } }
    end

    def consegna(result)
      scope = build_delivery_scope(phase: "planner", organization:, project:, ticket:, workflow:)
      workflow.update!(triage_started_at: nil, triaged_at: Time.current, ticket_snapshot_digest: "snapshot")
      described_class.call(organization:, host: scope[:host], attempt: scope[:attempt],
                           payload: { runtime: "claude", reviewer_runtime: "codex", result:,
                                      review: review_for("planner") })
    end

    before { done_status }

    it "chiude il ticket, conclude la lavorazione e non scrive nessun piano" do
      expect(consegna(already_done_result)).to be_ok

      expect(ticket.reload.status).to eq(done_status)
      expect(workflow.reload).to have_attributes(completed_at: be_present, planned_at: nil, phase: "completed")
      expect(workflow.plans).to be_empty
    end

    # Il commento è la riga che legge chi apre il ticket; le prove restano nella cronologia, con i
    # file, perché una chiusura automatica va potuta rimettere in discussione.
    it "lascia una riga sul ticket e i file provati in cronologia" do
      consegna(already_done_result)

      # La riga è quella di servizio, nella lingua di chi ha aperto il ticket: la legge una persona,
      # non la macchina. Il riassunto dell'agente NON ci entra — un commento ha un tetto di caratteri
      # e il riassunto no, e interpolarlo qui farebbe fallire la validazione dentro la transazione.
      atteso = I18n.t("agents.already_done.service_line",
                      locale: ticket.reporter&.effective_locale || I18n.default_locale)
      expect(ticket.reload.comments.last).to have_attributes(kind: "service", body: atteso)
      evento = ticket.events.find_by(action: "already_done")
      expect(evento.data["summary"]).to include("gate dei duplicati")
      expect(evento.data["sources"].first["path"]).to eq("app/services/ticketing/resolve_duplicate.rb")
    end

    it "senza le prove la consegna viene respinta e il ticket non si muove" do
      senza_prove = already_done_result.deep_dup
      senza_prove[:already_done].delete(:sources)

      esito = consegna(senza_prove)

      expect(esito.error.code).to eq("R422-ATTEMPT-001")
      expect(ticket.reload.status).not_to eq(done_status)
      expect(workflow.reload.completed_at).to be_nil
    end

    # Il vocabolario nuovo vive solo nella v2: un result senza contract_version è validato contro la
    # v1, che non lo conosce. Fail-closed voluto — un producer vecchio non può chiudere ticket.
    it "non è ammesso su un result della vecchia versione" do
      esito = consegna(already_done_result.except(:contract_version))

      expect(esito.error.code).to eq("R422-ATTEMPT-001")
      expect(workflow.reload.completed_at).to be_nil
    end

    # Prerequisiti ancora aperti: il ticket NON si chiude, la lavorazione si ferma e resta scritto
    # perché. Chiudere qui vorrebbe dire dichiarare finito un lavoro che aspetta un altro ticket.
    it "con un prerequisito aperto non chiude niente e chiama una persona" do
      blocker = create(:ticket, organization:, project:)
      create(:ticket_dependency, ticket:, blocker:)

      expect(consegna(already_done_result)).to be_ok

      expect(ticket.reload.status).not_to eq(done_status)
      expect(workflow.reload).to have_attributes(completed_at: nil, blocked_at: be_present)
      expect(workflow.blocked_reason).to include("già fatto")
      expect(ticket.events.where(action: "dependency_blocked")).to be_present
    end

    # Un'organizzazione senza uno stato conclusivo attivo: il lavoro è finito e il ticket resterebbe
    # aperto per sempre, riproposto al planner a ogni giro. Meglio fermarsi e dirlo.
    it "senza uno stato conclusivo configurato si ferma invece di lasciare il ticket appeso" do
      organization.ticket_statuses.category_done.update_all(active: false)

      expect(consegna(already_done_result)).to be_ok

      expect(workflow.reload).to have_attributes(completed_at: nil, blocked_at: be_present)
      expect(workflow.blocked_reason).to include("stato conclusivo")
    end
  end

  it "rifiuta un piano con campi non-array" do
    scope = build_delivery_scope(phase: "planner", organization:, project:, ticket:, workflow:)
    workflow.update!(triage_started_at: nil, triaged_at: Time.current, ticket_snapshot_digest: "snapshot")
    invalid = {
      runtime: "claude", reviewer_runtime: "codex",
      result: { code: ticket.code, technical_analysis: "Piano", state: "submitted-for-approval",
                scenarios: "uno", definition_of_done: [], mixed_parts: nil, notes: [] },
      review: review_for("planner")
    }

    expect(described_class.call(organization:, host: scope[:host], attempt: scope[:attempt],
                                payload: invalid).error.code).to eq("R422-ATTEMPT-001")
    expect(workflow.plans).to be_empty
  end

  it "rifiuta un result il cui code non è quello del ticket del tentativo (anti cross-ticket)" do
    foreign = payload.merge(result: triage_meta.merge(code: "ALTRO-999", state: "workable"))

    expect(described_class.call(organization:, host:, attempt:, payload: foreign).error.code).to eq("R422-ATTEMPT-001")
    expect(workflow.reload.triaged_at).to be_nil
  end

  it "rifiuta un result conforme ai vecchi predicati ma non al contratto (scenari non strutturati)" do
    scope = build_delivery_scope(phase: "planner", organization:, project:, ticket:, workflow:)
    workflow.update!(triage_started_at: nil, triaged_at: Time.current, ticket_snapshot_digest: "snapshot")
    invalid = {
      runtime: "claude", reviewer_runtime: "codex",
      result: { code: ticket.code, technical_analysis: "Piano", state: "submitted-for-approval",
                scenarios: [ "non un oggetto given/when/then" ], definition_of_done: [], mixed_parts: nil, notes: [] },
      review: review_for("planner")
    }

    expect(described_class.call(organization:, host: scope[:host], attempt: scope[:attempt],
                                payload: invalid).error.code).to eq("R422-ATTEMPT-001")
    expect(workflow.reload.plans).to be_empty
  end

  it "porta l'autopilot consegnato in Review in attesa dell'approvazione umana (non completa)" do
    scope = build_delivery_scope(phase: "autopilot", organization:, project:, ticket:, workflow:)
    review_status = organization.ticket_statuses.review_gates.active.ordered.first ||
                    create(:ticket_status, :in_review, organization:)
    workflow.update!(triage_started_at: nil, triaged_at: Time.current, planned_at: Time.current,
                     approved_at: Time.current, autopilot_started_at: Time.current, ticket_snapshot_digest: "snapshot")
    congela_piano!(workflow)
    autopilot_payload = {
      runtime: "claude", reviewer_runtime: "codex",
      result: { code: ticket.code, state: "delivered", security_findings: [], gate: { passed: true }, review: { verdict: "approved" },
                cycles: 1, delivery: { prUrl: "https://github.com/bussolabs/closeyourit-rails/pull/1", cyiStatus: "in_review", autoMerged: false } },
      review: review_for("autopilot"), observed: observed_head
    }

    expect(described_class.call(organization:, host: scope[:host], attempt: scope[:attempt],
                                payload: autopilot_payload)).to be_ok
    # CYRA-612 — la consegna registra e basta: non sposta il ticket e non chiede niente. La card
    # arriverà nella pila solo dopo che il sistema avrà aperto la proposta e letto i controlli.
    expect(ticket.reload.status).not_to eq(review_status)
    expect(workflow.reload).to have_attributes(autopilot_completed_at: be_present, completed_at: nil,
                                               candidate_verified_at: nil, phase: "verifying_candidate")
  end

  # CYRA-674 — trenta giorni di campo facoltativo hanno dato zero dichiarazioni su 1457 consegne:
  # ora una consegna v1 senza `security_findings` è invalida. L'elenco vuoto resta la risposta
  # legittima («ho guardato, niente»); l'assenza («non ho guardato») viene rifiutata.
  it "rifiuta una consegna v1 senza la dichiarazione delle anomalie di sicurezza" do
    scope = build_delivery_scope(phase: "autopilot", organization:, project:, ticket:, workflow:)
    workflow.update!(triage_started_at: nil, triaged_at: Time.current, planned_at: Time.current,
                     approved_at: Time.current, autopilot_started_at: Time.current,
                     ticket_snapshot_digest: "snapshot")
    congela_piano!(workflow)
    payload = {
      runtime: "claude", reviewer_runtime: "codex",
      result: { code: ticket.code, state: "delivered", gate: { passed: true }, review: { verdict: "approved" },
                cycles: 1, delivery: { prUrl: "https://github.com/bussolabs/closeyourit-rails/pull/1", cyiStatus: "in_review", autoMerged: false } },
      review: review_for("autopilot"), observed: observed_head
    }

    esito = described_class.call(organization:, host: scope[:host], attempt: scope[:attempt], payload:)

    aggregate_failures do
      expect(esito).to be_err
      expect(esito.error.code).to eq("R422-ATTEMPT-001")
      expect(workflow.reload.autopilot_completed_at).to be_nil
    end
  end

  it "conserva resoconto e finding atomici di una consegna v2" do
    scope = build_delivery_scope(phase: "autopilot", organization:, project:, ticket:, workflow:)
    workflow.update!(triage_started_at: nil, triaged_at: Time.current, planned_at: Time.current,
                     approved_at: Time.current, autopilot_started_at: Time.current,
                     ticket_snapshot_digest: "snapshot")
    congela_piano!(workflow)
    result = JSON.parse(Rails.root.join("contracts/agent-result/v2/fixtures/valid/autopilot_delivered.json").read)
    result["code"] = ticket.code
    result["delivery"]["prUrl"] = "https://github.com/bussolabs/closeyourit-rails/pull/123"
    findings = [ { severity: "minor", aspect: "tests", title: "Confine dichiarato", detail: nil } ]

    delivered = described_class.call(
      organization:, host: scope[:host], attempt: scope[:attempt],
      payload: { runtime: "claude", reviewer_runtime: "codex", result:,
                 review: review_for("autopilot", findings:), observed: observed_head }
    )

    expect(delivered).to be_ok
    expect(scope[:attempt].reload.result.dig("work_report", "acceptance_evidence")).to be_present
    expect(scope[:attempt].review.fetch("findings")).to eq(findings.map(&:deep_stringify_keys))
  end

  # CYAU-173 — l'indirizzo della PR e' la prova che il lavoro c'e', e serve a un controllo che viene dopo:
  # il server andra' ad aprire quella PR per leggere il diff e l'esito dei check. Se la forma non e' una che
  # si puo' aprire, quel controllo non parte nemmeno. Questa prova sta a livello di SERVIZIO di proposito:
  # gli spec di contratto validano con un validatore che costruiscono loro, quindi non vedrebbero un
  # allentamento del bundle vendorizzato che il servizio invece userebbe davvero.
  # Ogni forma ha il suo scope: una consegna rifiutata registra comunque il tentativo, quindi riusarne uno
  # solo farebbe rispondere l'idempotenza (R409) al posto della validazione, e il test direbbe «rifiutato»
  # senza aver mai provato la forma.
  [ [ "senza owner e repo", "https://ex/pull/1" ],
    [ "con credenziali", "https://a:b@github.com/bussolabs/repo/pull/1" ],
    [ "numero zero", "https://github.com/bussolabs/repo/pull/0" ],
    [ "pull in mezzo al percorso", "https://github.com/bussolabs/repo/tree/main/pull/1" ] ].each do |etichetta, url|
    it "rifiuta un autopilot il cui prUrl e #{etichetta}: GitHub non potrebbe averlo prodotto" do
      scope = build_delivery_scope(phase: "autopilot", organization:, project:, ticket:, workflow:)
      workflow.update!(triage_started_at: nil, triaged_at: Time.current, planned_at: Time.current,
                       approved_at: Time.current, autopilot_started_at: Time.current, ticket_snapshot_digest: "snapshot")
      congela_piano!(workflow)
      payload = {
        runtime: "claude", reviewer_runtime: "codex",
        result: { code: ticket.code, state: "delivered", security_findings: [], gate: { passed: true }, review: { verdict: "approved" },
                  cycles: 1, delivery: { prUrl: url, cyiStatus: "in_review", autoMerged: false } },
        review: review_for("autopilot"), observed: observed_head
      }

      esito = described_class.call(organization:, host: scope[:host], attempt: scope[:attempt], payload:)

      expect(esito).not_to be_ok
      expect(esito.error.code).to eq("R422-ATTEMPT-001")
      expect(workflow.reload.autopilot_completed_at).to be_nil
    end
  end

  # Il lavoro trovato già consegnato da una sessione precedente avanza come `delivered`: è consegnato
  # davvero, e il contratto lo lascia dire solo con la PR come prova. Senza questo ramo il ticket
  # resterebbe in coda a ripetere all'infinito una lavorazione già compiuta.
  it "porta in Review anche l'autopilot che trova il lavoro già consegnato" do
    scope = build_delivery_scope(phase: "autopilot", organization:, project:, ticket:, workflow:)
    review_status = organization.ticket_statuses.review_gates.active.ordered.first ||
                    create(:ticket_status, :in_review, organization:)
    workflow.update!(triage_started_at: nil, triaged_at: Time.current, planned_at: Time.current,
                     approved_at: Time.current, autopilot_started_at: Time.current, ticket_snapshot_digest: "snapshot")
    congela_piano!(workflow)
    payload = {
      runtime: "claude", reviewer_runtime: "codex",
      result: { code: ticket.code, state: "already-delivered", security_findings: [], gate: { passed: nil }, cycles: 0,
                delivery: { prUrl: "https://github.com/bussolabs/closeyourit-rails/pull/7", cyiStatus: "in_review", autoMerged: false },
                reason: "Piano già implementato e consegnato in una sessione precedente" },
      observed: observed_head, review: review_for("autopilot", summary: "Nulla di nuovo da revisionare")
    }

    expect(described_class.call(organization:, host: scope[:host], attempt: scope[:attempt],
                                payload:)).to be_ok
    # CYRA-612 — la consegna registra e basta: non sposta il ticket e non chiede niente. La card
    # arriverà nella pila solo dopo che il sistema avrà aperto la proposta e letto i controlli.
    expect(ticket.reload.status).not_to eq(review_status)
    expect(workflow.reload).to have_attributes(autopilot_completed_at: be_present, completed_at: nil,
                                               candidate_verified_at: nil, phase: "verifying_candidate")
  end

  # La skill autopilot VIETA all'agente di scriversi `approved` da solo: il verdetto lo mette l'automator
  # dopo la cross review. Pretendere `approved` + `gate.passed: true` qui buttava via ogni consegna onesta —
  # PR aperta compresa — e il ticket non arrivava mai al gate umano. `false` resta rifiutato: un gate
  # eseguito e fallito non è una consegna.
  it "porta in Review l'autopilot che non ha potuto eseguire il gate né scriversi il verdetto" do
    scope = build_delivery_scope(phase: "autopilot", organization:, project:, ticket:, workflow:)
    review_status = organization.ticket_statuses.review_gates.active.ordered.first ||
                    create(:ticket_status, :in_review, organization:)
    workflow.update!(triage_started_at: nil, triaged_at: Time.current, planned_at: Time.current,
                     approved_at: Time.current, autopilot_started_at: Time.current, ticket_snapshot_digest: "snapshot")
    congela_piano!(workflow)
    payload = {
      runtime: "claude", reviewer_runtime: "codex",
      result: { code: ticket.code, state: "delivered", security_findings: [],
                gate: { passed: nil, note: "nessun .closeyourit/quality-gate.yml; suite non eseguibile nel sandbox" },
                review: { verdict: "unavailable" }, cycles: 1,
                delivery: { prUrl: "https://github.com/bussolabs/closeyourit-rails/pull/51", cyiStatus: "in_review", autoMerged: false } },
      observed: observed_head, review: review_for("autopilot", summary: "Diff conforme al piano approvato")
    }

    expect(described_class.call(organization:, host: scope[:host], attempt: scope[:attempt],
                                payload:)).to be_ok
    # CYRA-612 — la consegna registra e basta: non sposta il ticket e non chiede niente. La card
    # arriverà nella pila solo dopo che il sistema avrà aperto la proposta e letto i controlli.
    expect(ticket.reload.status).not_to eq(review_status)
    expect(workflow.reload).to have_attributes(autopilot_completed_at: be_present, completed_at: nil,
                                               candidate_verified_at: nil, phase: "verifying_candidate")
  end

  it "rifiuta l'autopilot consegnato con il quality gate eseguito e fallito" do
    scope = build_delivery_scope(phase: "autopilot", organization:, project:, ticket:, workflow:)
    workflow.update!(triage_started_at: nil, triaged_at: Time.current, planned_at: Time.current,
                     approved_at: Time.current, autopilot_started_at: Time.current, ticket_snapshot_digest: "snapshot")
    congela_piano!(workflow)
    payload = {
      runtime: "claude", reviewer_runtime: "codex",
      result: { code: ticket.code, state: "delivered", security_findings: [], gate: { passed: false }, review: { verdict: "approved" },
                cycles: 1, delivery: { prUrl: "https://github.com/bussolabs/closeyourit-rails/pull/52", cyiStatus: "in_review", autoMerged: false } },
      review: review_for("autopilot"), observed: observed_head
    }

    expect(described_class.call(organization:, host: scope[:host], attempt: scope[:attempt],
                                payload:)).not_to be_ok
    expect(workflow.reload.autopilot_completed_at).to be_nil
  end

  # CYRA-504 — la consegna dello staging non manda più in coda la produzione: la ferma in attesa del
  # via libera di una persona, e il ticket resta dov'era.
  # CYRA-620 — consegnare non basta più: la produzione si apre sulla PROVA che il codice approvato è
  # atterrato, non sulla parola della macchina. Subito dopo la consegna la lavorazione sta nel momento
  # in cui il sistema guarda, e non chiede niente a nessuno.
  it "closer_staging consegnato porta la lavorazione al controllo della prova, non al via libera" do
    scope = build_delivery_scope(phase: "closer_staging", organization:, project:, ticket:, workflow:)
    # CYRA-621 — il numero lo assegna il server prima che la fase parta: la consegna deve portare
    # QUELLO, e senza la riga viene rifiutata.
    assigned_version(workflow, "closer_staging", version: "v0.30.0-beta.1", sha: nil)
    in_progress = create(:ticket_status, :in_progress, organization:)
    ticket.update!(status: in_progress)
    workflow.update!(triage_started_at: nil, triaged_at: Time.current, planned_at: Time.current,
                     approved_at: Time.current, autopilot_started_at: Time.current,
                     autopilot_completed_at: Time.current, autopilot_approved_at: Time.current,
                     ticket_snapshot_digest: "snapshot")
    closer_payload = {
      runtime: "claude", reviewer_runtime: "codex",
      result: { code: ticket.code, state: "staging-released", tag: "v0.30.0-beta.1", commit: "3f2a91c0d4e6b8079a1c5f3d2e7b4a6c8d0f1e29" },
      review: review_for("closer_staging"), observed: observed_head
    }

    expect(described_class.call(organization:, host: scope[:host], attempt: scope[:attempt],
                                payload: closer_payload)).to be_ok
    expect(workflow.reload).to have_attributes(closer_staging_completed_at: be_present, completed_at: nil,
                                               closer_staging_verified_at: nil, phase: "verifying_staging")
    expect(ticket.reload.status).to eq(in_progress)
  end

  # CYRA-624 — la consegna del closer di produzione NON chiude più il lavoro. Prima il ticket andava a
  # «Fatto» nell'istante in cui la macchina diceva di aver messo l'etichetta: lì non era stato
  # rilasciato niente, e se il rilascio andava male un minuto dopo il ticket restava Fatto lo stesso.
  it "closer_production consegnato chiude la FASE e apre il controllo, senza portare il ticket a done" do
    scope = build_delivery_scope(phase: "closer_production", organization:, project:, ticket:, workflow:)
    # CYRA-621 — il numero lo assegna il server prima che la fase parta: la consegna deve portare
    # QUELLO, e senza la riga viene rifiutata.
    assigned_version(workflow, "closer_production", version: "v0.30.0", sha: "3f2a91c0d4e6b8079a1c5f3d2e7b4a6c8d0f1e29")
    in_progress = create(:ticket_status, :in_progress, organization:)
    done_status = create(:ticket_status, :done, organization:)
    ticket.update!(status: in_progress)
    workflow.update!(triage_started_at: nil, triaged_at: Time.current, planned_at: Time.current,
                     approved_at: Time.current, autopilot_started_at: Time.current,
                     autopilot_completed_at: Time.current, autopilot_approved_at: Time.current,
                     closer_staging_started_at: Time.current, closer_staging_completed_at: Time.current,
                     ticket_snapshot_digest: "snapshot")
    closer_payload = {
      runtime: "claude", reviewer_runtime: "codex",
      result: { code: ticket.code, state: "production-released", tag: "v0.30.0", commit: "3f2a91c0d4e6b8079a1c5f3d2e7b4a6c8d0f1e29", awaiting_human_approval: true },
      review: review_for("closer_production"), observed: observed_head
    }

    # Il progetto dichiara COME si prova che un rilascio è vivo: senza, la lavorazione si fermerebbe
    # subito — ed è un altro caso, con parole sue.
    congela_piano!(workflow, kind: "deploy_smoke", environment_id: 42)

    expect do
      expect(described_class.call(organization:, host: scope[:host], attempt: scope[:attempt],
                                  payload: closer_payload)).to be_ok
    end.not_to change(Ticketing::Event, :count)

    # Il ticket resta dov'era, il lavoro non è concluso, e l'unica cosa scritta è che la FASE è finita.
    expect(ticket.reload.status).to eq(in_progress)
    expect(done_status.reload).to be_present
    expect(workflow.reload).to have_attributes(completed_at: nil, closer_production_completed_at: be_present,
                                               phase: "awaiting_production_proof")
    # E la prova è agganciata, con dentro quello che si andrà a cercare.
    prova = workflow.probes.live.sole
    expect(prova.expected).to include("version" => "v0.30.0", "sha" => "3f2a91c0d4e6b8079a1c5f3d2e7b4a6c8d0f1e29")
  end

  it "respinge un closer senza outcome completed senza avanzare (review_failed)" do
    scope = build_delivery_scope(phase: "closer_staging", organization:, project:, ticket:, workflow:)
    # CYRA-621 — il numero lo assegna il server prima che la fase parta: la consegna deve portare
    # QUELLO, e senza la riga viene rifiutata.
    assigned_version(workflow, "closer_staging", version: "v0.30.0-beta.1", sha: nil)
    in_progress = create(:ticket_status, :in_progress, organization:)
    ticket.update!(status: in_progress)
    workflow.update!(triage_started_at: nil, triaged_at: Time.current, planned_at: Time.current,
                     approved_at: Time.current, autopilot_started_at: Time.current,
                     autopilot_completed_at: Time.current, autopilot_approved_at: Time.current,
                     ticket_snapshot_digest: "snapshot")
    failed_payload = {
      runtime: "claude", reviewer_runtime: "codex",
      result: { code: ticket.code, state: "failed", tag: "v0.30.0-beta.1" },
      review: review_for("closer_staging"), observed: observed_head
    }

    result = described_class.call(organization:, host: scope[:host], attempt: scope[:attempt], payload: failed_payload)

    expect(result.error.code).to eq("R422-ATTEMPT-001")
    expect(scope[:attempt].reload).to be_status_review_failed
    expect(workflow.reload).to have_attributes(closer_staging_completed_at: nil, phase: "closer_staging_queued")
  end

  it "fallisce chiuso per scope host, lease, digest o repository revocati" do
    variants = [
      -> { lease.update!(profile_digest: "0" * 64) },
      -> { lease.update!(run_id: "altro-run") },
      -> { repository.destroy! }
    ]

    variants.each_with_index do |mutation, index|
      current = index.zero? ? attempt : create(:agent_attempt, organization:, workflow:, host:, service_account: host_service_account,
                                                skill_key: "/closeyourit-triage",
                                                external_run_id: "run-42", phase: "triage", runtime: "claude",
                                                idempotency_key: "scope-#{index}")
      mutation.call
      expect(described_class.call(organization:, host:, attempt: current, payload:).error.code).to eq("R409-ATTEMPT-001")
      lease.update!(profile_digest: Agents::PhaseProfile.for("triage").digest, run_id: "run-42")
      create(:github_repository, project:) unless project.reload.github_repository
    end
  end

  it "rifiuta risultati non strutturati, stati e fasi sconosciute" do
    invalid_payloads = [
      payload.merge(result: "testo"),
      payload.merge(result: triage_meta.merge(state: "unknown"))
    ]

    invalid_payloads.each_with_index do |invalid, index|
      current = index.zero? ? attempt : create(:agent_attempt, organization:, workflow:, host:, service_account: host_service_account,
                                                skill_key: "/closeyourit-triage",
                                                external_run_id: "run-42", phase: "triage", runtime: "claude",
                                                idempotency_key: "invalid-#{index}")
      expect(described_class.call(organization:, host:, attempt: current, payload: invalid).error.code).to eq("R422-ATTEMPT-001")
    end

    # Host-first (CYAU-91): Deliver rivalida lo scope con Agents::Hosts::Eligibility(phase: attempt.phase),
    # che fallisce chiuso su una fase sconosciuta (PhaseProfile assente) PRIMA della validazione del
    # risultato: la fase ignota è ora respinta come scope non più valido (R409), non come R422.
    unknown = create(:agent_attempt, organization:, workflow:, host:, service_account: host_service_account,
                                      skill_key: "/closeyourit-triage",
                                      external_run_id: "run-42", phase: "unknown", runtime: "claude",
                                      idempotency_key: "unknown-phase")
    expect(described_class.call(organization:, host:, attempt: unknown, payload:).error.code).to eq("R409-ATTEMPT-001")
  end

  # CYRA-612 — la consegna non guarda più lo status Review: non sposta il ticket, quindi uno stato di
  # revisione non configurato non la riguarda più. Passa senza toccare niente.
  it "l'autopilot si consegna anche dove uno stato di revisione non è configurato" do
    scope = build_delivery_scope(phase: "autopilot", organization:, project:, ticket:, workflow:)
    organization.ticket_statuses.review_gates.update_all(active: false)
    workflow.update!(triage_started_at: nil, triaged_at: Time.current, planned_at: Time.current,
                     approved_at: Time.current, autopilot_started_at: Time.current, ticket_snapshot_digest: "snapshot")
    congela_piano!(workflow)
    autopilot_payload = {
      runtime: "claude", reviewer_runtime: "codex",
      result: { code: ticket.code, state: "delivered", security_findings: [], gate: { passed: true }, review: { verdict: "approved" },
                cycles: 1, delivery: { prUrl: "https://github.com/bussolabs/closeyourit-rails/pull/1", cyiStatus: "in_review", autoMerged: false } },
      review: review_for("autopilot"), observed: observed_head
    }

    expect(described_class.call(organization:, host: scope[:host], attempt: scope[:attempt],
                                payload: autopilot_payload)).to be_ok
    expect(workflow.reload.autopilot_completed_at).to be_present
  end

  it "non applica effetti per una fase non registrata" do
    unknown = create(:agent_attempt, organization:, workflow:, host:, service_account: host_service_account,
                                      skill_key: "/closeyourit-triage",
                                      external_run_id: "run-42", phase: "unknown", runtime: "claude",
                                      idempotency_key: "unknown-effect")
    delivery = described_class.new(organization:, host:, attempt: unknown, payload:)

    expect { delivery.send(:apply_typed_effect!) }.to raise_error(ActiveRecord::RecordNotFound)
  end

  context "consegna host-first senza agente (CYAU-93)" do
    it "registra un chiarimento host-first e lo pubblica a nome del service account dell'host" do
      scope = build_delivery_scope(phase: "triage", organization:, project:, ticket:, workflow:)

      result = described_class.call(organization:, host: scope[:host], attempt: scope[:attempt], payload:)

      expect(result).to be_ok
      expect(scope[:attempt].reload).to be_status_approved
      expect(ticket.comments.sole.author).to eq(scope[:host_sa])
      giro = workflow.clarifications.sole
      expect(giro.question_comment_id).to eq(ticket.comments.sole.id)
      expect(giro.questions.map(&:body)).to eq([ "Quale risultato ti aspetti?" ])
    end

    it "completa un triage host-first lavorabile senza dereferenziare l'agente" do
      scope = build_delivery_scope(phase: "triage", organization:, project:, ticket:, workflow:)
      workable = payload.merge(result: triage_meta.merge(state: "workable"))

      expect(described_class.call(organization:, host: scope[:host], attempt: scope[:attempt],
                                  payload: workable)).to be_ok
      expect(workflow.reload.triaged_at).to be_present
    end

    it "crea un piano host-first immutabile" do
      scope = build_delivery_scope(phase: "planner", organization:, project:, ticket:, workflow:)
      workflow.update!(triage_started_at: nil, triaged_at: Time.current, ticket_snapshot_digest: "snapshot")
      planner_payload = {
        runtime: "claude", reviewer_runtime: "codex",
        result: { code: ticket.code, technical_analysis: "Analisi del piano", state: "submitted-for-approval",
                  scenarios: [ { given: "contesto", when: "azione", then: "esito", expected: "atteso" } ],
                  definition_of_done: [ "Test verdi" ], mixed_parts: nil, notes: [] },
        review: review_for("planner")
      }

      expect do
        expect(described_class.call(organization:, host: scope[:host], attempt: scope[:attempt],
                                    payload: planner_payload)).to be_ok
      end.to change(Agents::Plan, :count).by(1)
      expect(workflow.reload.planned_at).to be_present
    end

    it "consegna l'autopilot host-first senza spostare il ticket" do
      scope = build_delivery_scope(phase: "autopilot", organization:, project:, ticket:, workflow:)
      review_status = organization.ticket_statuses.review_gates.active.ordered.first ||
                      create(:ticket_status, :in_review, organization:)
      workflow.update!(triage_started_at: nil, triaged_at: Time.current, planned_at: Time.current,
                       approved_at: Time.current, autopilot_started_at: Time.current, ticket_snapshot_digest: "snapshot")
      congela_piano!(workflow)
      autopilot_payload = {
        runtime: "claude", reviewer_runtime: "codex",
        result: { code: ticket.code, state: "delivered", security_findings: [], gate: { passed: true }, review: { verdict: "approved" },
                  cycles: 1, delivery: { prUrl: "https://github.com/bussolabs/closeyourit-rails/pull/1", cyiStatus: "in_review", autoMerged: false } },
        review: review_for("autopilot"), observed: observed_head
      }

      expect(described_class.call(organization:, host: scope[:host], attempt: scope[:attempt],
                                  payload: autopilot_payload)).to be_ok
      expect(ticket.reload.status).not_to eq(review_status)
      expect(workflow.reload.autopilot_completed_at).to be_present
    end

    it "consegna closer_staging host-first e sblocca closer_production" do
      scope = build_delivery_scope(phase: "closer_staging", organization:, project:, ticket:, workflow:)
      # CYRA-621 — il numero lo assegna il server prima che la fase parta: la consegna deve portare
      # QUELLO, e senza la riga viene rifiutata.
      assigned_version(workflow, "closer_staging", version: "v0.30.0-beta.1", sha: nil)
      in_progress = create(:ticket_status, :in_progress, organization:)
      ticket.update!(status: in_progress)
      workflow.update!(triage_started_at: nil, triaged_at: Time.current, planned_at: Time.current,
                       approved_at: Time.current, autopilot_started_at: Time.current,
                       autopilot_completed_at: Time.current, autopilot_approved_at: Time.current,
                       ticket_snapshot_digest: "snapshot")
      closer_payload = {
        runtime: "claude", reviewer_runtime: "codex",
        result: { code: ticket.code, state: "staging-released", tag: "v0.30.0-beta.1", commit: "3f2a91c0d4e6b8079a1c5f3d2e7b4a6c8d0f1e29" },
        review: review_for("closer_staging"), observed: observed_head
      }

      expect(described_class.call(organization:, host: scope[:host], attempt: scope[:attempt],
                                  payload: closer_payload)).to be_ok
      expect(workflow.reload.closer_staging_completed_at).to be_present
    end

    # CYRA-624 — la consegna della produzione non muove più il ticket, quindi non c'è più nessun
    # evento di stato da attribuire: quello che resta da provare è che la FASE risulti chiusa e
    # attribuita alla macchina che l'ha eseguita.
    it "chiude closer_production host-first, senza muovere il ticket e senza eventi di stato" do
      scope = build_delivery_scope(phase: "closer_production", organization:, project:, ticket:, workflow:)
      # CYRA-621 — il numero lo assegna il server prima che la fase parta: la consegna deve portare
      # QUELLO, e senza la riga viene rifiutata.
      assigned_version(workflow, "closer_production", version: "v0.30.0", sha: "3f2a91c0d4e6b8079a1c5f3d2e7b4a6c8d0f1e29")
      in_progress = create(:ticket_status, :in_progress, organization:)
      done_status = create(:ticket_status, :done, organization:)
      ticket.update!(status: in_progress)
      workflow.update!(triage_started_at: nil, triaged_at: Time.current, planned_at: Time.current,
                       approved_at: Time.current, autopilot_started_at: Time.current,
                       autopilot_completed_at: Time.current, autopilot_approved_at: Time.current,
                       closer_staging_started_at: Time.current, closer_staging_completed_at: Time.current,
                       ticket_snapshot_digest: "snapshot")
      closer_payload = {
        runtime: "claude", reviewer_runtime: "codex",
        result: { code: ticket.code, state: "production-released", tag: "v0.30.0", commit: "3f2a91c0d4e6b8079a1c5f3d2e7b4a6c8d0f1e29", awaiting_human_approval: true },
        review: review_for("closer_production"), observed: observed_head
      }

      congela_piano!(workflow, kind: "deploy_smoke", environment_id: 42)

      expect do
        expect(described_class.call(organization:, host: scope[:host], attempt: scope[:attempt],
                                    payload: closer_payload)).to be_ok
      end.not_to change(Ticketing::Event, :count)

      expect(ticket.reload.status).to eq(in_progress)
      expect(done_status.reload).to be_present
      expect(workflow.reload).to have_attributes(closer_production_completed_at: be_present, completed_at: nil)
    end
  end

  # CYRA-285: la rilettura incrociata resta obbligatoria su OGNI fase, ma quanto deve essere profonda lo
  # decide il server dalla fase (Agents::PhaseProfile#review_depth). Un host che potesse sceglierla farebbe
  # sparire la garanzia proprio dove serve: un autopilot dichiarato riletto "sul solo result" è un diff che
  # nessuno ha guardato. Il triage produce cinque campi e si rilegge su quelli, non come un cambio di codice.
  context "profondità della rilettura incrociata (decisa dal server, non dall'host)" do
    def deliver_autopilot(review:)
      scope = build_delivery_scope(phase: "autopilot", organization:, project:, ticket:, workflow:)
      create(:ticket_status, :in_review, organization:) unless organization.ticket_statuses.review_gates.active.exists?
      workflow.update!(triage_started_at: nil, triaged_at: Time.current, planned_at: Time.current,
                       approved_at: Time.current, autopilot_started_at: Time.current,
                       ticket_snapshot_digest: "snapshot")
      congela_piano!(workflow)
      autopilot_payload = {
        runtime: "claude", reviewer_runtime: "codex",
        result: { code: ticket.code, state: "delivered", security_findings: [], gate: { passed: true }, review: { verdict: "approved" },
                  cycles: 1, delivery: { prUrl: "https://github.com/bussolabs/closeyourit-rails/pull/1", cyiStatus: "in_review", autoMerged: false } },
        review:, observed: observed_head
      }
      [ scope, described_class.call(organization:, host: scope[:host], attempt: scope[:attempt],
                                    payload: autopilot_payload) ]
    end

    it "accetta il triage riletto sul solo result strutturato" do
      workable = payload.merge(result: triage_meta.merge(state: "workable"),
                               review: { status: "accepted", summary: "I cinque campi tornano col ticket.",
                                         depth: "result" })

      expect(described_class.call(organization:, host:, attempt:, payload: workable)).to be_ok
      expect(workflow.reload.triaged_at).to be_present
    end

    it "rifiuta il triage che si dichiara riletto sul diff, che per quella fase non esiste" do
      workable = payload.merge(result: triage_meta.merge(state: "workable"),
                               review: { status: "accepted", summary: "Conforme", depth: "diff" })

      result = described_class.call(organization:, host:, attempt:, payload: workable)

      expect(result.error.code).to eq("R409-ATTEMPT-003")
      expect(workflow.reload.triaged_at).to be_nil
      expect(attempt.reload).to be_status_review_failed
    end

    it "rifiuta l'autopilot che si dichiara riletto sul solo result, senza applicare effetti" do
      scope, result = deliver_autopilot(
        review: { status: "accepted", summary: "Result conforme", depth: "result" }
      )

      expect(result.error.code).to eq("R409-ATTEMPT-003")
      expect(workflow.reload.autopilot_completed_at).to be_nil
      expect(scope[:attempt].reload).to be_status_review_failed
    end

    it "accetta l'autopilot riletto sul diff, con le impronte di ciò che il reviewer ha letto" do
      _scope, result = deliver_autopilot(review: review_for("autopilot"))

      expect(result).to be_ok
      expect(workflow.reload.autopilot_completed_at).to be_present
    end

    # CYRA-757 — gli stati che NON producono un diff (`already-delivered`: il lavoro sta in una proposta
    # aperta prima; `blocked`: l'agente si è fermato senza toccare niente) si rileggono sul solo result,
    # come già fa l'host (CYAU-187). Pretendere «diff» più le impronte dove un diff non esiste bocciava
    # una consegna onesta con «revisione non approvata» — e il ticket si fermava dopo due giri.
    context "quando il risultato non ha un diff da rileggere" do
      def deliver_autopilot_state(state, review:, **result_overrides)
        scope = build_delivery_scope(phase: "autopilot", organization:, project:, ticket:, workflow:)
        create(:ticket_status, :in_review, organization:) unless organization.ticket_statuses.review_gates.active.exists?
        workflow.update!(triage_started_at: nil, triaged_at: Time.current, planned_at: Time.current,
                         approved_at: Time.current, autopilot_started_at: Time.current,
                         ticket_snapshot_digest: "snapshot")
        congela_piano!(workflow)
        payload = {
          runtime: "claude", reviewer_runtime: "codex",
          result: { code: ticket.code, state:, security_findings: [], gate: { passed: nil }, cycles: 0 }.merge(result_overrides),
          review:, observed: observed_head
        }
        [ scope, described_class.call(organization:, host: scope[:host], attempt: scope[:attempt], payload:) ]
      end

      it "accetta il lavoro già consegnato riletto sul solo result, senza impronte" do
        scope, result = deliver_autopilot_state(
          "already-delivered",
          review: { status: "accepted", summary: "La proposta precedente è coerente", depth: "result" },
          delivery: { prUrl: "https://github.com/bussolabs/closeyourit-rails/pull/110", cyiStatus: "in_review", autoMerged: false },
          reason: "Commit già in cima al branch e proposta aperta"
        )

        expect(result).to be_ok
        expect(workflow.reload.autopilot_completed_at).to be_present
        expect(scope[:attempt].reload).to be_status_approved
        expect(scope[:attempt].review["depth"]).to eq("result")
      end

      it "accetta ancora il lavoro già consegnato riletto sul diff, con le impronte" do
        _scope, result = deliver_autopilot_state(
          "already-delivered", review: review_for("autopilot"),
          delivery: { prUrl: "https://github.com/bussolabs/closeyourit-rails/pull/110", cyiStatus: "in_review", autoMerged: false },
          reason: "Commit già in cima al branch e proposta aperta"
        )

        expect(result).to be_ok
      end

      it "accetta il blocco riletto sul solo result, senza impronte" do
        _scope, result = deliver_autopilot_state(
          "blocked", review: { status: "accepted", summary: "Il blocco è motivato", depth: "result" },
          reason: "La CI fallisce su una prova preesistente non correlata"
        )

        expect(result).to be_ok
        expect(workflow.reload).to have_attributes(blocked_phase: "autopilot", autopilot_completed_at: nil)
      end

      it "boccia un result che non è un oggetto senza esplodere" do
        scope = build_delivery_scope(phase: "autopilot", organization:, project:, ticket:, workflow:)
        payload = { runtime: "claude", reviewer_runtime: "codex", result: "already-delivered",
                    review: { status: "accepted", summary: "Conforme", depth: "result" }, observed: observed_head }

        result = described_class.call(organization:, host: scope[:host], attempt: scope[:attempt], payload:)

        expect(result).not_to be_ok
        expect(result.error.code).to eq("R409-ATTEMPT-003")
      end

      it "rifiuta il lavoro già consegnato che si dichiara riletto sul diff senza impronte" do
        scope, result = deliver_autopilot_state(
          "already-delivered", review: { status: "accepted", summary: "Conforme", depth: "diff" },
          delivery: { prUrl: "https://github.com/bussolabs/closeyourit-rails/pull/110", cyiStatus: "in_review", autoMerged: false },
          reason: "Commit già in cima al branch"
        )

        expect(result.error.code).to eq("R409-ATTEMPT-003")
        expect(scope[:attempt].reload).to be_status_review_failed
      end
    end

    # CYAU-176 — «riletto sul diff» senza le impronte è una parola che l'host può scrivere a costo zero.
    # Le impronte sono ciò che rende la dichiarazione verificabile: senza, il campo `depth` tornerebbe
    # esattamente l'etichetta senza valore che questo ticket toglie di mezzo.
    it "rifiuta l'autopilot che si dichiara riletto sul diff senza dire cosa ha letto" do
      _scope, result = deliver_autopilot(
        review: { status: "accepted", summary: "Diff conforme", depth: "diff" }
      )

      expect(result.error.code).to eq("R409-ATTEMPT-003")
      expect(workflow.reload.autopilot_completed_at).to be_nil
    end

    # Un'impronta troncata o abbreviata non identifica niente. Le tre lunghezze non sono uguali — due
    # oggetti Git (40) e l'impronta del diff (64) — e accettarne una qualunque le renderebbe decorative.
    it "rifiuta un'impronta che non ha la forma di ciò che dice di essere" do
      storte = [
        { reviewed_base_commit: "a" * 39 },
        { reviewed_base_commit: "A" * 40 },
        { reviewed_snapshot_tree: "z" * 40 },
        { reviewed_diff_sha256: "c" * 40 },
        { reviewed_diff_sha256: "" }
      ]

      storte.each do |storta|
        _scope, result = deliver_autopilot(review: review_for("autopilot", **storta))
        expect(result.error&.code).to eq("R409-ATTEMPT-003"), "accettata un'impronta storta: #{storta.inspect}"
      end
    end

    # CYAU-176 — le due fasi che rilasciano non producono un diff da rileggere: uniscono e marchiano, e a
    # rilascio riuscito le modifiche sono già dentro il ramo principale. Pretendere il diff da loro faceva
    # risultare fallita una lavorazione riuscita — cioè il rilascio in produzione non partiva. Ora una
    # dichiarazione "diff" da un closer è un rapporto che non torna, e viene rifiutata.
    it "rifiuta il closer che si dichiara riletto sul diff, che per quella fase non esiste" do
      scope = build_delivery_scope(phase: "closer_staging", organization:, project:, ticket:, workflow:)
      # CYRA-621 — il numero lo assegna il server prima che la fase parta: la consegna deve portare
      # QUELLO, e senza la riga viene rifiutata.
      assigned_version(workflow, "closer_staging", version: "v0.30.0-beta.1", sha: nil)
      ticket.update!(status: create(:ticket_status, :in_progress, organization:))
      workflow.update!(triage_started_at: nil, triaged_at: Time.current, planned_at: Time.current,
                       approved_at: Time.current, autopilot_started_at: Time.current,
                       autopilot_completed_at: Time.current, autopilot_approved_at: Time.current,
                       ticket_snapshot_digest: "snapshot")
      closer_payload = {
        runtime: "claude", reviewer_runtime: "codex",
        result: { code: ticket.code, state: "staging-released", tag: "v0.30.0-beta.1",
                  commit: "3f2a91c0d4e6b8079a1c5f3d2e7b4a6c8d0f1e29" },
        observed: observed_head, review: review_for("autopilot", summary: "Diff conforme")
      }

      result = described_class.call(organization:, host: scope[:host], attempt: scope[:attempt],
                                    payload: closer_payload)

      expect(result.error.code).to eq("R409-ATTEMPT-003")
      expect(workflow.reload.closer_staging_completed_at).to be_nil
      expect(scope[:attempt].reload).to be_status_review_failed
    end

    # Una consegna rifiutata conserva la dichiarazione dell'host tale e quale: è la prova di cosa ha detto,
    # e riscriverla col valore dovuto cancellerebbe proprio il motivo del rifiuto.
    it "conserva sul tentativo bocciato la profondità che l'host aveva dichiarato" do
      workable = payload.merge(result: triage_meta.merge(state: "workable"),
                               review: { status: "accepted", summary: "Conforme", depth: "diff" })

      described_class.call(organization:, host:, attempt:, payload: workable)

      expect(attempt.reload.review).to include("depth" => "diff")
    end

    # CYAU-176 — un rapporto che non dice COME è stato riletto non passa più. Fino a ieri passava, e
    # passava in silenzio: chi non lo dichiarava era indistinguibile da chi aveva riletto davvero, e il
    # campo era di fatto facoltativo — cioè inutile come garanzia.
    it "rifiuta la consegna che non dice come è stata riletta" do
      workable = payload.merge(result: triage_meta.merge(state: "workable"))
      workable[:review] = workable[:review].except(:depth)

      result = described_class.call(organization:, host:, attempt:, payload: workable)

      expect(result.error.code).to eq("R409-ATTEMPT-003")
      expect(workflow.reload.triaged_at).to be_nil
      expect(attempt.reload).to be_status_review_failed
    end

    # Il valore registrato resta comunque quello del SERVER: il payload deve dire la stessa cosa, non la
    # fissa. Così l'audit di ogni consegna accettata dice quale rilettura era dovuta.
    it "registra la profondità dovuta dal server, non quella scritta dall'host" do
      workable = payload.merge(result: triage_meta.merge(state: "workable"))

      expect(described_class.call(organization:, host:, attempt:, payload: workable)).to be_ok
      expect(attempt.reload.review).to include("status" => "accepted", "depth" => "result")
    end

    # La profondità cambia COSA si chiede alla rilettura, non SE serve: sulle fasi leggere restano
    # obbligatori il reviewer opposto e l'esito accettato con la sua sintesi.
    it "non sostituisce la rilettura: sul triage restano obbligatori reviewer opposto ed esito accettato" do
      variants = [
        payload.merge(result: triage_meta.merge(state: "workable"), reviewer_runtime: "claude",
                      review: { status: "accepted", summary: "Conforme", depth: "result" }),
        payload.merge(result: triage_meta.merge(state: "workable"),
                      review: { status: "unavailable", summary: "Nessun reviewer", depth: "result" }),
        payload.merge(result: triage_meta.merge(state: "workable"),
                      review: { status: "accepted", summary: "", depth: "result" })
      ]

      variants.each_with_index do |variant, index|
        current = create(:agent_attempt, organization:, workflow:, host:, service_account: host_service_account,
                                         skill_key: "/closeyourit-triage", external_run_id: "run-42",
                                         phase: "triage", runtime: "claude", idempotency_key: "depth-#{index}")
        result = described_class.call(organization:, host:, attempt: current, payload: variant)
        expect(result.error.code).to eq("R409-ATTEMPT-003")
      end
      expect(workflow.reload.triaged_at).to be_nil
    end
  end
  # ── CYAU-178 ──────────────────────────────────────────────────────────────────────────────────
  #
  # La consegna allegava un indirizzo di proposta e il sistema si fidava dell'indirizzo. Un indirizzo
  # che punta al lavoro di un altro ticket, a una versione vecchia, o a un lavoro il cui ultimo invio
  # non è mai partito, da fuori sono identici: tutti e tre passavano, e chi approva guardava una pagina
  # verde che mostrava un lavoro a metà.
  describe "l'impronta del codice che l'host aveva in mano" do
    def consegna_autopilot(payload_extra)
      scope = build_delivery_scope(phase: "autopilot", organization:, project:, ticket:, workflow:)
      create(:ticket_status, :in_review, organization:) unless organization.ticket_statuses.review_gates.active.exists?
      workflow.update!(triage_started_at: nil, triaged_at: Time.current, planned_at: Time.current,
                       approved_at: Time.current, autopilot_started_at: Time.current,
                       ticket_snapshot_digest: "snapshot")
      congela_piano!(workflow)
      payload = {
        runtime: "claude", reviewer_runtime: "codex",
        result: { code: ticket.code, state: "delivered", security_findings: [], gate: { passed: true }, review: { verdict: "approved" },
                  cycles: 1, delivery: { prUrl: "https://github.com/bussolabs/closeyourit-rails/pull/1",
                                         cyiStatus: "in_review", autoMerged: false } },
        review: review_for("autopilot")
      }.merge(payload_extra)
      [ scope, described_class.call(organization:, host: scope[:host], attempt: scope[:attempt], payload:) ]
    end

    it "la registra sul tentativo quando la consegna passa" do
      scope, result = consegna_autopilot(observed: observed_head)

      expect(result).to be_ok
      expect(scope[:attempt].reload.observed_head_sha).to eq(AgentReviewAttestation::OBSERVED_HEAD_SHA)
    end

    it "rifiuta la fase che scrive codice senza dire quale codice aveva in mano" do
      scope, result = consegna_autopilot({})

      expect(result.error.code).to eq("R409-ATTEMPT-004")
      expect(workflow.reload.autopilot_completed_at).to be_nil
      expect(scope[:attempt].reload).to be_status_review_failed
    end

    # Un'impronta abbreviata o con lettere maiuscole non identifica niente e passerebbe come se lo
    # facesse: è la stessa ragione per cui non si accetta un commit abbreviato altrove.
    it "rifiuta un'impronta che non ha la forma di un'impronta" do
      [ "7c9e6679", "7C9E6679742501B7D0E8B1F4A3C2D5E6F708192A", "", "z" * 40 ].each do |storta|
        _scope, result = consegna_autopilot(observed: { head_sha: storta })
        expect(result.error&.code).to eq("R409-ATTEMPT-004"), "accettata un'impronta storta: #{storta.inspect}"
      end
    end

    # Le fasi che non scrivono codice non hanno un'impronta da portare: pretenderla sarebbe una domanda
    # senza risposta possibile, e fermerebbe lavorazioni sane.
    it "non la pretende dalle fasi che non scrivono codice" do
      workable = payload.merge(result: triage_meta.merge(state: "workable"))

      expect(described_class.call(organization:, host:, attempt:, payload: workable)).to be_ok
      expect(attempt.reload.observed_head_sha).to be_nil
    end
  end
  # ── CYRA-612 ──────────────────────────────────────────────────────────────────────────────────
  #
  # Il lavoro entrava nella pila delle decisioni nell'istante in cui la macchina diceva «ho finito» — e
  # lo dicevano in due, senza che nessuno dei due avesse guardato niente. Ora la consegna fa una cosa
  # sola: prende nota di dove sta la proposta, e lo scrive in un registro che resta.
  describe "la consegna registra la proposta" do
    def consegna_pr(url, ammesso: "bussolabs/closeyourit-rails")
      scope = build_delivery_scope(phase: "autopilot", organization:, project:, ticket:, workflow:)
      workflow.update!(triage_started_at: nil, triaged_at: Time.current, planned_at: Time.current,
                       approved_at: Time.current, autopilot_started_at: Time.current,
                       ticket_snapshot_digest: "snapshot")
      congela_piano!(workflow, repo: ammesso) if ammesso
      payload = {
        runtime: "claude", reviewer_runtime: "codex",
        result: { code: ticket.code, state: "delivered", security_findings: [], gate: { passed: true },
                  review: { verdict: "approved" }, cycles: 1,
                  delivery: { prUrl: url, cyiStatus: "in_review", autoMerged: false } },
        review: review_for("autopilot"), observed: observed_head
      }
      [ scope, described_class.call(organization:, host: scope[:host], attempt: scope[:attempt], payload:) ]
    end

    it "scrive una riga da controllare, senza aver ancora guardato niente" do
      scope, result = consegna_pr("https://github.com/bussolabs/closeyourit-rails/pull/42")

      expect(result).to be_ok
      candidato = Agents::DeliveryCandidate.sole
      expect(candidato).to have_attributes(
        workflow: workflow, attempt: scope[:attempt], number: 42,
        repository_full_name: "bussolabs/closeyourit-rails", head_sha: nil, base_ref: nil,
        verified_at: nil, next_check_at: be_present
      )
      expect(candidato).to be_state_pending
    end

    # Una seconda consegna della stessa proposta non fa una seconda riga: sarebbe un doppione che
    # verrebbe controllato due volte e mostrerebbe due esiti per la stessa cosa.
    # CYRA-614 — la verifica parte subito dopo il commit, non dentro la transazione: dentro terrebbe
    # righe bloccate per la durata di una chiamata a GitHub.
    it "accoda subito la verifica di quella riga" do
      expect { consegna_pr("https://github.com/bussolabs/closeyourit-rails/pull/42") }
        .to have_enqueued_job(Agents::CandidateVerificationJob)
        .with(Agents::DeliveryCandidate.last&.id || anything)
    end

    it "una consegna ripetuta non raddoppia la riga" do
      consegna_pr("https://github.com/bussolabs/closeyourit-rails/pull/42")

      expect { consegna_pr("https://github.com/bussolabs/closeyourit-rails/pull/42") }
        .not_to change(Agents::DeliveryCandidate, :count)
    end

    # Approvando il piano vengono fissati i progetti su cui quel lavoro può uscire: una proposta
    # altrove è respinta, e ne resta traccia.
    it "una proposta fuori dai progetti fissati viene respinta" do
      scope, result = consegna_pr("https://github.com/bussolabs/un-altro-progetto/pull/1")

      expect(result.error.code).to eq("R422-ATTEMPT-001")
      expect(Agents::DeliveryCandidate.count).to eq(0)
      expect(scope[:attempt].reload).to be_status_review_failed
      expect(workflow.reload.autopilot_completed_at).to be_nil
    end

    # Le lavorazioni approvate prima che l'elenco esistesse non hanno niente con cui confrontarsi: si
    # chiedono modifiche al piano e lo si approva di nuovo. Accettarle «perché il dato manca»
    # rimetterebbe in piedi il buco che questo lavoro chiude.
    it "senza l'elenco dei progetti fissati la consegna viene respinta" do
      _scope, result = consegna_pr("https://github.com/bussolabs/closeyourit-rails/pull/1", ammesso: nil)

      expect(result.error.code).to eq("R422-ATTEMPT-001")
      expect(Agents::DeliveryCandidate.count).to eq(0)
    end

    # Qui si legge soltanto l'INDIRIZZO: non si apre niente e non si interroga nessuno. Un host che
    # non è github.com non è un altro modo di scrivere lo stesso indirizzo, è un altro posto.
    it "un indirizzo su un altro sito non passa, nemmeno col nome giusto dentro" do
      _scope, result = consegna_pr("https://github.example.com/bussolabs/closeyourit-rails/pull/1")

      expect(result.error.code).to eq("R422-ATTEMPT-001")
    end

    # Il progetto può non essere agganciato a nessun repository conosciuto: il nome osservato resta
    # scritto lo stesso, altrimenti la riga non direbbe nemmeno di cosa parlava.
    it "aggancia il repository quando lo riconosce" do
      # Il progetto ha gia' il suo repository (let! in testa al file): qui conta solo che il nome
      # osservato combaci con quello agganciato.
      repository = project.github_repository
      repository.update!(full_name: "bussolabs/closeyourit-rails")

      consegna_pr("https://github.com/bussolabs/closeyourit-rails/pull/9")

      expect(Agents::DeliveryCandidate.sole.repository).to eq(repository)
    end

    # Finché il controllo non è acceso le consegne si accumulano nel registro e restano lì: non si
    # perde niente e nessuno viene chiamato, perché non c'è niente da decidere.
    it "la lavorazione resta lavoro in corso, e non entra nella pila delle decisioni" do
      consegna_pr("https://github.com/bussolabs/closeyourit-rails/pull/42")

      # CYRA-615 — il momento in cui il sistema guarda ha un nome suo: non chiede niente e non si
      # racconta come lavoro che l'agente sta ancora scrivendo.
      expect(workflow.reload.phase).to eq("verifying_candidate")
      expect(Agents::Workflows::PhaseResolver.phase(workflow.reload, [])).to eq("verifying_candidate")
    end
  end
  # CYRA-621 — il numero pubblicato dev'essere QUELLO assegnato dal server. Prima lo sceglieva la
  # macchina pochi secondi prima di pubblicare, e nessuno controllava quella scelta: se sbagliava a
  # valutare il tipo di cambiamento, il numero raccontava una cosa falsa senza modo di accorgersene.
  describe "il numero pubblicato è quello assegnato" do
    def consegna_staging(tag:, assegnato: "v0.30.0-beta.1")
      scope = build_delivery_scope(phase: "closer_staging", organization:, project:, ticket:, workflow:)
      ticket.update!(status: create(:ticket_status, :in_progress, organization:))
      workflow.update!(triage_started_at: nil, triaged_at: Time.current, planned_at: Time.current,
                       approved_at: Time.current, autopilot_started_at: Time.current,
                       autopilot_completed_at: Time.current, autopilot_approved_at: Time.current,
                       ticket_snapshot_digest: "snapshot")
      assigned_version(workflow, "closer_staging", version: assegnato) if assegnato
      payload = {
        runtime: "claude", reviewer_runtime: "codex",
        result: { code: ticket.code, state: "staging-released", tag:,
                  commit: "3f2a91c0d4e6b8079a1c5f3d2e7b4a6c8d0f1e29" },
        review: review_for("closer_staging"), observed: observed_head
      }
      [ scope, described_class.call(organization:, host: scope[:host], attempt: scope[:attempt], payload:) ]
    end

    it "col numero assegnato passa" do
      _scope, result = consegna_staging(tag: "v0.30.0-beta.1")

      expect(result).to be_ok
      expect(workflow.reload.closer_staging_completed_at).to be_present
    end

    it "con un numero diverso quel rilascio non diventa mai «fatto»" do
      scope, result = consegna_staging(tag: "v9.9.9-beta.1")

      expect(result.error.code).to eq("R409-ATTEMPT-005")
      expect(workflow.reload.closer_staging_completed_at).to be_nil
      expect(scope[:attempt].reload).to be_status_review_failed
    end

    # Senza assegnazione non c'è niente con cui confrontare: accettarla «perché il dato manca»
    # rimetterebbe in piedi proprio il buco che questo lavoro chiude.
    it "senza assegnazione la consegna viene rifiutata" do
      _scope, result = consegna_staging(tag: "v0.30.0-beta.1", assegnato: nil)

      expect(result.error.code).to eq("R409-ATTEMPT-005")
    end

    # Uno stato che non pubblica niente non ha un numero da confrontare: pretenderlo lo boccerebbe
    # per una prova che non poteva portare.
    it "uno stato che non rilascia non ha niente da confrontare" do
      scope = build_delivery_scope(phase: "closer_staging", organization:, project:, ticket:, workflow:)
      workflow.update!(triage_started_at: nil, triaged_at: Time.current, planned_at: Time.current,
                       approved_at: Time.current, autopilot_started_at: Time.current,
                       autopilot_completed_at: Time.current, autopilot_approved_at: Time.current,
                       ticket_snapshot_digest: "snapshot")
      payload = {
        runtime: "claude", reviewer_runtime: "codex",
        result: { code: ticket.code, state: "blocked", tag: "v9.9.9-beta.1", reason: "non ce l'ho fatta" },
        review: review_for("closer_staging"), observed: observed_head
      }

      result = described_class.call(organization:, host: scope[:host], attempt: scope[:attempt], payload:)

      expect(result).to be_ok
    end
  end
end
