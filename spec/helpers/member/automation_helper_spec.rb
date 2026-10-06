# frozen_string_literal: true

require "rails_helper"

# CYRA-282: un tentativo `failed` non mostrava il motivo — `automation_considerations` usciva subito
# perché il `result` è vuoto (un guasto non consegna un risultato strutturato). Qui si verifica che il
# motivo del fallimento sia reso, con un fallback quando manca.
RSpec.describe Member::AutomationHelper, type: :helper do
  describe "#automation_outcome" do
    it "shows a failed attempt as a technical fault (red, triangle)" do
      attempt = build_stubbed(:agent_attempt, status: :failed)

      outcome = helper.automation_outcome(attempt)

      expect(outcome[:color]).to eq(:red)
      expect(outcome[:icon]).to eq("triangle-alert")
      expect(outcome[:label]).to eq(I18n.t("member.tickets.automation.steps.outcome.failed"))
    end
  end

  describe "#automation_considerations" do
    it "mostra il motivo del fallimento come testo del passo" do
      attempt = build_stubbed(:agent_attempt, status: :failed,
                                              failure_reason: "OOM killer ha terminato la sessione.")

      considerations = helper.automation_considerations(attempt)

      expect(considerations[:text]).to eq("OOM killer ha terminato la sessione.")
    end

    it "usa un fallback leggibile quando il fallimento non porta un motivo" do
      attempt = build_stubbed(:agent_attempt, status: :failed, failure_reason: nil)

      considerations = helper.automation_considerations(attempt)

      expect(considerations[:text]).to eq(I18n.t("member.tickets.automation.steps.failure_no_reason"))
    end

    it "non confonde un tentativo fallito con uno che ha consegnato un risultato" do
      attempt = build_stubbed(:agent_attempt, status: :approved, phase: "planner",
                                              result: { "technical_analysis" => "Analisi" })

      considerations = helper.automation_considerations(attempt)

      expect(considerations[:text]).to eq("Analisi")
    end

    # CYRA-392 — lo `state` del payload agente (contratto agent-result) è in inglese: mostrato come
    # chip stonava accanto agli esiti già tradotti. Ora è localizzato, con fallback humanize.
    it "flags a triage that needs clarification instead of printing the state as a chip" do
      attempt = build_stubbed(:agent_attempt, status: :approved, phase: "triage",
                                              result: { "state" => "needs-clarification" })

      triage = helper.automation_considerations(attempt)[:triage]

      expect(triage[:clarification]).to be(true)
    end

    it "ricade su humanize per uno state fuori vocabolario" do
      attempt = build_stubbed(:agent_attempt, status: :approved, phase: "closer_staging",
                                              result: { "state" => "some-new-state" })

      considerations = helper.automation_considerations(attempt)

      expect(considerations[:chips]).to include("Some new state")
    end

    # Ogni fase riassume cose diverse: quello che il triage chiama «capacità» il planner lo chiama
    # «criteri di accettazione». I rami sotto sono i riepiloghi delle singole fasi.
    it "the triage sums up area, risk, skills and the reasons as a list" do
      attempt = build_stubbed(:agent_attempt, status: :approved, phase: "triage",
                                              result: { "category" => "bug", "risk" => "low", "reasons" => [ "manca il caso limite", "" ],
                                                        "requires_human_approval" => true,
                                                        "capabilities" => [ "rails", "rspec" ] })

      triage = I18n.with_locale(:it) { helper.automation_considerations(attempt)[:triage] }

      expect(triage).to include(area: "bug", risk: "basso", capabilities: %w[rails rspec], human_approval: true,
                                reasons: [ "manca il caso limite" ], clarification: false)
    end

    it "il triage senza capacità non stampa il conteggio vuoto" do
      attempt = build_stubbed(:agent_attempt, status: :approved, phase: "triage", result: { "category" => "bug" })

      expect(helper.automation_considerations(attempt)[:counts]).to eq({})
    end

    it "il planner conta criteri e note solo quando ci sono" do
      with_notes = build_stubbed(:agent_attempt, status: :approved, phase: "planner",
                                                 result: { "technical_analysis" => "si tocca il servizio",
                                                           "definition_of_done" => [ "a", "b" ], "notes" => [ "attenzione" ] })
      without = build_stubbed(:agent_attempt, status: :approved, phase: "planner",
                                              result: { "definition_of_done" => [ "a" ] })

      expect(helper.automation_considerations(with_notes)[:counts].values).to include(2, 1)
      expect(helper.automation_considerations(with_notes)[:counts].keys).to include(I18n.t("member.tickets.automation.steps.notes"))
      expect(helper.automation_considerations(without)[:counts].keys).not_to include(I18n.t("member.tickets.automation.steps.notes"))
    end

    it "l'autopilot dichiara gate superato e cicli di revisione" do
      attempt = build_stubbed(:agent_attempt, status: :approved, phase: "autopilot",
                                              result: { "state" => "delivered", "gate" => { "passed" => true },
                                                        "cycles" => 2, "reason" => "consegnato" })

      considerations = helper.automation_considerations(attempt)

      expect(considerations[:text]).to eq("consegnato")
      expect(considerations[:chips]).to include(I18n.t("member.tickets.automation.steps.gate_passed"))
      expect(considerations[:counts].values).to include(2)
    end

    it "l'autopilot senza gate né cicli non inventa chip" do
      attempt = build_stubbed(:agent_attempt, status: :approved, phase: "autopilot", result: { "state" => "delivered" })

      considerations = helper.automation_considerations(attempt)

      expect(considerations[:chips]).not_to include(I18n.t("member.tickets.automation.steps.gate_passed"))
      expect(considerations[:counts]).to eq({})
    end
  end

  describe "#automation_host_label" do
    it "senza host scrive che non si sa quale macchina, senza link" do
      label = helper.automation_host_label(nil)

      expect(label).to include(I18n.t("member.tickets.automation.steps.unknown_host"))
      expect(label).not_to include("<a")
    end
  end

  # CYRA-410 — «da quando è in attesa» è un dato che sta già in tabella: ogni fase in coda ha il suo
  # timestamp d'ingresso, ed è quello che va letto — non `created_at` del workflow, che su una coda
  # successiva alla prima direbbe un'ora vecchia di giorni.
  describe "#automation_queued_since" do
    # Il confronto è col valore LETTO dal workflow, non con quello assegnato: il cast del tipo
    # colonna tronca alla precisione del database, e PostgreSQL si ferma al microsecondo mentre
    # Ruby porta i nanosecondi. Confrontando col valore pre-cast il test passa su SQLite (in locale)
    # e cade in CI con `expected …004965035, got …004965000` — una differenza che non riguarda
    # affatto ciò che l'helper deve fare.
    it "legge l'ora d'ingresso in coda della fase in attesa" do
      workflow = build_stubbed(:agent_workflow, triage_requested_at: 3.minutes.ago)

      expect(helper.automation_queued_since(workflow)).to eq(workflow.triage_requested_at)
    end

    it "su una coda successiva legge il timestamp di QUELLA fase, non della prima" do
      workflow = build_stubbed(:agent_workflow, triage_requested_at: 2.days.ago, triaged_at: 2.days.ago,
                                                planned_at: 2.days.ago, approved_at: 1.minute.ago)

      expect(workflow.phase).to eq("autopilot_queued")
      expect(helper.automation_queued_since(workflow)).to eq(workflow.approved_at)
      expect(helper.automation_queued_since(workflow)).not_to eq(workflow.triage_requested_at)
    end

    it "non dà niente quando la lavorazione è già partita" do
      workflow = build_stubbed(:agent_workflow, triage_requested_at: 5.minutes.ago,
                                                triage_started_at: 1.minute.ago)

      expect(helper.automation_queued_since(workflow)).to be_nil
    end

    it "non dà niente su una lavorazione mai richiesta" do
      workflow = build_stubbed(:agent_workflow, triage_requested_at: nil)

      expect(helper.automation_queued_since(workflow)).to be_nil
    end
  end

  describe "#automation_phase_label" do
    # CYRA-602 — sedici fasi interne, otto parole. La fase «in coda per la valutazione» e la fase
    # «in valutazione» sono lo stesso momento per chi legge: il dettaglio non sparisce, vive nella
    # frase sotto il nome.
    it "dà a ogni fase la parola del suo passaggio" do
      expect(helper.automation_phase_label("triage_queued"))
        .to eq(I18n.t("member.tickets.automation.stage.to_plan"))
      expect(helper.automation_phase_label("closer_production"))
        .to eq(I18n.t("member.tickets.automation.stage.closing"))
    end

    it "fasi diverse dello stesso momento leggono la stessa parola" do
      %w[triage_queued triaging planning].each do |fase|
        expect(helper.automation_phase_label(fase))
          .to eq(helper.automation_phase_label("inactive"))
      end
    end

    # ROVESCIATO da CYRA-602. Prima questo spec pretendeva il ripiego su `humanize`, che stampava il
    # nome interno del passaggio — una parola inglese scritta come la scrivono i programmatori — su
    # una pagina italiana. E siccome era considerato normale, una fase nuova poteva arrivare sotto
    # gli occhi di chi legge senza che nessuno si accorgesse che non le era stato dato un nome.
    # Ora si rompe qui, dove costa meno.
    it "una fase senza parola si ferma prima di arrivare in pagina" do
      expect { helper.automation_phase_label("qualcosa_di_nuovo") }
        .to raise_error(ArgumentError, /fase senza passaggio/)
    end
  end

  describe "#automation_outcome" do
    it "porta con sé la frase che spiega l'esito" do
      attempt = build_stubbed(:agent_attempt, status: :review_failed)

      expect(helper.automation_outcome(attempt)[:hint])
        .to eq(I18n.t("member.tickets.automation.steps.outcome_hint.rejected"))
    end
  end

  # CYRA-384 — diciannove tentativi interrotti in fila coprivano tutto il resto della scheda: per
  # arrivare al piano bisognava scorrerli uno per uno.
  describe "#automation_step_groups" do
    def attempts_of(*statuses)
      statuses.each_with_index.map do |status, index|
        build_stubbed(:agent_attempt, status:, started_at: (60 - index).minutes.ago,
                                      finished_at: (59 - index).minutes.ago)
      end
    end

    it "raccoglie in un gruppo solo i tentativi consecutivi con lo stesso esito" do
      attempts = attempts_of(:stale, :stale, :stale, :approved)

      gruppi = helper.automation_step_groups(attempts, pinned_ids: [])

      expect(gruppi.size).to eq(2)
      expect(gruppi.first[:attempts].size).to eq(3)
      expect(gruppi.first[:collapsed]).to be(true)
      expect(gruppi.last[:collapsed]).to be(false)
    end

    it "non raccoglie due soli tentativi: nasconderne due è più fastidio che guadagno" do
      gruppi = helper.automation_step_groups(attempts_of(:stale, :stale), pinned_ids: [])

      expect(gruppi.size).to eq(2)
      expect(gruppi).to all(include(collapsed: false))
    end

    it "non mescola esiti diversi nello stesso gruppo" do
      gruppi = helper.automation_step_groups(attempts_of(:stale, :stale, :failed, :stale), pinned_ids: [])

      expect(gruppi.map { |gruppo| gruppo[:attempts].size }).to eq([ 1, 1, 1, 1 ])
    end

    # I passi che spiegano DOVE sta la lavorazione adesso (quello in corso, l'ultimo bocciato) sono
    # quelli che si aprono d'ufficio: chiuderli dentro un gruppo li nasconderebbe proprio quando
    # servono.
    it "lascia fuori dal gruppo i passi che la scheda apre d'ufficio" do
      attempts = attempts_of(:stale, :stale, :stale, :stale)

      gruppi = helper.automation_step_groups(attempts, pinned_ids: [ attempts.last.id ])

      expect(gruppi.size).to eq(2)
      expect(gruppi.first[:attempts].size).to eq(3)
      expect(gruppi.last[:attempts]).to eq([ attempts.last ])
      expect(gruppi.last[:collapsed]).to be(false)
    end

    it "il gruppo dichiara l'arco di tempo che copre" do
      attempts = attempts_of(:stale, :stale, :stale)

      gruppo = helper.automation_step_groups(attempts, pinned_ids: []).first

      expect(gruppo[:from]).to eq(attempts.first.started_at)
      expect(gruppo[:to]).to eq(attempts.last.finished_at)
    end

    # Un tentativo interrotto a metà non ha una fine: l'arco di tempo si chiude su quando è partito,
    # invece di restare nil e stampare un buco al posto dell'ora.
    it "un tentativo senza fine chiude l'arco sul suo avvio" do
      attempts = [
        build_stubbed(:agent_attempt, status: :stale, started_at: 30.minutes.ago, finished_at: 29.minutes.ago),
        build_stubbed(:agent_attempt, status: :stale, started_at: 20.minutes.ago, finished_at: 19.minutes.ago),
        build_stubbed(:agent_attempt, status: :stale, started_at: 10.minutes.ago, finished_at: nil)
      ]

      expect(helper.automation_step_groups(attempts, pinned_ids: []).first[:to]).to eq(attempts.last.started_at)
    end

    # CYRA-876 — an attempt whose delivery was a `blocked` result is `approved` as a record, but the work
    # did not pass: grouped by status, two discarded autopilot runs read «4 attempts approved».
    it "does not group a blocked delivery with approved attempts" do
      attempts = attempts_of(:approved, :approved, :approved, :approved)
      attempts[2..].each { |attempt| attempt.result = { "state" => "blocked" } }

      groups = helper.automation_step_groups(attempts, pinned_ids: [])

      expect(groups.map { |group| group[:attempts].size }).to eq([ 1, 1, 1, 1 ])
      expect(groups.last[:outcome][:label]).to eq(I18n.t("member.tickets.automation.steps.outcome.blocked"))
    end
  end

  describe "#automation_outcome for a blocked delivery" do
    it "reads as blocked, not as approved" do
      attempt = build_stubbed(:agent_attempt, status: :approved, result: { "state" => "blocked" })

      outcome = helper.automation_outcome(attempt)

      expect(outcome[:color]).to eq(:amber)
      expect(outcome[:hint]).to eq(I18n.t("member.tickets.automation.steps.outcome_hint.blocked"))
    end

    it "keeps approved for a real delivery" do
      attempt = build_stubbed(:agent_attempt, status: :approved, result: { "state" => "delivered" })

      expect(helper.automation_outcome(attempt)[:color]).to eq(:green)
    end
  end

  # CYRA-606 — «rilasciato v1.4.0» non dice su cosa. Fra l'approvazione e il rilascio possono passare
  # ore e il codice può cambiare: accanto al numero compare la sigla del codice su cui il tag è stato
  # messo, così chi guarda la scheda può andare a vedere.
  describe "#automation_considerations sui closer" do
    let(:sigla) { "3f2a91c0d4e6b8079a1c5f3d2e7b4a6c8d0f1e29" }

    def considerazioni(result)
      helper.automation_considerations(
        build_stubbed(:agent_attempt, phase: "closer_staging", status: :approved, result:)
      )
    end

    it "mostra la sigla accorciata accanto al numero di versione" do
      chips = considerazioni({ "state" => "staging-released", "tag" => "v1.4.0-beta.1", "commit" => sigla })[:chips]

      expect(chips).to include("v1.4.0-beta.1")
      expect(chips).to include("3f2a91c")
    end

    # Un closer che si è FERMATO non ha taggato niente: la scheda non deve inventare una sigla né
    # esplodere per la sua assenza.
    it "non mostra nessuna sigla quando il rilascio si è fermato" do
      chips = considerazioni({ "state" => "blocked", "tag" => nil, "reason" => "staging rosso" })[:chips]

      expect(chips.join(" ")).not_to match(/[0-9a-f]{7}/)
    end

    # Il payload è dato esterno. «Non esplode» non basta come prova: senza il controllo sul tipo,
    # un numero diventerebbe una targhetta «42» accanto alla versione — una sigla inventata, che è
    # peggio di nessuna sigla su una riga che serve a ritrovare il codice.
    it "una sigla che non è una stringa non diventa una targhetta" do
      chips = considerazioni({ "state" => "staging-released", "tag" => "v1.4.0-beta.1", "commit" => 42 })[:chips]

      expect(chips).to include("v1.4.0-beta.1")
      expect(chips).not_to include("42")
    end
  end
end
