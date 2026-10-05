# frozen_string_literal: true

require "rails_helper"

# CYRA-282: se la sessione muore sulla macchina, `failed` era previsto dall'enum ma nessun percorso lo
# scriveva — un guasto era indistinguibile da una macchina spenta. Qui la macchina riporta l'esito
# fallito col motivo: il tentativo diventa `failed`, il ticket rientra in coda (fase riaperta come per lo
# stale) e nessun altro host può marcare fallito un tentativo che non ha eseguito.
RSpec.describe Agents::Attempts::ReportFailure do
  let(:organization) { create(:organization) }
  let(:host) { create(:agent_host, organization:) }
  let(:workflow) { create(:agent_workflow, organization:, triage_started_at: Time.current) }
  let(:attempt) do
    create(:agent_attempt, workflow:, organization:, host:, phase: "triage", status: :running)
  end

  def run(reason: "Sessione terminata: processo ucciso a metà pianificazione.", target: attempt, on: host)
    described_class.call(host: on, attempt: target, reason:)
  end

  describe "marca il tentativo fallito col motivo" do
    it "scrive status failed, il motivo e l'istante di fine" do
      result = run(reason: "Kernel OOM killer ha terminato la sessione.")

      expect(result).to be_ok
      expect(attempt.reload).to be_status_failed
      expect(attempt.failure_reason).to eq("Kernel OOM killer ha terminato la sessione.")
      expect(attempt.finished_at).to be_present
    end

    # Chiudere l'attempt NON basta: il claim ha scritto triage_started_at e la fase resta fuori coda finché
    # non viene azzerato (stessa logica di MarkStale). Riaprendola, il ticket rientra subito senza aspettare
    # il giro periodico degli orfani.
    it "riapre la fase interrotta così il ticket rientra in coda" do
      expect(workflow.ready_execution_phase).to be_nil # triaging: fuori dalla coda

      run

      expect(workflow.reload.triage_started_at).to be_nil
      expect(workflow.ready_execution_phase).to eq("triage")
    end
  end

  # CYRA-504 — riaprire la fase non basta: un guasto che si ripete la rimetteva in coda all'infinito,
  # perché il tetto ai tentativi viveva sulla sola strada della consegna e un fallimento non ci passa.
  describe "tetto ai tentativi" do
    it "ferma la lavorazione quando i fallimenti sulla stessa fase esauriscono il budget" do
      (Agents::Constants::PHASE_REVIEW_LIMIT - 1).times do
        create(:agent_attempt, workflow:, organization:, host:, phase: "triage", status: :failed)
      end

      run

      expect(workflow.reload).to have_attributes(blocked_at: be_present, blocked_phase: "triage")
    end

    it "sotto il budget la lascia riprovare" do
      run

      expect(workflow.reload.blocked_at).to be_nil
      expect(workflow.ready_execution_phase).to eq("triage")
    end
  end

  describe "protezione dell'esito" do
    it "rifiuta un host che non ha eseguito il tentativo e non produce effetti" do
      other = create(:agent_host, organization:)

      result = run(on: other)

      expect(result).to be_err
      expect(result.error.code).to eq("R409-ATTEMPT-001")
      expect(attempt.reload).to be_status_running
    end

    it "pretende un motivo: senza, nessun fallimento silenzioso" do
      result = run(reason: "   ")

      expect(result).to be_err
      expect(result.error.code).to eq("R422-ATTEMPT-002")
      expect(attempt.reload).to be_status_running
    end

    # Un secondo report dello stesso fallimento è idempotente: la macchina può riprovare la chiamata senza
    # sporcare l'audit né rimuovere il motivo già registrato.
    it "è idempotente su un tentativo già fallito" do
      run(reason: "Primo motivo.")
      result = run(reason: "Secondo motivo, ignorato.")

      expect(result).to be_ok
      expect(attempt.reload).to be_status_failed
      expect(attempt.failure_reason).to eq("Primo motivo.")
    end

    it "non sovrascrive un tentativo già concluso con un altro esito" do
      attempt.update_columns(status: Agents::Attempt.statuses.fetch("approved"), finished_at: Time.current)

      result = run

      expect(result).to be_err
      expect(result.error.code).to eq("R409-ATTEMPT-004")
      expect(attempt.reload).to be_status_approved
    end
  end

  # Il lease vivo su una lavorazione fallita blocca il ticket (fase riaperta ma non reclamabile) e lascia
  # passare una consegna /result tardiva fino a un update! terminale (ReadOnlyRecord → 500). ReportFailure
  # lo ritira, ma solo il proprio.
  describe "rilascio del lease" do
    it "ritira il lease host di questa lavorazione così il ticket torna reclamabile" do
      lease = create(:agent_lease, :host_first, host:, organization:, ticket: workflow.ticket,
                                                run_id: attempt.external_run_id)

      run

      expect(Agents::Lease.exists?(lease.id)).to be(false)
    end

    it "non tocca un lease fresco di un'ALTRA lavorazione dello stesso ticket" do
      other = create(:agent_lease, :host_first, host:, organization:, ticket: workflow.ticket,
                                                run_id: "run-altra", expires_at: 1.hour.from_now)

      run

      expect(Agents::Lease.exists?(other.id)).to be(true)
    end

    it "non tocca un lease umano che nel frattempo ha preso il ticket" do
      human = create(:agent_lease, :held_by_account, ticket: workflow.ticket, organization:)

      run

      expect(Agents::Lease.exists?(human.id)).to be(true)
    end
  end

  describe "robustezza" do
    it "tronca un motivo abnorme al tetto previsto" do
      result = run(reason: "x" * (Agents::Constants::FAILURE_REASON_MAX + 500))

      expect(result).to be_ok
      expect(attempt.reload.failure_reason.length).to eq(Agents::Constants::FAILURE_REASON_MAX)
    end

    it "rivaluta sotto lock: una consegna arrivata nel frattempo vince sul report di fallimento" do
      allow(attempt).to receive(:lock!).and_wrap_original do |original, *args|
        attempt.update_columns(status: Agents::Attempt.statuses.fetch("approved"), finished_at: Time.current)
        original.call(*args)
      end

      result = run

      expect(result).to be_err
      expect(result.error.code).to eq("R409-ATTEMPT-004")
    end
  end
end
