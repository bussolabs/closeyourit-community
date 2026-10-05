# frozen_string_literal: true

require "rails_helper"

# CYRA-201: `stale` era previsto dall'enum, letto dalle viste e MAI assegnato. Una lavorazione che perdeva
# la finestra restava `running` per sempre e poteva farsi scambiare per un tentativo in corso, bloccando i
# claim successivi sullo stesso ticket. Qui si verifica che venga chiusa — e soprattutto CHE NON venga
# chiusa quando è ancora viva: un falso positivo ucciderebbe lavoro buono.
RSpec.describe Agents::Attempts::MarkStale do
  let(:organization) { create(:organization) }
  let(:host) { create(:agent_host, organization:) }
  let(:now) { Time.current }
  let(:grace) { Agents::Constants::ATTEMPT_STALE_GRACE }

  # Una lavorazione = un attempt + il lease del suo ticket, legati dal run_id.
  def lavorazione(started_ago: grace + 1.hour, lease: :expired, run_id: "run-1", **attempt_overrides)
    workflow = create(:agent_workflow, organization:)
    attempt = create(:agent_attempt, workflow:, organization:, host:,
                                     external_run_id: run_id, started_at: now - started_ago,
                                     **attempt_overrides)
    case lease
    when :expired
      create(:agent_lease, :host_first, host:, organization:, ticket: workflow.ticket,
                                        run_id:, expires_at: now - 1.hour)
    when :active
      create(:agent_lease, :host_first, host:, organization:, ticket: workflow.ticket,
                                        run_id:, expires_at: now + 1.hour)
    when :active_other_run
      create(:agent_lease, :host_first, host:, organization:, ticket: workflow.ticket,
                                        run_id: "run-altra", expires_at: now + 1.hour)
    when :none
      nil
    end
    attempt
  end

  def run = described_class.call(now:)

  # CYRA-504 — una prenotazione che scade sempre sulla stessa fase è una lavorazione da guardare: il
  # recovery la rimetteva in coda all'infinito, perché il tetto stava sulla sola strada della consegna.
  describe "tetto ai tentativi" do
    it "ferma la lavorazione quando le scadenze sulla stessa fase esauriscono il budget" do
      attempt = lavorazione
      (Agents::Constants::PHASE_REVIEW_LIMIT - 1).times do
        create(:agent_attempt, workflow: attempt.workflow, organization:, host:,
                               phase: attempt.phase, status: :stale)
      end

      run

      expect(attempt.workflow.reload).to have_attributes(blocked_at: be_present,
                                                         blocked_phase: attempt.phase)
    end

    it "sotto il budget la lascia riprovare" do
      attempt = lavorazione

      run

      expect(attempt.workflow.reload.blocked_at).to be_nil
    end
  end

  describe "chiude ciò che è morto" do
    it "marca ferma una lavorazione con prenotazione scaduta e nessuna consegna" do
      attempt = lavorazione(lease: :expired)

      expect(run.value).to eq(1)
      expect(attempt.reload).to be_status_stale
      expect(attempt.finished_at).to be_present
    end

    it "marca ferma una lavorazione senza alcuna prenotazione (riga già sparita)" do
      attempt = lavorazione(lease: :none)

      expect(run.value).to eq(1)
      expect(attempt.reload).to be_status_stale
    end

    # Il ticket è unico, le lavorazioni no: un lease fresco di un'ALTRA lavorazione dello stesso ticket non
    # tiene in vita questa. Senza il confronto sul run_id l'orfano resterebbe running per sempre.
    it "marca ferma una lavorazione il cui ticket ha una prenotazione fresca di un'ALTRA lavorazione" do
      attempt = lavorazione(lease: :active_other_run, run_id: "run-mia")

      expect(run.value).to eq(1)
      expect(attempt.reload).to be_status_stale
    end

    it "chiude più orfani in un solo giro" do
      2.times { |i| lavorazione(run_id: "run-#{i}") }

      expect(run.value).to eq(2)
    end
  end

  describe "non tocca ciò che è vivo" do
    it "lascia in corso una lavorazione con la prenotazione ancora valida" do
      attempt = lavorazione(lease: :active)

      expect(run.value).to eq(0)
      expect(attempt.reload).to be_status_running
      expect(attempt.finished_at).to be_nil
    end

    # La grazia esiste perché la consegna può essere in volo proprio mentre la riga risulta scaduta.
    it "lascia in corso una lavorazione appena scaduta, dentro la grazia" do
      attempt = lavorazione(started_ago: grace - 1.minute)

      expect(run.value).to eq(0)
      expect(attempt.reload).to be_status_running
    end

    it "lascia in corso una lavorazione che ha consegnato (delivery_digest presente)" do
      attempt = lavorazione(delivery_digest: "abc123")

      expect(run.value).to eq(0)
      expect(attempt.reload).to be_status_running
    end

    it "non tocca i tentativi già terminali" do
      attempt = lavorazione(status: :approved, finished_at: now - 2.hours)

      expect(run.value).to eq(0)
      expect(attempt.reload).to be_status_approved
    end

    it "non tocca gli `awaiting_review`: la DoD parla di lavorazioni ferme, non di stati in attesa" do
      attempt = lavorazione(status: :awaiting_review)

      expect(run.value).to eq(0)
      expect(attempt.reload).to be_status_awaiting_review
    end
  end

  describe "robustezza" do
    it "è idempotente: un secondo giro non trova più nulla" do
      lavorazione

      expect(run.value).to eq(1)
      expect(run.value).to eq(0)
    end

    # Lo snapshot degli id è preso fuori dalla transazione: se la consegna arriva nel frattempo, la riga
    # viene rivalutata sotto lock e SALTATA. Dichiarare ferma una lavorazione appena conclusa sarebbe
    # peggio del problema di partenza.
    it "salta una lavorazione che consegna tra lo snapshot e il lock" do
      attempt = lavorazione
      allow(Agents::Attempt).to receive(:lock).and_wrap_original do |original, *args|
        attempt.update_columns(status: Agents::Attempt.statuses.fetch("approved"), finished_at: Time.current)
        original.call(*args)
      end

      expect(run.value).to eq(0)
      expect(attempt.reload).to be_status_approved
    end
  end

  # CYRA-212: chiudere l'attempt come stale NON basta a far rientrare il ticket in coda — il claim ha scritto
  # <fase>_started_at sul workflow e READY_EXECUTION_PHASE_SQL smette di proporre la fase finché resta
  # valorizzato. MarkStale deve quindi riaprire la fase avviata e mai conclusa.
  describe "riporta il ticket in coda riaprendo la fase interrotta" do
    it "azzera lo start della fase triage così torna proposta alle macchine" do
      workflow = create(:agent_workflow, organization:, triage_started_at: now - 2.hours)
      attempt = create(:agent_attempt, workflow:, organization:, host:, phase: "triage",
                                       external_run_id: "run-1", started_at: now - (grace + 1.hour))
      create(:agent_lease, :host_first, host:, organization:, ticket: workflow.ticket,
                                        run_id: "run-1", expires_at: now - 1.hour)
      expect(workflow.ready_execution_phase).to be_nil # triaging: fuori dalla coda

      expect(run.value).to eq(1)
      expect(attempt.reload).to be_status_stale
      expect(workflow.reload.triage_started_at).to be_nil
      expect(workflow.ready_execution_phase).to eq("triage") # di nuovo in coda
    end

    it "non altera i timestamp del workflow per una lavorazione planner (rientra alla scadenza del lease)" do
      workflow = create(:agent_workflow, organization:, triage_started_at: now - 3.hours, triaged_at: now - 2.hours)
      attempt = create(:agent_attempt, workflow:, organization:, host:, phase: "planner",
                                       skill_key: "/closeyourit-planner",
                                       external_run_id: "run-2", started_at: now - (grace + 1.hour))
      create(:agent_lease, :host_first, host:, organization:, ticket: workflow.ticket,
                                        run_id: "run-2", expires_at: now - 1.hour)

      expect(run.value).to eq(1)
      expect(attempt.reload).to be_status_stale
      expect(workflow.reload.triage_started_at).to be_present
      expect(workflow.ready_execution_phase).to eq("planner")
    end
  end

  describe "scope orphaned_at" do
    it "non include lavorazioni di un attempt il cui lease coincide per run ed è attivo" do
      lavorazione(lease: :active, run_id: "run-x")

      expect(Agents::Attempt.orphaned_at(now)).to be_empty
    end

    it "accetta una grazia esplicita" do
      lavorazione(started_ago: 10.minutes)

      expect(Agents::Attempt.orphaned_at(now, grace: 1.hour)).to be_empty
      expect(Agents::Attempt.orphaned_at(now, grace: 1.minute).count).to eq(1)
    end
  end
end
