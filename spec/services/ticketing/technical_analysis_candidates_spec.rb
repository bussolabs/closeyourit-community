require "rails_helper"

RSpec.describe Ticketing::TechnicalAnalysisCandidates do
  let(:organization) { create(:organization) }
  let(:saturo) { "a" * (Ticketing::Constants::TECHNICAL_ANALYSIS_MAX_CHARS * 0.95).to_i }
  let(:ticket) { create(:ticket, organization: organization, technical_analysis: saturo, with_agent_workflow: true) }
  let(:author) do
    create(:account).tap { |account| create(:membership, account: account, organization: organization, role: :member) }
  end

  # I commenti storici sono oltre il tetto: si salvano aggirando la validazione, come le righe scritte
  # prima che il tetto esistesse (stesso meccanismo del trait :long).
  def comment(body, at: Time.current, on: ticket, by: author)
    Ticketing::Comment.new(ticket: on, author: by, body: body, created_at: at)
                      .tap { |c| c.save!(validate: false) }
  end

  def candidates(on: ticket) = described_class.call(ticket: on.reload)

  describe "campo saturo" do
    it "prende il commento lungo scritto quando l'analisi era piena" do
      long = comment("Dettaglio dell'implementazione. #{"x" * 400}")

      expect(candidates.flatten).to eq([ long ])
    end

    it "ignora i commenti che stanno già nel tetto dei commenti" do
      comment("Fatto, verificato in produzione.")

      expect(candidates).to be_empty
    end

    it "non prende niente se il campo analisi non era pieno" do
      ticket.update_column(:technical_analysis, "Nota breve.")
      comment("Dettaglio dell'implementazione. #{"x" * 400}")

      expect(candidates).to be_empty
    end

    it "non prende niente se il campo analisi è vuoto" do
      ticket.update_column(:technical_analysis, nil)
      comment("Dettaglio dell'implementazione. #{"x" * 400}")

      expect(candidates).to be_empty
    end
  end

  describe "commento che si dichiara continuazione" do
    let(:ticket) { create(:ticket, organization: organization, technical_analysis: "Nota breve.", with_agent_workflow: true) }

    it "lo prende anche col campo non pieno" do
      long = comment("ANALISI TECNICA ESTESA (il campo dedicato ha un limite di 1500 caratteri).\n\n#{"x" * 400}")

      expect(candidates.flatten).to eq([ long ])
    end

    it "riconosce le altre forme usate nei ticket storici" do
      [ "DETTAGLIO TECNICO (segue l'analisi nel corpo)",
        "DESIGN IMPLEMENTATIVO (verificato sul codice reale).",
        "Dettagli che non stavano nel limite dell'analisi tecnica." ].each do |intro|
        t = create(:ticket, organization: organization, technical_analysis: "Nota breve.")
        comment("#{intro}\n\n#{"x" * 400}", on: t)

        expect(candidates(on: t).flatten.size).to eq(1), "non riconosciuto: #{intro}"
      end
    end

    it "non si fa ingannare da una MENZIONE dell'analisi tecnica a metà testo" do
      comment("Rilasciato in produzione. #{"x" * 300} come da analisi tecnica del ticket. #{"x" * 100}")

      expect(candidates).to be_empty
    end
  end

  describe "analisi spezzata su più commenti" do
    it "unisce in un gruppo solo i commenti dello stesso autore ravvicinati" do
      first = comment("Prima parte. #{"x" * 400}", at: 20.minutes.ago)
      second = comment("Seconda parte. #{"x" * 400}", at: 18.minutes.ago)

      expect(candidates).to eq([ [ first, second ] ])
    end

    it "separa i gruppi quando passa più della finestra" do
      first = comment("Prima parte. #{"x" * 400}", at: 3.hours.ago)
      second = comment("Molto dopo. #{"x" * 400}", at: 1.hour.ago)

      expect(candidates).to eq([ [ first ], [ second ] ])
    end

    it "separa i gruppi quando cambia l'autore" do
      other = create(:account).tap do |account|
        create(:membership, account: account, organization: organization, role: :member)
      end
      first = comment("Prima parte. #{"x" * 400}", at: 20.minutes.ago)
      second = comment("Risposta di un altro. #{"x" * 400}", at: 18.minutes.ago, by: other)

      expect(candidates).to eq([ [ first ], [ second ] ])
    end

    it "tiene i pezzi in ordine cronologico" do
      late = comment("Seconda parte. #{"x" * 400}", at: 18.minutes.ago)
      early = comment("Prima parte. #{"x" * 400}", at: 20.minutes.ago)

      expect(candidates.first).to eq([ early, late ])
    end
  end

  describe "cosa resta fuori" do
    it "scarta le righe di servizio scritte dall'app" do
      comment("Resoconto aggiornato. #{"x" * 400}").update_column(:kind, :service)

      expect(candidates).to be_empty
    end

    it "scarta le domande di chiarimento, che hanno già casa loro" do
      question = comment("Domanda per il team. #{"x" * 400}")
      create(:agent_clarification, workflow: ticket.agent_workflow, question_comment: question)

      expect(candidates).to be_empty
    end
  end
end
