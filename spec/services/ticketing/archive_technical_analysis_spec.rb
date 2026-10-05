require "rails_helper"

RSpec.describe Ticketing::ArchiveTechnicalAnalysis do
  let(:organization) { create(:organization) }
  let(:analisi) { "Analisi originale. #{"a" * 1_400}" }
  let(:ticket) { create(:ticket, organization: organization, technical_analysis: analisi) }
  let(:author) do
    create(:account, name: "Ada Lovelace")
      .tap { |account| create(:membership, account: account, organization: organization, role: :member) }
  end
  let(:client) { instance_double(Ai::Llm::Client, generate_content: { "summary" => "Il problema era X, risolto con Y." }) }

  def comment(body, at: Time.current)
    Ticketing::Comment.new(ticket: ticket, author: author, body: body, created_at: at)
                      .tap { |c| c.save!(validate: false) }
  end

  def archive(fallback: true) = described_class.call(ticket: ticket.reload, client: client, fallback: fallback)

  def attachment = ticket.reload.files.find { |f| f.filename.to_s == "analisi-tecnica-#{ticket.code}.md" }

  # ActiveStorage consegna sempre ASCII-8BIT: i byte sono UTF-8, va solo ridichiarato per confrontarli
  # con le stringhe dello spec (che contengono trattini lunghi e accenti).
  def attachment_text = attachment.download.force_encoding("UTF-8")

  describe "archiviazione" do
    before { comment("Continuazione dell'analisi. #{"x" * 400}") }

    it "allega il markdown col codice del ticket nel nome" do
      expect(archive).to be_ok
      expect(attachment).to be_present
      expect(attachment.content_type).to eq("text/markdown")
    end

    it "mette nell'allegato sia il campo sia i commenti, verbatim" do
      archive
      testo = attachment_text

      expect(testo).to include("# Analisi tecnica — #{ticket.code}")
      expect(testo).to include("Analisi originale.")
      expect(testo).to include("Continuazione dell'analisi.")
      expect(testo).to include("Ada Lovelace")
    end

    it "lascia nel campo la spiegazione col rimando all'allegato" do
      archive

      expect(ticket.reload.technical_analysis)
        .to eq("Il problema era X, risolto con Y.\n\nDettaglio completo nell'allegato analisi-tecnica-#{ticket.code}.md")
      expect(ticket.technical_analysis.length).to be <= Ticketing::Constants::TECHNICAL_ANALYSIS_MAX_CHARS
    end

    it "non tocca i commenti originali" do
      expect { archive }.not_to change { ticket.reload.comments.map(&:body) }
    end

    it "segna quando l'ha fatto" do
      expect { archive }.to change { ticket.reload.analysis_recomposed_at }.from(nil)
    end

    it "riaccoda l'embedding, che qui non passa da UpdateTicket" do
      expect { archive }.to have_enqueued_job(Ticketing::EmbedTicketJob)
    end
  end

  describe "pezzi spezzati su più commenti" do
    it "li mette nell'allegato in ordine cronologico" do
      comment("Seconda parte, la correzione. #{"x" * 400}", at: 18.minutes.ago)
      comment("Prima parte, il problema. #{"y" * 400}", at: 20.minutes.ago)
      archive
      testo = attachment_text

      expect(testo.index("Prima parte")).to be < testo.index("Seconda parte")
    end
  end

  describe "quando il riassunto dei commenti è già passato" do
    it "archivia il testo integrale, non il riassunto rimasto in discussione" do
      integrale = "Continuazione dell'analisi, versione integrale. #{"x" * 400}"
      comment("segnaposto").update_columns(body: "Riassunto breve. (resoconto v1)",
                                           original_body: integrale, compacted_at: Time.current)
      archive

      expect(attachment_text).to include("Continuazione dell'analisi, versione integrale.")
      expect(attachment_text).not_to include("Riassunto breve.")
    end
  end

  describe "idempotenza" do
    before { comment("Continuazione dell'analisi. #{"x" * 400}") }

    it "un secondo giro non allega di nuovo e non riscrive" do
      archive
      testo = ticket.reload.technical_analysis

      expect(archive.value).to be_nil
      expect(ticket.reload.files.size).to eq(1)
      expect(ticket.technical_analysis).to eq(testo)
    end
  end

  describe "niente da fare" do
    it "non tocca un ticket senza commenti da recuperare" do
      expect(archive.value).to be_nil
      expect(ticket.reload.files).to be_empty
      expect(ticket.technical_analysis).to eq(analisi)
    end

    it "non marca il ticket, così un commento futuro lo trova ancora lavorabile" do
      archive

      expect(ticket.reload.analysis_recomposed_at).to be_nil
    end
  end

  describe "senza AI" do
    before { comment("Continuazione dell'analisi. #{"x" * 400}") }

    it "senza ripiego concesso non scrive e non marca: il tentativo dopo lo ritrova da fare" do
      Settings::Global.instance.update!(ai_comment_compaction_enabled: false)

      expect(archive(fallback: false)).to be_err
      expect(ticket.reload.technical_analysis).to eq(analisi)
      expect(ticket.analysis_recomposed_at).to be_nil
    end

    it "mette comunque il testo al sicuro nell'allegato, che non dipende dal modello" do
      Settings::Global.instance.update!(ai_comment_compaction_enabled: false)
      archive(fallback: false)

      expect(attachment).to be_present
    end

    it "col ripiego concesso tronca il testo vero invece di lasciare il ticket com'è" do
      Settings::Global.instance.update!(ai_comment_compaction_enabled: false)
      archive

      expect(ticket.reload.technical_analysis).to start_with("Analisi originale.")
      expect(ticket.technical_analysis).to end_with("Dettaglio completo nell'allegato analisi-tecnica-#{ticket.code}.md")
      expect(ticket.technical_analysis.length).to be <= Ticketing::Constants::TECHNICAL_ANALYSIS_MAX_CHARS
      expect(attachment).to be_present
    end

    it "lascia traccia nei log del troncamento, che altrimenti non si distinguerebbe" do
      Settings::Global.instance.update!(ai_comment_compaction_enabled: false)
      allow(Rails.logger).to receive(:warn)

      archive

      expect(Rails.logger).to have_received(:warn).with(/\[analysis-archive\] #{ticket.code}: troncato/)
    end
  end
end
