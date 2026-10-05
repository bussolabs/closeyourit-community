require "rails_helper"

RSpec.describe Ticketing::RecordReport do
  let(:organization) { create(:organization) }
  let(:ticket) { create(:ticket, organization: organization) }
  let(:author) do
    create(:account).tap { |account| create(:membership, account: account, organization: organization, role: :member) }
  end

  def record(body, **options)
    described_class.call(ticket: ticket, author: author, body: body, **options)
  end

  describe "prima versione" do
    it "crea la versione 1 e la ritorna" do
      result = record("Fatto: aggiunte le verifiche mancanti.")

      expect(result).to be_ok
      expect(result.value.version).to eq(1)
      expect(result.value.body).to eq("Fatto: aggiunte le verifiche mancanti.")
      expect(ticket.reload.current_report).to eq(result.value)
    end

    it "registra l'origine richiesta" do
      expect(record("Testo.", source: :agent).value).to be_source_agent
    end

    it "nasce manuale se l'origine non è dichiarata" do
      expect(record("Testo.").value).to be_source_manual
    end
  end

  describe "versioni successive" do
    it "crea la versione 2 senza toccare la 1" do
      first = record("Prima stesura.").value
      second = record("Seconda stesura, più completa.").value

      expect(second.version).to eq(2)
      expect(first.reload.body).to eq("Prima stesura.")
      expect(ticket.reload.reports.chronological.map(&:body))
        .to eq([ "Prima stesura.", "Seconda stesura, più completa." ])
    end
  end

  describe "idempotenza" do
    it "non crea una nuova versione se il testo è identico al corrente" do
      first = record("Stesso testo.").value

      expect { @result = record("Stesso testo.") }.not_to change(Ticketing::Report, :count)
      expect(@result).to be_ok
      expect(@result.value).to eq(first)
    end

    it "riconosce l'identità anche a meno di spazi ai bordi e fine-riga" do
      record("Stesso testo.")

      expect { record("  Stesso testo.\r\n".sub("\r\n", "")) }.not_to change(Ticketing::Report, :count)
    end

    it "crea una nuova versione se il testo torna a una stesura precedente" do
      record("A.")
      record("B.")

      expect { record("A.") }.to change(Ticketing::Report, :count).by(1)
      expect(ticket.reload.current_report.version).to eq(3)
    end
  end

  describe "riga di servizio nella discussione" do
    it "annuncia il primo resoconto senza numero di versione" do
      expect { record("Testo.") }.to change(ticket.comments, :count).by(1)

      comment = ticket.comments.reload.last
      expect(comment).to be_kind_service
      expect(comment.body).to eq(I18n.t("ticketing.reports.service_line.created"))
      expect(comment.body.length).to be <= Ticketing::Constants::COMMENT_MAX_CHARS
    end

    it "annuncia gli aggiornamenti col numero di versione" do
      record("Prima.")
      record("Seconda.")

      expect(ticket.comments.reload.last.body)
        .to eq(I18n.t("ticketing.reports.service_line.updated", version: 2))
    end

    it "non scrive nessuna riga quando il testo è identico e non nasce una versione" do
      record("Testo.")

      expect { record("Testo.") }.not_to change(ticket.comments, :count)
    end

    # CYRA-389 — una versione scritta respingendo un lavoro ha una riga sua: "resoconto aggiornato
    # alla versione 2" farebbe credere che qualcuno abbia raccontato altro lavoro fatto, mentre quello
    # che c'è da leggere è il motivo per cui il lavoro torna indietro.
    it "annuncia con la sua riga la versione nata da un respingimento" do
      record("Manca il caso limite, e va rifatta la verifica.", source: :review_rejection)

      comment = ticket.comments.reload.last
      expect(comment).to be_kind_service
      expect(comment.body).to eq(I18n.t("ticketing.reports.service_line.review_rejection"))
      expect(comment.body.length).to be <= Ticketing::Constants::COMMENT_MAX_CHARS
    end
  end

  describe "errori" do
    it "rifiuta un corpo vuoto con R422-REPORT-001" do
      result = record("   ")

      expect(result).to be_err
      expect(result.error.code).to eq("R422-REPORT-001")
      expect(result.error.details[:body]).to be_present
    end

    it "rifiuta un corpo oltre il tetto e non lascia versioni a metà" do
      expect { @result = record("x" * (Ticketing::Constants::REPORT_MAX_CHARS + 1)) }
        .not_to change(Ticketing::Report, :count)

      expect(@result).to be_err
      expect(@result.error.code).to eq("R422-REPORT-001")
    end

    it "non scrive la riga di servizio se il resoconto non è valido" do
      expect { record("") }.not_to change(Ticketing::Comment, :count)
    end

    it "rifiuta un autore che non appartiene all'organizzazione del ticket" do
      outsider = create(:account)
      create(:membership, account: outsider, organization: create(:organization), role: :member)

      result = described_class.call(ticket: ticket, author: outsider, body: "Testo.")

      expect(result).to be_err
      expect(result.error.code).to eq("R422-REPORT-001")
    end
  end
end
