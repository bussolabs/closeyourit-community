require "rails_helper"

RSpec.describe Ticketing::Question, type: :model do
  it "produce una domanda valida" do
    expect(build(:ticket_question)).to be_valid
  end

  describe "corpo" do
    it "è invalido se vuoto o di soli spazi" do
      expect(build(:ticket_question, body: nil)).not_to be_valid
      expect(build(:ticket_question, body: "   ")).not_to be_valid
    end

    it "normalizza gli spazi e mette gli accenti mancanti" do
      question = create(:ticket_question, body: "  Se ne e' accorto?  ")

      expect(question.body).to eq("Se ne è accorto?")
    end

    it "accetta il limite e rifiuta un carattere in più, dicendo di quanto ha sforato" do
      max = Ticketing::Constants::QUESTION_MAX_CHARS
      expect(build(:ticket_question, body: "x" * max)).to be_valid

      question = build(:ticket_question, body: "x" * (max + 1))
      expect(question).to be_invalid
      expect(question.errors.details[:body])
        .to include(hash_including(error: :length_budget_exceeded, count: max, actual: max + 1))
    end
  end

  # Il tetto stretto vale SOLO per chi lo deve rispettare. È il numero del contratto verso gli host,
  # non una regola di stile: una persona che scrive duecento caratteri non sta violando niente.
  describe "tetto delle domande di un agente" do
    let(:max) { Ticketing::Constants::AGENT_QUESTION_MAX_CHARS }

    it "rifiuta una domanda di un agente oltre il limite del contratto" do
      question = build(:ticket_question, :from_agent, body: "x" * (max + 1))

      expect(question).to be_invalid
      expect(question.errors.details[:body]).to include(hash_including(error: :too_long))
    end

    it "lascia passare la stessa lunghezza se la domanda è di una persona" do
      expect(build(:ticket_question, body: "x" * (max + 1))).to be_valid
    end
  end

  # La stessa regola che aveva Agents::Clarification: una domanda si legge, non si esegue. Ora vale
  # anche per le domande poste a mano, che prima non passavano da nessun controllo.
  describe "una domanda non contiene comandi" do
    it "rifiuta backtick, indirizzi, percorsi e comandi" do
      [ "Hai provato `bin/rails db:migrate`?",
        "Guarda https://example.com/x, va bene?",
        "Il file sta in app/models/x.rb o in ./altro?",
        "Devo fare bundle install prima?" ].each do |body|
        expect(build(:ticket_question, body: body)).to be_invalid, "accettata: #{body}"
      end
    end

    it "accetta una domanda scritta in parole" do
      expect(build(:ticket_question, body: "La priorità mancante deve dare errore o un default?"))
        .to be_valid
    end
  end

  describe "isolamento tenant" do
    it "rifiuta un autore che non è membro dell'organizzazione del ticket" do
      question = build(:ticket_question, author: create(:account))

      expect(question).to be_invalid
      expect(question.errors.details[:author]).to include(hash_including(error: :not_member))
    end
  end

  describe "stato" do
    it "è aperta finché non ha risposta né è stata ritirata" do
      expect(build(:ticket_question)).to be_open
      expect(build(:ticket_question, answered_at: Time.current)).not_to be_open
      expect(build(:ticket_question, closed_at: Time.current)).not_to be_open
    end
  end

  describe "scope" do
    let(:ticket) { create(:ticket) }

    it "open tiene solo le domande senza risposta e non ritirate" do
      aperta = create(:ticket_question, ticket: ticket, organization: ticket.project.organization)
      create(:ticket_question, :answered, ticket: ticket, organization: ticket.project.organization)
      create(:ticket_question, ticket: ticket, organization: ticket.project.organization,
                               closed_at: Time.current)

      expect(described_class.open).to contain_exactly(aperta)
    end

    it "blocking_open tiene solo le bloccanti ancora aperte" do
      bloccante = create(:ticket_question, :blocking, ticket: ticket,
                                                      organization: ticket.project.organization)
      create(:ticket_question, ticket: ticket, organization: ticket.project.organization)
      create(:ticket_question, :blocking, :answered, ticket: ticket,
                                                     organization: ticket.project.organization)

      expect(described_class.blocking_open).to contain_exactly(bloccante)
    end

    # Array#sort_by non è stabile: a parità di istante serve un secondario, o l'ordine cambia fra
    # due letture identiche. È la stessa trappola già documentata sulla cronologia del ticket.
    it "chronological ordina per istante e, a parità, per identificativo" do
      istante = Time.current
      prime = create_list(:ticket_question, 3, ticket: ticket,
                                               organization: ticket.project.organization,
                                               created_at: istante)

      expect(described_class.chronological.to_a).to eq(prime.sort_by(&:id))
    end
  end

  # CYRA-848 — la distinzione internal/shared veniva salvata e mai applicata in lettura. La regola
  # vive QUI perché i lettori sono più d'uno (scheda Domande, CLI, contatori della lista): scritta nei
  # controller, il prossimo lettore nascerebbe senza filtro.
  describe "readable_by" do
    let(:organizzazione) { create(:organization) }
    let(:ticket) { create(:ticket, organization: organizzazione) }
    let!(:riservata) { create(:ticket_question, ticket: ticket, organization: organizzazione) }
    let!(:condivisa) { create(:ticket_question, :shared, ticket: ticket, organization: organizzazione) }

    def account_con_ruolo(ruolo)
      create(:account).tap { |a| create(:membership, account: a, organization: organizzazione, role: ruolo) }
    end

    it "al cliente mostra solo le domande condivise" do
      cliente = account_con_ruolo(:customer)

      expect(described_class.readable_by(cliente, organization: organizzazione)).to contain_exactly(condivisa)
    end

    it "al gruppo di lavoro le mostra tutte" do
      membro = account_con_ruolo(:member)

      expect(described_class.readable_by(membro, organization: organizzazione))
        .to contain_exactly(riservata, condivisa)
    end

    it "a un god senza membership le mostra tutte" do
      god = create(:account, god: true)

      expect(described_class.readable_by(god, organization: organizzazione))
        .to contain_exactly(riservata, condivisa)
    end

    # Fail-closed: senza qualcuno da valutare non si può decidere che è del gruppo di lavoro.
    it "senza account mostra solo le condivise" do
      expect(described_class.readable_by(nil, organization: organizzazione)).to contain_exactly(condivisa)
    end
  end
end
