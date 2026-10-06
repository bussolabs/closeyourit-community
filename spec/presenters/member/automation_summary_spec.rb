# frozen_string_literal: true

require "rails_helper"

# CYRA-384 — la scheda della lavorazione automatica consegnava un registro di macchina a chi deve
# decidere: decine di tentativi quasi identici e un testo lungo, e mai la riga che dice cosa è
# successo, perché il lavoro si è fermato e cosa serve da chi legge. Qui si prova la sintesi, che è
# proprio quelle tre righe.
#
# Ogni riga nasce da CAMPI STRUTTURATI (fase del workflow, esito dei tentativi, domande aperte), mai
# da euristiche sul testo libero consegnato dalla macchina: è il rischio scritto nel ticket — una
# sintesi ricavata a naso può dire il falso proprio nel punto in cui si decide.
RSpec.describe Member::AutomationSummary do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let(:ticket) { create(:ticket, organization:, project:, with_agent_workflow: true) }
  let(:workflow) { ticket.agent_workflow }
  let(:host) { create(:agent_host, organization:) }

  # Le tre righe sono in italiano per definizione di fatto: la prova gira nella lingua in cui si
  # legge la scheda, non in quella di default della suite.
  around { |example| I18n.with_locale(:it) { example.run } }

  def summary(decides: true, pending_questions: 0, blocking_codes: [], blocking_count: 0)
    described_class.new(workflow: workflow.reload, attempts: workflow.attempts.order(:started_at).to_a,
                        decides:, pending_questions:, cto_name: "Alessio",
                        blocking_codes:, blocking_count:)
  end

  describe "cosa ha fatto" do
    it "nomina l'ultimo passo concluso, con il suo esito" do
      create(:agent_attempt, organization:, workflow:, host:, phase: "planner", status: :approved,
                             started_at: 10.minutes.ago, finished_at: 9.minutes.ago)

      expect(summary.done).to include("Pianificazione")
      expect(summary.done).to include(I18n.t("member.tickets.automation.steps.outcome.approved"))
    end

    it "dice che non ha concluso niente quando nessun tentativo è finito" do
      create(:agent_attempt, organization:, workflow:, host:, phase: "triage", status: :running,
                             started_at: 2.minutes.ago)

      expect(summary.done).to eq(I18n.t("member.tickets.automation.summary.done.none"))
    end

    # Il registro cronologico mette in fondo l'ultimo tentativo, non l'ultimo CONCLUSO: se la macchina
    # sta già rifacendo il passo, «cosa ha fatto» deve restare il passo finito, non quello in corso.
    it "salta i tentativi ancora in corso e resta sull'ultimo concluso" do
      create(:agent_attempt, organization:, workflow:, host:, phase: "triage", status: :approved,
                             started_at: 10.minutes.ago, finished_at: 9.minutes.ago)
      create(:agent_attempt, organization:, workflow:, host:, phase: "planner", status: :running,
                             started_at: 1.minute.ago)

      expect(summary.done).to include("Valutazione")
    end
  end

  describe "perché si è fermata" do
    it "una lavorazione ferma dopo troppe bocciature dice quante volte e su quale passo" do
      workflow.update!(triage_started_at: 3.hours.ago, triaged_at: 2.hours.ago,
                       blocked_at: 1.hour.ago, blocked_phase: "planner", blocked_kind: "attempt_limit")
      2.times do |index|
        create(:agent_attempt, organization:, workflow:, host:, phase: "planner", status: :review_failed,
                               started_at: (60 - index).minutes.ago, finished_at: (59 - index).minutes.ago)
      end

      expect(summary.stopped).to include("Pianificazione")
      expect(summary.stopped).to include("2")
    end

    # CYRA-598 — quando a fermarsi è stata la macchina, la frase del tetto sarebbe falsa due volte:
    # nomina la revisione, che non c'entra, e mostra un conteggio che è ZERO — una consegna che
    # dichiara un blocco è valida e si chiude approved, quindi di bocciature non ne produce nessuna.
    # Sarebbe uscito «La revisione ha respinto autopilot 0 volte di fila».
    it "una lavorazione fermata dalla macchina riporta il suo motivo, non la revisione" do
      workflow.update!(triage_started_at: 3.hours.ago, blocked_at: 1.hour.ago, blocked_phase: "triage",
                       blocked_kind: "agent_blocked",
                       blocked_reason: "Il ticket è finito nella coda del prodotto sbagliato.")

      frase = summary.stopped

      expect(frase).to include("Il ticket è finito nella coda del prodotto sbagliato.")
      expect(frase).not_to include("revisione")
      expect(frase).not_to match(/\b0\b/)
    end

    # Il prefisso tecnico è audit, non una frase da leggere: chi decide vede il motivo, non la sigla.
    it "e non mostra il prefisso tecnico del motivo" do
      workflow.update!(triage_started_at: 3.hours.ago, blocked_at: 1.hour.ago,
                       blocked_phase: "closer_staging", blocked_kind: "agent_blocked",
                       blocked_reason: "unreachable: closer_staging non leggibile 3 volte — Il registro non risponde.")

      frase = summary.stopped

      expect(frase).to include("Il registro non risponde.")
      expect(frase).not_to include("unreachable:")
    end

    # La frase del tetto resta com'è: il confronto è la prova che le due strade sono davvero diverse.
    it "le due frasi non si somigliano" do
      workflow.update!(triage_started_at: 3.hours.ago, blocked_at: 1.hour.ago, blocked_phase: "triage",
                       blocked_kind: "agent_blocked", blocked_reason: "Non è pianificabile qui.")
      dalla_macchina = summary.stopped

      workflow.update!(blocked_kind: "attempt_limit", blocked_reason: "attempt_limit: triage failed 2 times")

      expect(summary.stopped).not_to eq(dalla_macchina)
      # CYRA-618 — la frase del tetto non nomina piu' la revisione: il tetto conta anche i giri morti,
      # e dire «la revisione ha respinto» su due host spenti era falso proprio dove si decide.
      expect(summary.stopped).to include("volte di fila")
      expect(summary.stopped).not_to include("revisione")
    end

    it "un piano da approvare dice che aspetta una persona, non che è rotta" do
      workflow.update!(triage_started_at: 3.hours.ago, triaged_at: 2.hours.ago, planned_at: 1.hour.ago)

      expect(summary.stopped).to eq(I18n.t("member.tickets.automation.summary.stopped.awaiting_approval"))
    end

    # Respinta una volta sola con budget ancora aperto la lavorazione NON è ferma: dirlo fermo
    # spingerebbe a intervenire su qualcosa che si sta già risolvendo da solo.
    it "una lavorazione che sta riprovando da sola non è ferma" do
      workflow.update!(triage_started_at: 3.hours.ago, triaged_at: 2.hours.ago)
      create(:agent_attempt, organization:, workflow:, host:, phase: "planner", status: :review_failed,
                             started_at: 30.minutes.ago, finished_at: 29.minutes.ago)

      expect(summary.stopped).to eq(I18n.t("member.tickets.automation.summary.stopped.retrying"))
    end

    # CYRA-877 — the badge said «Bloccato» and «what you need» said «restart it» while the work was
    # already retrying by itself, and no restart button existed.
    it "a workflow retrying by itself asks for nothing and does not read as blocked" do
      workflow.update!(triage_started_at: 3.hours.ago, triaged_at: 2.hours.ago)
      create(:agent_attempt, organization:, workflow:, host:, phase: "planner", status: :review_failed,
                             started_at: 30.minutes.ago, finished_at: 29.minutes.ago)

      expect(summary.retrying?).to be(true)
      expect(summary.needs).to eq(I18n.t("member.tickets.automation.summary.needs.nothing"))
    end

    it "a workflow stopped for a decision is not retrying" do
      workflow.update!(triage_started_at: 3.hours.ago, triaged_at: 2.hours.ago,
                       blocked_at: 1.hour.ago, blocked_phase: "planner", blocked_kind: "attempt_limit")

      expect(summary.retrying?).to be(false)
    end

    it "una lavorazione annullata porta con sé il motivo dell'annullamento" do
      workflow.update!(cancelled_at: 1.minute.ago, cancellation_reason: "Il ticket è un duplicato.")

      expect(summary.stopped).to include("Il ticket è un duplicato.")
    end
  end

  describe "cosa serve da chi legge" do
    it "chiede di approvare il piano a chi può decidere" do
      workflow.update!(triage_started_at: 3.hours.ago, triaged_at: 2.hours.ago, planned_at: 1.hour.ago)

      expect(summary.needs).to eq(I18n.t("member.tickets.automation.summary.needs.approve_plan"))
    end

    it "a chi non decide dice chi deve decidere, invece di chiedergli qualcosa che non può fare" do
      workflow.update!(triage_started_at: 3.hours.ago, triaged_at: 2.hours.ago, planned_at: 1.hour.ago)

      expect(summary(decides: false).needs).to include("Alessio")
    end

    # Una domanda senza risposta blocca tutto il resto: viene prima di qualunque altra richiesta.
    it "le domande in attesa vengono prima di ogni altra cosa" do
      workflow.update!(triage_started_at: 3.hours.ago, triaged_at: 2.hours.ago, planned_at: 1.hour.ago)

      expect(summary(pending_questions: 2).needs)
        .to eq(I18n.t("member.tickets.automation.summary.needs.answer_questions", count: 2))
    end

    it "dice esplicitamente che non serve niente quando la lavorazione va avanti da sola" do
      workflow.update!(triage_started_at: 10.minutes.ago)

      expect(summary.needs).to eq(I18n.t("member.tickets.automation.summary.needs.nothing"))
    end

    # CYRA-876 — a cancelled workflow read «Annullato» and then «the work carries on by itself».
    it "says the work is over once a person cancelled it" do
      workflow.update!(triage_started_at: 10.minutes.ago, cancelled_at: 1.minute.ago)

      expect(summary.needs).to eq(I18n.t("member.tickets.automation.summary.needs.finished"))
    end
  end

  # Il ticket chiedeva una CTA che cambiasse con lo stato. La risposta del cliente (2026-08-17) l'ha
  # ristretta ad approva/rifiuta: «un bottone che cambia significato riga per riga si preme per
  # sbaglio». Le altre uscite (riprova, annulla) restano dove sono già.
  describe "la decisione in evidenza" do
    it "offre la decisione sul piano solo a chi può prenderla" do
      workflow.update!(triage_started_at: 3.hours.ago, triaged_at: 2.hours.ago, planned_at: 1.hour.ago)

      expect(summary.decision).to eq(:plan)
      expect(summary(decides: false).decision).to be_nil
    end

    it "non offre nessuna decisione dove non c'è niente da decidere" do
      workflow.update!(triage_started_at: 10.minutes.ago)

      expect(summary.decision).to be_nil
    end

    # Con una domanda aperta la lavorazione aspetta una risposta scritta, non un verdetto: offrire
    # «Approva» lì sopra farebbe approvare un piano su cui l'automazione ha ancora un dubbio.
    it "non offre la decisione finché c'è una domanda senza risposta" do
      workflow.update!(triage_started_at: 3.hours.ago, triaged_at: 2.hours.ago, planned_at: 1.hour.ago)

      expect(summary(pending_questions: 1).decision).to be_nil
    end
  end

  # ── CYRA-623 ────────────────────────────────────────────────────────────────────────────────────
  #
  # Sulla scheda c'era scritto «in coda» oppure «ci sta lavorando». Non era vero: da quella coda quel
  # ticket non usciva finché il prerequisito non era a posto, e chi guardava stava aspettando una cosa
  # che non sarebbe successa.
  # CYRA-682 — la coda non propone una fase che scrive senza il vincolo congelato all'approvazione,
  # perché la macchina si rifiuterebbe di partire e il ticket si brucerebbe. Ma senza una riga che lo
  # dica il ticket sparirebbe dalla coda in silenzio, e la scheda continuerebbe a raccontarlo come
  # «aspetta una macchina libera» — che è falso: non partirà mai finché manca la configurazione.
  describe "ferma perché il progetto non dichiara la prova di rilascio" do
    def piano_approvato(congelato:)
      workflow.update!(triage_requested_at: 3.hours.ago, triage_started_at: 3.hours.ago, triaged_at: 2.hours.ago)
      attempt = create(:agent_attempt, workflow:, organization:, host:, phase: "planner")
      plan = Agents::Plan.create!(
        workflow:, attempt:, technical_analysis: "Piano", scenarios: [], definition_of_done: [ "RSpec" ],
        notes: [], ticket_snapshot_digest: "snapshot",
        **(congelato ? { candidate_items: [ { "repo" => "bussolabs/x", "base" => "main" } ],
                         completion_probe: { "kind" => "merge", "repo" => "bussolabs/x" } } : {})
      )
      workflow.update!(planned_at: 1.hour.ago, approved_at: 30.minutes.ago,
                       frozen_plan: plan, plan_frozen_at: 30.minutes.ago)
    end

    it "lo dice, invece di far credere che stia aspettando il suo turno" do
      piano_approvato(congelato: false)

      riga = summary.stopped

      expect(riga).to include("non dichiara come si capisce che un suo rilascio è riuscito")
      expect(riga).not_to include("aspetta una macchina libera")
    end

    # Col vincolo la lavorazione è davvero in coda, e la riga torna quella di sempre: la frase nuova
    # deve comparire SOLO dove descrive la realtà.
    it "col vincolo torna la riga normale della coda" do
      piano_approvato(congelato: true)

      expect(summary.stopped).not_to include("non dichiara come si capisce")
    end

    # Le fasi che leggono non hanno un vincolo da rispettare: la frase lì sarebbe una bugia.
    it "non compare sulle fasi che leggono soltanto" do
      workflow.update!(triage_requested_at: Time.current)

      expect(summary.stopped).not_to include("non dichiara come si capisce")
    end
  end

  describe "trattenuta da un prerequisito" do
    before { workflow.update!(triage_requested_at: Time.current) }

    it "al posto di «aspetta una macchina libera» dice che è trattenuta, e nomina il codice" do
      riga = summary(blocking_codes: %w[CYRA-1], blocking_count: 1).stopped

      expect(riga).to include("CYRA-1")
      expect(riga).not_to include("aspetta una macchina libera")
      expect(riga).not_to include("ci sta lavorando")
    end

    # I codici arrivano già ordinati dal cancello: due elenchi composti in due punti diversi si
    # metterebbero d'accordo per caso finché uno dei due non cambia un `order`.
    it "con più prerequisiti li nomina tutti, nell'ordine ricevuto, e l'ordine non cambia" do
      riga = summary(blocking_codes: %w[CYRA-1 CYRA-7 CYRA-9], blocking_count: 3).stopped

      expect(riga.index("CYRA-1")).to be < riga.index("CYRA-7")
      expect(riga.index("CYRA-7")).to be < riga.index("CYRA-9")
      expect(summary(blocking_codes: %w[CYRA-1 CYRA-7 CYRA-9], blocking_count: 3).stopped).to eq(riga)
    end

    # Un prerequisito su un progetto che chi guarda non può vedere resta un fatto, non un codice:
    # nominarlo sarebbe una fuga di informazione travestita da messaggio d'aiuto.
    it "se il prerequisito non è visibile dice che c'è, e il codice non compare da nessuna parte" do
      riga = summary(blocking_codes: [], blocking_count: 1).stopped

      expect(riga).to include("prerequisito")
      expect(riga).not_to match(/[A-Z]{2,4}-\d+/)
    end

    it "soddisfatto il prerequisito la riga torna quella di prima" do
      expect(summary(blocking_codes: [], blocking_count: 0).stopped).to eq(summary.stopped)
      expect(summary.stopped).to include("Aspetta una macchina libera")
    end

    # Le due frasi esistono in tutte e due le lingue, sono diverse fra loro, e nessuna delle due è un
    # segnaposto di traduzione mancante.
    it "le frasi ci sono in italiano e in inglese, diverse fra loro e senza segnaposti" do
      %i[it en].each do |lingua|
        I18n.with_locale(lingua) do
          col_codice = summary(blocking_codes: %w[CYRA-1], blocking_count: 1).stopped
          senza = summary(blocking_codes: [], blocking_count: 1).stopped

          expect(col_codice).not_to include("translation missing")
          expect(senza).not_to include("translation missing")
          expect(col_codice).not_to eq(senza)
        end
      end
    end
  end

  # The «why it stopped» row is titled «A che punto è» unless the work is really halted, and the
  # «what you need» row is highlighted only when a person has to act.
  describe "row title and highlight" do
    it "titles the row «A che punto è» and drops «Non è ferma» while it runs" do
      allow(workflow).to receive(:phase).and_return("verifying_candidate")

      expect(summary.halted?).to be(false)
      expect(summary.stopped).not_to start_with("Non è ferma")
    end

    it "keeps «Perché si è fermata» when the work is blocked" do
      workflow.update_columns(blocked_at: Time.current, blocked_phase: "autopilot", blocked_kind: "attempt_limit")
      allow(workflow).to receive(:phase).and_return("review_blocked")

      expect(summary.halted?).to be(true)
    end

    it "says it waits for an answer, not for a free machine, while a question is open" do
      allow(workflow).to receive(:phase).and_return("triage_queued")

      expect(summary(pending_questions: 1).stopped)
        .to eq(I18n.t("member.tickets.automation.summary.stopped.waiting_answer", count: 1))
    end

    it "asks a person to act when a question is open or a decision is theirs" do
      allow(workflow).to receive(:phase).and_return("triage_queued")
      expect(summary(pending_questions: 1).needs_person?).to be(true)

      allow(workflow).to receive(:phase).and_return("awaiting_approval")
      expect(summary.needs_person?).to be(true)
      expect(summary(decides: false).needs_person?).to be(false)
    end

    it "counts an open question as halted: the work waits for a person" do
      allow(workflow).to receive(:phase).and_return("triage_queued")

      expect(summary(pending_questions: 1).halted?).to be(true)
    end

    it "asks nothing while the work carries on by itself" do
      allow(workflow).to receive(:phase).and_return("verifying_candidate")

      expect(summary.needs_person?).to be(false)
    end
  end
end
