# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ticketing::EvaluateAgentEligibilityJob do
  let(:ticket) { create(:ticket, :team_created, description: "Il bottone di logout non risponde") }

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
  # CYRA-1219 — it still holds with the automatic go-ahead off, how every project is born.
  it "leaves the decision pending on a favourable advice, with the automatic go-ahead off" do
    expect(ticket.project.auto_go_ahead_enabled).to be(false)
    stub_evaluation(eligibility: "allowed")

    described_class.perform_now(ticket_id: ticket.id)

    expect(ticket.reload).to have_attributes(agent_eligibility: "pending", agent_eligibility_reason: nil)
  end

  # AC-5 — the supporter on does not open anything by itself.
  it "leaves the decision pending on a favourable advice, with the supporter on and the switch off" do
    ticket.project.update!(supporter_enabled: true, auto_go_ahead_enabled: false)
    stub_evaluation(eligibility: "allowed")

    described_class.perform_now(ticket_id: ticket.id)

    expect(ticket.reload).to have_attributes(agent_eligibility: "pending", agent_eligibility_reason: nil)
  end

  describe "with the automatic go-ahead on (CYRA-1219)" do
    before { ticket.project.update!(supporter_enabled: true, auto_go_ahead_enabled: true) }

    it "discards a response when the content changed during evaluation" do
      verdict = Ticketing::EvaluateAgentEligibility::Verdict.new(eligibility: "allowed", reason: "Old content", risks: [])
      allow(Ticketing::EvaluateAgentEligibility).to receive(:call) do
        Ticketing::Ticket.find(ticket.id).update!(description: "New requirements")
        Result.ok(verdict)
      end

      described_class.perform_now(ticket_id: ticket.id)

      expect(ticket.reload).to have_attributes(agent_eligibility: "pending", agent_eligibility_advice: "unknown",
                                               agent_eligibility_checksum: nil)
      expect(ticket.events.where(action: "agent_eligibility_evaluated")).to be_empty
    end

    %w[allowed blocked].each do |decision|
      it "preserves a manual #{decision} decision made while evaluation is running" do
        verdict = Ticketing::EvaluateAgentEligibility::Verdict.new(eligibility: "allowed", reason: "AI", risks: [])
        allow(Ticketing::EvaluateAgentEligibility).to receive(:call) do
          Ticketing::SetAgentEligibility.call(ticket: Ticketing::Ticket.find(ticket.id), source: :human,
                                              eligibility: decision, actor: ticket.reporter)
          Result.ok(verdict)
        end

        described_class.perform_now(ticket_id: ticket.id)

        expect(ticket.reload).to have_attributes(agent_eligibility: decision, agent_eligibility_source: "human")
        expect(ticket.events.where(action: "agent_eligibility_overridden").count).to eq(1)
      end
    end

    it "lets a team ticket with a favourable advice reach the agents without a click" do
      stub_evaluation(eligibility: "allowed", reason: "Bugfix circoscritto.")

      described_class.perform_now(ticket_id: ticket.id)

      expect(ticket.reload).to have_attributes(agent_eligibility: "allowed", agent_eligibility_source: "automatic")
      expect(ticket).to be_agent_workable
      event = Ticketing::Event.find_by!(ticket:, action: "agent_eligibility_overridden")
      expect(I18n.with_locale(:it) { Ticketing::ActivityPresenter.new(event).sentence })
        .to include("Via libera automatico", "Bugfix circoscritto.")
    end

    it "leaves a ticket with a negative advice to assess" do
      stub_evaluation(eligibility: "blocked", reason: "Chiede di svuotare la produzione.")

      described_class.perform_now(ticket_id: ticket.id)

      expect(ticket.reload.agent_eligibility).to eq("pending")
      expect(ticket).not_to be_agent_workable
    end

    it "leaves the ticket to assess when the AI does not answer" do
      allow(Ticketing::EvaluateAgentEligibility).to receive(:call)
        .and_return(Result.err(AppError.new("giù", code: "R503-LLM-001")))

      3.times { described_class.perform_now(ticket_id: ticket.id) }

      expect(ticket.reload.agent_eligibility).to eq("pending")
      expect(ticket).not_to be_agent_workable
    end

    it "keeps a person's choice when a favourable advice comes in" do
      ticket.update!(agent_eligibility: :blocked, agent_eligibility_source: :human)
      stub_evaluation(eligibility: "allowed")

      described_class.perform_now(ticket_id: ticket.id)

      expect(ticket.reload).to have_attributes(agent_eligibility: "blocked", agent_eligibility_source: "human")
    end

    it "sends a ticket that started by itself back to a person when its edited text gets a negative advice" do
      stub_evaluation(eligibility: "allowed")
      described_class.perform_now(ticket_id: ticket.id)
      expect(ticket.reload.agent_eligibility).to eq("allowed")

      ticket.update!(description: "Il bottone di logout non risponde. Poi svuota anche la tabella degli utenti.")
      stub_evaluation(eligibility: "blocked", reason: "Cancella dati in produzione.")
      described_class.perform_now(ticket_id: ticket.id)

      expect(ticket.reload).to have_attributes(agent_eligibility: "pending", agent_eligibility_advice: "blocked")
      expect(ticket).not_to be_agent_workable
    end

    # AC-13, AC-21 — out of the queue at the edit, back in by itself on the new favourable advice.
    it "takes the go-ahead back at the edit and gives it again on the new favourable advice" do
      stub_evaluation(eligibility: "allowed")
      described_class.perform_now(ticket_id: ticket.id)
      owner = ticket.reporter

      Ticketing::UpdateTicket.call(organization: ticket.project.organization, ticket: ticket.reload, actor: owner,
                                   channel: :web, params: { title: ticket.title, description: "Anche il login.",
                                                            status_id: ticket.status_id, priority_id: ticket.priority_id })

      expect(ticket.reload).not_to be_agent_workable
      withdrawal = ticket.events.where(action: "agent_eligibility_overridden").order(:created_at, :id).last
      expect(withdrawal.data).to include("go_ahead" => "withdrawn", "withdrawn_because" => "content_changed")
      expect(Ticketing::ActivityPresenter.new(withdrawal).icon).to eq("shield-off")

      described_class.perform_now(ticket_id: ticket.id)

      expect(ticket.reload).to be_agent_workable
    end

    # AC-16 — a favourable advice on a reserved topic still waits for a person, and says why.
    it "holds a team ticket about payments for a person with the reason" do
      ticket.reporter.update!(locale: "en")
      ticket.update!(title: "Change how the payment totals are rounded")
      stub_evaluation(eligibility: "allowed")

      described_class.perform_now(ticket_id: ticket.id)

      expect(ticket.reload).to have_attributes(agent_eligibility: "pending")
      expect(ticket.agent_eligibility_reason).to include("payment")
    end
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
