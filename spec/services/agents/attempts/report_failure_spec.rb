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

  # CYRA-1330 — a review that produced no verdict for a technical fault (an exhausted quota, a
  # reviewer process that died) says nothing about the work: it must not spend the phase's attempts.
  describe "a review that was never produced" do
    let(:fault_reason) do
      "review not produced by a technical fault (quota), not a rejection of the work: " \
        "the reviewer's quota resets at 18:00"
    end

    def report(reason:, review_fault: nil)
      described_class.call(host:, attempt:, reason:, review_fault:)
    end

    it "writes the declared fault beside the reason" do
      report(reason: "the reviewer process died", review_fault: "transient")

      expect(attempt.reload.review_fault).to eq("transient")
    end

    # The machines in the field send the reason only, and its shape is stable (the automator composes
    # it in one place): without reading the sign from there the column would stay empty exactly on
    # the machines this cap was written for.
    it "reads the fault from the reason when the field is missing" do
      report(reason: fault_reason)

      expect(attempt.reload.review_fault).to eq("quota")
    end

    it "signs nothing on a plain failure" do
      run

      expect(attempt.reload.review_fault).to be_nil
    end

    # A kind nobody knows is not trusted into the column: the attempt stays a failure like any
    # other, which is the safe answer — it counts, instead of granting a free retry.
    it "ignores a kind nobody knows" do
      report(reason: "something else entirely", review_fault: "whatever")

      expect(attempt.reload.review_fault).to be_nil
    end

    # AC-1 — two faults in a row: nobody is called and the phase goes back to the queue.
    it "leaves the work going after two faults in a row" do
      create(:agent_attempt, workflow:, organization:, host:, phase: "triage", status: :failed,
                             review_fault: "quota", created_at: 10.minutes.ago)

      report(reason: fault_reason)

      expect(workflow.reload.blocked_at).to be_nil
      expect(workflow.ready_execution_phase).to eq("triage")
    end
  end
end
