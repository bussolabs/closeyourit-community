# frozen_string_literal: true

require "rails_helper"

# ── CYRA-622 ──────────────────────────────────────────────────────────────────────────────────────
#
# La parola sul ticket è la proiezione della fase della lavorazione. Prima la corrispondenza stava in
# due posti — la verifica del candidato e l'approvazione, ognuna con la sua regola — e i due potevano
# dire cose diverse sulla stessa riga. Qui si prova che il posto è uno solo e che chi lo consuma non
# deve conoscerlo.
RSpec.describe Agents::Workflows::StatusProjection do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let(:open_status) { create(:ticket_status, organization:, position: 0) }
  let!(:in_review) { create(:ticket_status, :in_review, organization:, position: 2) }
  let!(:in_progress) { create(:ticket_status, :in_progress, organization:, position: 1) }
  let(:ticket) { create(:ticket, organization:, project:, status: open_status, with_agent_workflow: true) }
  let(:workflow) { ticket.agent_workflow }

  describe ".category" do
    # È quello che rende il cancello delle dipendenze indipendente dalla configurazione: la categoria
    # si legge dalla FASE, e un'organizzazione senza stati configurati non può spegnerlo.
    it "risponde senza guardare nessuno stato dell'organizzazione" do
      Types::TicketStatus.delete_all

      expect(described_class.category("closer_staging_queued")).to eq(:in_progress)
    end

    it "su una fase che non proietta niente non inventa una categoria" do
      expect(described_class.category("triaging")).to be_nil
    end
  end

  describe ".prerequisiti" do
    # CYRA-623 — arrivare davanti a una persona e andare al rilascio di prova sono due momenti di
    # LAVORAZIONE: la domanda è quella che la coda fa per la fase che li produce. Fossero più severi
    # della coda, un ticket servito non riuscirebbe poi a muoversi — il giro di macchina buttato.
    it "la domanda è quella del cancello per la fase di esecuzione che porta lì" do
      expect(described_class.prerequisites("awaiting_autopilot_approval"))
        .to eq(Ticketing::DependencyGuard.mode_for("autopilot"))
      expect(described_class.prerequisites("closer_staging_queued"))
        .to eq(Ticketing::DependencyGuard.mode_for("closer_staging"))
    end

    # Fail-closed: una fase che nessuno ha mappato non deve poter allentare il cancello.
    it "una fase sconosciuta ricade sulla domanda severa" do
      expect(described_class.prerequisites("triaging")).to eq(:released)
    end
  end

  describe "#call" do
    it "il sistema ha guardato: il ticket va sullo stato di revisione" do
      workflow.update!(autopilot_started_at: 2.minutes.ago, autopilot_completed_at: 1.minute.ago,
                       candidate_verified_at: 1.minute.ago)

      expect(described_class.call(workflow:)).to be_ok
      expect(ticket.reload.status).to eq(in_review)
    end

    it "dopo il sì il ticket va sull'ultimo stato di lavoro, non sul primo" do
      in_chiusura = create(:ticket_status, :in_progress, organization:, position: 5, label: "In chiusura")
      workflow.update!(autopilot_started_at: 2.minutes.ago, autopilot_completed_at: 1.minute.ago,
                       candidate_verified_at: 1.minute.ago, autopilot_approved_at: Time.current)

      described_class.call(workflow:)

      expect(ticket.reload.status).to eq(in_chiusura)
    end

    # Una fase che non ha una parola sua non ne inventa una: il ticket resta dov'è. Il contrario
    # vorrebbe dire che ogni fase nuova sposta il ticket da qualche parte senza che nessuno l'abbia
    # deciso.
    it "una fase senza corrispondenza non tocca il ticket" do
      workflow.update!(triage_started_at: Time.current)

      expect(described_class.call(workflow:)).to be_ok
      expect(ticket.reload.status).to eq(open_status)
    end

    it "senza uno stato di destinazione risponde R422-TICKET-008 e non tocca il ticket" do
      in_review.update!(active: false)
      workflow.update!(autopilot_started_at: 2.minutes.ago, autopilot_completed_at: 1.minute.ago,
                       candidate_verified_at: 1.minute.ago)

      result = described_class.call(workflow:)

      expect(result.error.code).to eq("R422-TICKET-008")
      expect(ticket.reload.status).to eq(open_status)
    end

    # Idempotente: la proiezione la chiamano più fatti osservati, e riscrivere lo stesso stato
    # lascerebbe in timeline una riga «da In Review a In Review» a ogni giro. La regola non è
    # ripetuta qui: è della porta unica dei cambi stato, e questo prova che passa di lì.
    it "se il ticket è già sulla parola giusta non scrive niente" do
      workflow.update!(autopilot_started_at: 2.minutes.ago, autopilot_completed_at: 1.minute.ago,
                       candidate_verified_at: 1.minute.ago)
      described_class.call(workflow:)
      prima = ticket.reload.events.count

      expect(described_class.call(workflow:)).to be_ok
      expect(ticket.reload.events.count).to eq(prima)
    end
  end
end
