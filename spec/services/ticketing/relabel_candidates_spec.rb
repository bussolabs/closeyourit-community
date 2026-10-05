# frozen_string_literal: true

require "rails_helper"

# Chi entra nel backfill delle etichette e chi no (CYRA-266). È la decisione che, sbagliata, salta
# ticket in silenzio o ne riscrive di già a posto — e vive dentro un rake, cioè nel posto che nessuno
# guarda finché non ha già fatto danni.
RSpec.describe Ticketing::RelabelCandidates do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }

  def ticket_with(analysis, **attributes)
    create(:ticket, organization:, project:, technical_analysis: analysis, **attributes)
  end

  def candidates(**options) = described_class.call(**options)

  it "prende le analisi senza etichette" do
    ticket = ticket_with("Un muro di prosa senza nessun appiglio.")

    expect(candidates[:workable]).to include(ticket)
  end

  it "salta le analisi che le etichette ce l'hanno già" do
    ticket_with("**Approccio:** già a posto.")

    expect(candidates[:workable]).to be_empty
  end

  # Basta UNA etichetta del vocabolario: un'analisi che apre con **Fatto:** è già nella forma, anche
  # se non le ha tutte.
  it "riconosce anche una sola etichetta" do
    ticket_with("Testo introduttivo.\n\n**Rischi:** qualcosa può rompersi.")

    expect(candidates[:workable]).to be_empty
  end

  it "salta i ticket senza analisi" do
    ticket_with(nil)
    ticket_with("")

    expect(candidates[:workable]).to be_empty
  end

  it "salta i ticket già riscritti" do
    ticket_with("Prosa da riscrivere.", analysis_relabeled_at: 1.hour.ago)

    expect(candidates[:workable]).to be_empty
  end

  describe "l'automazione in corso" do
    let!(:ticket) { ticket_with("Prosa da riscrivere.", with_agent_workflow: true) }

    before { ticket.agent_workflow.update!(triage_started_at: 1.minute.ago) }

    it "lo mette fra i bloccati, non fra i lavorabili" do
      result = candidates

      expect(result[:locked]).to include(ticket)
      expect(result[:workable]).to be_empty
    end

    # Una lavorazione conclusa non blocca più niente: il ticket torna normale.
    it "torna lavorabile a lavorazione finita" do
      ticket.agent_workflow.update!(completed_at: Time.current)

      expect(candidates[:workable]).to include(ticket)
    end
  end

  describe "il limite" do
    before { 3.times { |i| ticket_with("Prosa numero #{i} da riscrivere.") } }

    it "conta i ticket presi, non quelli scartati" do
      expect(candidates(limit: 2)[:workable].length).to eq(2)
    end

    it "senza limite li prende tutti" do
      expect(candidates[:workable].length).to eq(3)
    end
  end

  # CYRA-765 — l'AI la offre il sistema: non esiste più una terza lista di ticket esclusi perché la
  # loro organizzazione non ha collegato niente. I ticket di qualunque organizzazione sono lavorabili.
  describe "organizzazioni diverse" do
    it "prende anche i ticket di un'altra organizzazione" do
      altra = create(:organization)
      progetto = create(:project, organization: altra)
      altrui = create(:ticket, organization: altra, project: progetto,
                               technical_analysis: "Prosa di un'altra organizzazione.")

      expect(candidates[:workable]).to include(altrui)
    end

    it "non torna più la lista dei non collegati" do
      ticket_with("Prosa da riscrivere.")

      expect(candidates.keys).to contain_exactly(:workable, :locked)
    end
  end
end
