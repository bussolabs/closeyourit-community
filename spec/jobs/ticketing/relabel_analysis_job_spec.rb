# frozen_string_literal: true

require "rails_helper"

# Il job che riscrive a etichette l'analisi di UN ticket (CYRA-266). Qui vivono le garanzie che il
# service da solo non può dare: che l'originale resti leggibile, che un ticket in mano
# all'automazione non venga toccato, e che un fallimento lasci le cose come stavano.
RSpec.describe Ticketing::RelabelAnalysisJob do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let(:plain) { "Il contatore avvisava troppo tardi. Ho aggiunto una costante col bersaglio." }
  let(:ticket) { create(:ticket, organization:, project:, technical_analysis: plain, with_agent_workflow: true) }
  let(:relabelled) { "**Approccio:** costante col bersaglio.\n\n**Rischi:** nessuno." }

  # CYRA-547 — la riscrittura gira sulla chiave dell'organizzazione del ticket.

  def stub_relabel(value: relabelled, error: nil)
    result = error ? Result.err(error) : Result.ok(value)
    allow(Ticketing::RelabelAnalysis).to receive(:call).and_return(result)
  end

  def run = described_class.new.perform(ticket_id: ticket.id)

  describe "la riscrittura" do
    before { stub_relabel }

    it "scrive il testo nuovo e marca il ticket" do
      run

      expect(ticket.reload.technical_analysis).to eq(relabelled)
      expect(ticket.analysis_relabeled_at).to be_present
    end

    # È la ragione per cui non serve nessuna colonna di backup: il testo di prima resta nella
    # cronologia, nella stessa forma che usa una modifica fatta a mano.
    it "lascia l'originale nella cronologia" do
      expect { run }.to change { ticket.events.where(action: "updated").count }.by(1)

      expect(ticket.events.where(action: "updated").last.data["technical_analysis"]).to eq([ plain, relabelled ])
    end

    it "non attribuisce la modifica a una persona" do
      run

      expect(ticket.events.where(action: "updated").last.actor).to be_nil
    end

    # UpdateTicket riaccoderebbe anche la rivalutazione del gate agenti: su 423 ticket sarebbero 423
    # chiamate in più al provider. È il motivo per cui questo job scrive diretto.
    it "non riaccoda la rivalutazione del gate agenti" do
      expect { run }.not_to have_enqueued_job(Ticketing::EvaluateAgentEligibilityJob)
    end

    it "riaccoda l'embedding, che fuori da UpdateTicket non arriva da solo" do
      expect { run }.to have_enqueued_job(Ticketing::EmbedTicketJob)
    end
  end

  describe "quando non c'è niente da fare" do
    it "marca il ticket senza scrivere se il service dice che è già a posto" do
      stub_relabel(value: nil)

      expect { run }.not_to change { ticket.reload.technical_analysis }
      expect(ticket.reload.analysis_relabeled_at).to be_present
    end

    it "non rifà un ticket già riscritto" do
      ticket.update_column(:analysis_relabeled_at, 1.hour.ago)
      expect(Ticketing::RelabelAnalysis).not_to receive(:call)

      run
    end

    it "non esplode su un ticket cancellato fra accodamento ed esecuzione" do
      id = ticket.id
      ticket.destroy!

      expect { described_class.new.perform(ticket_id: id) }.not_to raise_error
    end
  end

  describe "i confini da non superare" do
    # Il corpo è bloccato mentre un agente lavora il ticket: quel testo è la SPECIFICA che sta
    # seguendo in quel momento. Si salta senza marcare, così il rilancio lo riprende dopo.
    it "salta un ticket con l'automazione in corso, e non lo marca" do
      # La factory :ticket porta già il suo workflow: qui si fa partire il triage, che è ciò che
      # rende il corpo bloccato (Agents::Workflow#body_locked?).
      ticket.agent_workflow.update!(triage_started_at: 1.minute.ago)
      expect(Ticketing::RelabelAnalysis).not_to receive(:call)

      run

      expect(ticket.reload.analysis_relabeled_at).to be_nil
    end

    it "si ferma se il god ha tirato il freno" do
      allow(Ai::Feature).to receive(:disabled?).with(:analysis_relabel).and_return(true)
      expect(Ticketing::RelabelAnalysis).not_to receive(:call)

      run

      expect(ticket.reload.analysis_relabeled_at).to be_nil
    end

    # Nessun ripiego, a nessun tentativo: l'analisi di prima è già leggibile, una riscritta male no.
    it "rilancia l'errore e lascia il campo intatto" do
      stub_relabel(error: AppError.new("boom", code: "R502-RELABEL-001"))

      expect { run }.to raise_error(AppError)
      expect(ticket.reload.technical_analysis).to eq(plain)
      expect(ticket.analysis_relabeled_at).to be_nil
    end
  end
end
