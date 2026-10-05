# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20260903170000_split_agent_eligibility_advice_from_decision")

# CYRA-770 — il parco esistente porta marchi scritti dall'AI dentro la colonna della DECISIONE, cioè
# quella che la coda degli agenti interroga. Lo spostamento dei dati è la parte che non si può
# rifare: se sbagliasse verso, un ticket consentito da una persona tornerebbe in attesa (fastidio) o
# un ticket marcato dalla sola AI resterebbe in coda (il guasto che il ticket chiude).
RSpec.describe SplitAgentEligibilityAdviceFromDecision do
  def sposta!
    ActiveRecord::Migration.suppress_messages { described_class.new.sposta_marchi_automatici_nel_parere }
  end

  let(:organization) { create(:organization) }

  it "sposta nel parere il marchio automatico e riporta il ticket in attesa" do
    ticket = create(:ticket, organization:)
    ticket.update_columns(agent_eligibility: 1, agent_eligibility_source: 0,
                          agent_eligibility_reason: "Bugfix circoscritto.")

    sposta!

    expect(ticket.reload).to have_attributes(
      agent_eligibility: "pending",
      agent_eligibility_reason: nil,
      agent_eligibility_advice: "allowed",
      agent_eligibility_advice_reason: "Bugfix circoscritto."
    )
  end

  it "sposta anche i marchi automatici negativi" do
    ticket = create(:ticket, organization:)
    ticket.update_columns(agent_eligibility: 2, agent_eligibility_source: 0,
                          agent_eligibility_reason: "Tocca la produzione.")

    sposta!

    expect(ticket.reload).to have_attributes(agent_eligibility: "pending", agent_eligibility_advice: "blocked")
  end

  it "non tocca la decisione presa da una persona" do
    ticket = create(:ticket, organization:)
    ticket.update_columns(agent_eligibility: 1, agent_eligibility_source: 1,
                          agent_eligibility_reason: "Lo seguo io.")

    sposta!

    expect(ticket.reload).to have_attributes(
      agent_eligibility: "allowed",
      agent_eligibility_source: "human",
      agent_eligibility_reason: "Lo seguo io.",
      agent_eligibility_advice: "unknown",
      agent_eligibility_advice_reason: nil
    )
  end

  # Un ticket mai valutato resta identico: nessun parere inventato, nessuna decisione inventata.
  it "lascia com'è un ticket che nessuno ha ancora guardato" do
    ticket = create(:ticket, organization:)

    sposta!

    expect(ticket.reload).to have_attributes(agent_eligibility: "pending", agent_eligibility_advice: "unknown")
  end
  describe "azzeramenti registrati come valutazione automatica" do
    def riattribuisci!
      ActiveRecord::Migration.suppress_messages { described_class.new.riattribuisci_azzeramenti_storici }
    end

    let(:ticket) { create(:ticket, organization:) }
    let(:actor) { create(:account) }

    # Solo l'azzeramento porta un ticket a «da valutare»: il parere dell'AI dice sempre lavorabile o
    # non lavorabile. È questo a rendere i due casi distinguibili a posteriori senza indovinare.
    it "riattribuisce alla persona l'evento che riporta il ticket in attesa" do
      evento = Ticketing::Event.create!(ticket:, organization:, actor_id: actor.id,
                                        action: "agent_eligibility_evaluated",
                                        data: { "agent_eligibility" => { "from" => "allowed", "to" => "pending" } })

      riattribuisci!

      expect(evento.reload.action).to eq("agent_eligibility_overridden")
    end

    it "lascia dov'è il parere dell'AI, che non porta mai in attesa" do
      evento = Ticketing::Event.create!(ticket:, organization:, actor_id: actor.id,
                                        action: "agent_eligibility_evaluated",
                                        data: { "agent_eligibility" => { "from" => "pending", "to" => "allowed" } })

      riattribuisci!

      expect(evento.reload.action).to eq("agent_eligibility_evaluated")
    end

    it "non tocca un evento senza attore: non avrebbe nessuno da mostrare al posto del robot" do
      evento = Ticketing::Event.create!(ticket:, organization:, actor_id: nil,
                                        action: "agent_eligibility_evaluated",
                                        data: { "agent_eligibility" => { "from" => "allowed", "to" => "pending" } })

      riattribuisci!

      expect(evento.reload.action).to eq("agent_eligibility_evaluated")
    end
  end
end
