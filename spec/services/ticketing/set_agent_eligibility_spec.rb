# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ticketing::SetAgentEligibility do
  let(:ticket) { create(:ticket, description: "corpo") }
  let(:actor) { ticket.reporter }

  describe "parere automatico" do
    it "scrive parere, motivo del parere, checksum e istante di valutazione" do
      result = described_class.call(ticket:, source: :automatic, eligibility: "blocked",
                                    reason: "Chiede di svuotare il database di produzione.",
                                    risks: %w[destructive_production], checksum: "abc123")

      expect(result).to be_ok
      expect(ticket.reload).to have_attributes(
        agent_eligibility_advice: "blocked",
        agent_eligibility_advice_reason: "Chiede di svuotare il database di produzione.",
        agent_eligibility_checksum: "abc123"
      )
      expect(ticket.agent_eligibility_evaluated_at).to be_present
    end

    # È il cuore del CYRA-770: l'AI dà un parere, non apre nessuna coda. Nemmeno su un ticket che
    # nessuno ha ancora guardato, dove prima il verdetto del modello diventava direttamente lo stato.
    it "non muove la decisione nemmeno su un ticket ancora in attesa" do
      described_class.call(ticket:, source: :automatic, eligibility: "allowed",
                           reason: "Bugfix circoscritto.", checksum: "abc")

      expect(ticket.reload).to have_attributes(
        agent_eligibility: "pending",
        agent_eligibility_source: "automatic",
        agent_eligibility_reason: nil
      )
      expect(ticket.agent_eligibility_decided_at).to be_nil
    end

    it "registra un evento di cronologia SENZA attore (l'ha dato il modello, non una persona)" do
      expect do
        described_class.call(ticket:, source: :automatic, eligibility: "allowed",
                             reason: "Bugfix circoscritto.", risks: %w[none], checksum: "abc")
      end.to change { ticket.events.where(action: "agent_eligibility_evaluated").count }.by(1)

      event = ticket.events.find_by(action: "agent_eligibility_evaluated")
      expect(event.actor).to be_nil
      expect(event.data).to include("reason" => "Bugfix circoscritto.")
      expect(event.data.dig("agent_eligibility_advice", "from")).to eq("unknown")
      expect(event.data.dig("agent_eligibility_advice", "to")).to eq("allowed")
    end

    # L'evento non deve parlare della decisione: chi legge la cronologia vedrebbe un cambio di stato
    # che non è avvenuto, e il ticket sembrerebbe entrato in coda.
    it "non racconta la decisione nei dati dell'evento" do
      described_class.call(ticket:, source: :automatic, eligibility: "allowed", reason: "ok", checksum: "abc")

      event = ticket.events.find_by(action: "agent_eligibility_evaluated")
      expect(event.data).not_to have_key("agent_eligibility")
    end
  end

  describe "decisione umana" do
    it "scrive decisore e istante e marca la sorgente come umana" do
      described_class.call(ticket:, source: :human, eligibility: "allowed",
                           reason: "So che è sicuro.", actor: actor)

      expect(ticket.reload).to have_attributes(agent_eligibility: "allowed", agent_eligibility_source: "human")
      expect(ticket.agent_eligibility_decided_by).to eq(actor)
      expect(ticket.agent_eligibility_decided_at).to be_present
    end

    it "non scrive il parere: quello lo dà solo il percorso automatico" do
      described_class.call(ticket:, source: :human, eligibility: "allowed", reason: "So che è sicuro.", actor:)

      expect(ticket.reload).to have_attributes(
        agent_eligibility_advice: "unknown",
        agent_eligibility_advice_reason: nil
      )
    end

    # Il checksum resta quello dell'ultima valutazione VERA: se la decisione lo riscrivesse, un reset
    # successivo troverebbe un ticket "già valutato" su un contenuto che nessuno ha mai esaminato.
    it "non tocca il checksum" do
      ticket.update!(agent_eligibility_checksum: "checksum-della-valutazione")

      described_class.call(ticket:, source: :human, eligibility: "blocked", reason: "Meglio di no.", actor:)

      expect(ticket.reload.agent_eligibility_checksum).to eq("checksum-della-valutazione")
    end

    it "registra un evento di decisione con l'attore" do
      described_class.call(ticket:, source: :human, eligibility: "blocked", reason: "Meglio di no.", actor:)

      event = ticket.events.find_by(action: "agent_eligibility_overridden")
      expect(event.actor).to eq(actor)
      expect(event.data.dig("agent_eligibility", "to")).to eq("blocked")
    end

    it "lascia intatto un parere già dato" do
      described_class.call(ticket:, source: :automatic, eligibility: "blocked", reason: "Rischioso.", checksum: "x")

      described_class.call(ticket:, source: :human, eligibility: "allowed", reason: "Lo seguo io.", actor:)

      expect(ticket.reload).to have_attributes(
        agent_eligibility: "allowed",
        agent_eligibility_advice: "blocked",
        agent_eligibility_advice_reason: "Rischioso."
      )
    end
  end

  describe "convivenza di parere e decisione" do
    # Non c'è più nessuna stickiness da applicare: il percorso automatico non scrive nella colonna
    # della decisione, quindi non può sovrascriverla. Lo garantisce la struttura, non una guardia.
    it "un parere successivo non tocca la decisione già presa" do
      described_class.call(ticket:, source: :human, eligibility: "allowed", reason: "So che è sicuro.", actor:)

      result = described_class.call(ticket:, source: :automatic, eligibility: "blocked",
                                    reason: "Il modello dice di no.", checksum: "nuovo")

      expect(result).to be_ok
      expect(ticket.reload).to have_attributes(agent_eligibility: "allowed", agent_eligibility_source: "human",
                                               agent_eligibility_reason: "So che è sicuro.",
                                               agent_eligibility_advice: "blocked")
    end

    it "consente a un'altra persona di cambiare la decisione" do
      described_class.call(ticket:, source: :human, eligibility: "allowed", reason: "So che è sicuro.", actor:)

      described_class.call(ticket:, source: :human, eligibility: "blocked", reason: "Ci ho ripensato.", actor:)

      expect(ticket.reload.agent_eligibility).to eq("blocked")
    end
  end

  describe "ritorno allo stato iniziale (reset)" do
    it "pulisce la decisione: stato, motivazione, decisore e checksum" do
      described_class.call(ticket:, source: :human, eligibility: "allowed", reason: "sicuro", actor:)

      described_class.call(ticket:, source: :reset, actor:)

      expect(ticket.reload).to have_attributes(
        agent_eligibility: "pending", agent_eligibility_source: "automatic",
        agent_eligibility_reason: nil, agent_eligibility_checksum: nil
      )
      expect(ticket.agent_eligibility_decided_by).to be_nil
      expect(ticket.agent_eligibility_decided_at).to be_nil
    end

    it "pulisce anche il parere: si riparte da un ticket che nessuno ha ancora guardato" do
      described_class.call(ticket:, source: :automatic, eligibility: "allowed", reason: "ok", checksum: "abc")

      described_class.call(ticket:, source: :reset, actor:)

      expect(ticket.reload).to have_attributes(
        agent_eligibility_advice: "unknown", agent_eligibility_advice_reason: nil
      )
      expect(ticket.agent_eligibility_evaluated_at).to be_nil
    end

    it "rende di nuovo possibile la valutazione automatica" do
      described_class.call(ticket:, source: :human, eligibility: "allowed", reason: "sicuro", actor:)
      described_class.call(ticket:, source: :reset, actor:)

      described_class.call(ticket:, source: :automatic, eligibility: "blocked",
                           reason: "In realtà è pericoloso.", checksum: "nuovo")

      expect(ticket.reload.agent_eligibility_advice).to eq("blocked")
    end
  end

  describe "validazione" do
    # Una persona non porta un ticket a pending da qui: per quello c'è :reset, che pulisce anche il
    # checksum. Altrimenti resterebbe un pending "già valutato" che nessuna rivalutazione ripesca.
    it "rifiuta pending come verdetto esplicito" do
      result = described_class.call(ticket:, source: :human, eligibility: "pending", reason: "boh", actor:)

      expect(result).to be_err
      expect(result.error.code).to eq("R422-TICKET-013")
      expect(ticket.reload.agent_eligibility).to eq("pending")
    end

    it "rifiuta una sorgente sconosciuta" do
      result = described_class.call(ticket:, source: :magia, eligibility: "allowed", reason: "x")

      expect(result).to be_err
      expect(result.error.code).to eq("R422-TICKET-012")
    end
  end

  describe "idempotenza" do
    it "non registra un secondo evento se nulla cambia" do
      described_class.call(ticket:, source: :automatic, eligibility: "allowed", reason: "ok", checksum: "abc")

      expect do
        described_class.call(ticket:, source: :automatic, eligibility: "allowed", reason: "ok", checksum: "abc")
      end.not_to change(Ticketing::Event, :count)
    end
  end
  describe "azzeramento" do
    # Chi legge la cronologia deve vedere CHI ha premuto. L'azzeramento cancella una decisione ed è
    # un gesto di una persona: registrarlo come «valutazione automatica» metterebbe il robot al posto
    # dell'attore, e la riga direbbe il falso proprio su chi ha tolto un consenso.
    it "è attribuito alla persona che lo preme, non all'AI" do
      described_class.call(ticket:, source: :human, eligibility: "allowed", reason: "Lo seguo io.", actor:)

      described_class.call(ticket:, source: :reset, actor:)

      event = Ticketing::Event.where(ticket:).order(:created_at).last
      expect(event.action).to eq("agent_eligibility_overridden")
      expect(event.actor_id).to eq(actor.id)
    end

    it "riporta il ticket in attesa e cancella sia la decisione sia il parere" do
      described_class.call(ticket:, source: :automatic, eligibility: "allowed", reason: "Sembra fattibile.", checksum: "abc")
      described_class.call(ticket:, source: :human, eligibility: "blocked", reason: "Non ora.", actor:)

      described_class.call(ticket:, source: :reset, actor:)

      expect(ticket.reload).to have_attributes(
        agent_eligibility: "pending", agent_eligibility_reason: nil,
        agent_eligibility_advice: "unknown", agent_eligibility_advice_reason: nil,
        agent_eligibility_checksum: nil
      )
    end
  end
end
