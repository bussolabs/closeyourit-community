# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ticketing::EvaluateAgentEligibilityJob do
  let(:ticket) { create(:ticket, description: "Il bottone di logout non risponde") }

  def stub_evaluation(eligibility: "allowed", reason: "Bugfix circoscritto.", risks: [ "none" ])
    verdict = Ticketing::EvaluateAgentEligibility::Verdict.new(eligibility:, reason:, risks:)
    allow(Ticketing::EvaluateAgentEligibility).to receive(:call).and_return(Result.ok(verdict))
  end

  it "scrive il parere e il checksum del contenuto valutato" do
    stub_evaluation(eligibility: "blocked", reason: "Chiede di svuotare la produzione.",
                    risks: %w[destructive_production])

    described_class.perform_now(ticket_id: ticket.id)

    expect(ticket.reload).to have_attributes(agent_eligibility_advice: "blocked",
                                             agent_eligibility_advice_reason: "Chiede di svuotare la produzione.")
    expect(ticket.agent_eligibility_checksum).to eq(Ticketing::AgentEligibilityText.checksum(ticket:))
  end

  # CYRA-770: il giro automatico informa, non decide. Il ticket resta fuori dalla coda finché una
  # persona non lo consente, e questo vale anche quando il parere è favorevole.
  it "lascia la decisione in attesa anche con un parere favorevole" do
    stub_evaluation(eligibility: "allowed")

    described_class.perform_now(ticket_id: ticket.id)

    expect(ticket.reload).to have_attributes(agent_eligibility: "pending", agent_eligibility_reason: nil)
  end

  it "è coda :ai" do
    expect(described_class.new.queue_name).to eq("ai")
  end

  describe "guardie che evitano chiamate LLM inutili" do
    it "non chiama il modello se il checksum è invariato" do
      ticket.update!(agent_eligibility_checksum: Ticketing::AgentEligibilityText.checksum(ticket:))
      allow(Ticketing::EvaluateAgentEligibility).to receive(:call)

      described_class.perform_now(ticket_id: ticket.id)

      expect(Ticketing::EvaluateAgentEligibility).not_to have_received(:call)
    end

    # Non è più una guardia di sicurezza (il giro automatico non tocca la decisione): è il rifiuto
    # di pagare una chiamata al modello per un parere che non entrerà in nessuna scelta.
    it "non chiama il modello su un ticket con decisione umana" do
      ticket.update!(agent_eligibility: :allowed, agent_eligibility_source: :human)
      allow(Ticketing::EvaluateAgentEligibility).to receive(:call)

      described_class.perform_now(ticket_id: ticket.id)

      expect(Ticketing::EvaluateAgentEligibility).not_to have_received(:call)
    end

    it "non solleva se il ticket è stato cancellato fra enqueue ed esecuzione" do
      allow(Ticketing::EvaluateAgentEligibility).to receive(:call)

      expect { described_class.perform_now(ticket_id: SecureRandom.uuid) }.not_to raise_error
      expect(Ticketing::EvaluateAgentEligibility).not_to have_received(:call)
    end

    # Una raffica di salvataggi accoda N job: il primo valuta, gli altri escono sulla guardia.
    it "una raffica di job sullo stesso contenuto costa UNA sola chiamata al modello" do
      stub_evaluation

      3.times { described_class.perform_now(ticket_id: ticket.id) }

      expect(Ticketing::EvaluateAgentEligibility).to have_received(:call).once
    end
  end

  describe "fail-closed" do
    before do
      allow(Ticketing::EvaluateAgentEligibility).to receive(:call)
        .and_return(Result.err(AppError.new("giù", code: "R503-LLM-001")))
    end

    # Il retry c'è (a differenza di Ai::RunJob, che lo disattiva) perché qui non sta guardando
    # nessuno: senza, un 503 transitorio lascerebbe il ticket fuori dalla coda per sempre.
    it "ri-accoda il tentativo invece di arrendersi al primo errore" do
      expect { described_class.perform_now(ticket_id: ticket.id) }
        .to have_enqueued_job(described_class)
    end

    it "lascia il ticket da valutare — quindi fuori dalla coda — quando la valutazione fallisce" do
      described_class.perform_now(ticket_id: ticket.id)

      expect(ticket.reload).to be_agent_eligibility_pending
      expect(ticket).not_to be_agent_workable
      expect(ticket.agent_eligibility_checksum).to be_nil
    end

    # Il fallimento definitivo non ha bisogno di scrivere nulla: pending è già fuori dalla coda.
    it "non scrive MAI consentito quando la valutazione fallisce" do
      4.times { described_class.perform_now(ticket_id: ticket.id) }

      expect(ticket.reload).not_to be_agent_workable
    end

    # Contro un 429 riprovare entro pochi secondi brucia i tentativi mentre la finestra del provider
    # è ancora chiusa: al primo backfill reale sono bastati pochi secondi per esaurirli tutti.
    it "riprova a distanza di minuti, non di secondi" do
      allow(Ticketing::EvaluateAgentEligibility).to receive(:call)
        .and_return(Result.err(AppError.new("rate limited", code: "R429-LLM-001")))

      expect { described_class.perform_now(ticket_id: ticket.id) }
        .to have_enqueued_job(described_class).at(a_value >= 50.seconds.from_now)
    end
  end

  describe "local development without AI" do
    before do
      allow(Ticketing::EvaluateAgentEligibility).to receive(:call)
        .and_return(Result.err(AppError.new("AI is not configured", code: "R502-LLM-002")))
    end

    it "leaves the decision and checksum pending without failing or scheduling retries" do
      allow(Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new("development"))

      expect { described_class.perform_now(ticket_id: ticket.id) }.not_to have_enqueued_job(described_class)

      expect(ticket.reload).to have_attributes(agent_eligibility: "pending", agent_eligibility_advice: "unknown",
                                               agent_eligibility_checksum: nil)
      expect(ticket).not_to be_agent_workable
    end

    it "still reports a missing AI configuration outside development" do
      expect { described_class.perform_now(ticket_id: ticket.id) }.to raise_error(AppError)
    end

    it "still reports other permanent errors in development" do
      allow(Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new("development"))
      allow(Ticketing::EvaluateAgentEligibility).to receive(:call)
        .and_return(Result.err(AppError.new("Invalid input", code: "R422-AI-007")))

      expect { described_class.perform_now(ticket_id: ticket.id) }.to raise_error(AppError)
    end
  end
end
