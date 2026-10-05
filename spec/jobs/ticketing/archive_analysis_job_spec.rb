require "rails_helper"

RSpec.describe Ticketing::ArchiveAnalysisJob, type: :job do
  include ActiveJob::TestHelper

  let(:organization) { create(:organization) }
  let(:ticket) do
    create(:ticket, organization: organization, technical_analysis: "Analisi originale. #{"a" * 1_400}")
  end

  # CYRA-547 — l'archiviazione gira sulla chiave dell'organizzazione del ticket.

  def stub_archive(result)
    allow(Ticketing::ArchiveTechnicalAnalysis).to receive(:call).and_return(result)
  end

  describe "archiviazione" do
    it "archivia il ticket" do
      stub_archive(Result.ok(ticket))

      described_class.perform_now(ticket_id: ticket.id)

      expect(Ticketing::ArchiveTechnicalAnalysis).to have_received(:call).with(ticket: ticket, fallback: false)
    end

    it "al primo tentativo NON concede il ripiego: un provider giù non lascia analisi troncate" do
      stub_archive(Result.ok(ticket))

      described_class.perform_now(ticket_id: ticket.id)

      expect(Ticketing::ArchiveTechnicalAnalysis).to have_received(:call).with(hash_including(fallback: false))
    end
  end

  describe "guardie" do
    it "non fa niente su un ticket sparito fra enqueue ed esecuzione" do
      stub_archive(Result.ok(nil))

      expect { described_class.perform_now(ticket_id: SecureRandom.uuid) }.not_to raise_error
      expect(Ticketing::ArchiveTechnicalAnalysis).not_to have_received(:call)
    end

    it "non richiama il modello su un ticket già archiviato" do
      ticket.update_column(:analysis_recomposed_at, Time.current)
      stub_archive(Result.ok(nil))

      described_class.perform_now(ticket_id: ticket.id)

      expect(Ticketing::ArchiveTechnicalAnalysis).not_to have_received(:call)
    end

    it "si ferma se il god ha spento la compattazione" do
      Settings::Global.instance.update!(ai_comment_compaction_enabled: false)
      stub_archive(Result.ok(ticket))

      described_class.perform_now(ticket_id: ticket.id)

      expect(Ticketing::ArchiveTechnicalAnalysis).not_to have_received(:call)
    end
  end

  describe "errori" do
    it "rilancia un errore del provider, così il retry fa il suo lavoro" do
      stub_archive(Result.err(AppError.new("quota", code: "R429-LLM-001")))

      expect { described_class.perform_now(ticket_id: ticket.id) }
        .to have_enqueued_job(described_class)
    end

    # CYRA-713 — il filtro dei ritentativi ora comprende anche i guasti di rete, che un codice non ce
    # l'hanno. Senza `try` l'ultimo tentativo morirebbe di NoMethodError dentro la riga di log,
    # coprendo il guasto vero con uno finto.
    it "esaurisce i tentativi su un guasto di rete senza morire nella riga di log" do
      allow(Ticketing::ArchiveTechnicalAnalysis).to receive(:call).and_raise(Net::ReadTimeout)
      allow(Rails.logger).to receive(:warn)
      described_class.perform_later(ticket_id: ticket.id)

      expect { described_class::MAX_ATTEMPTS.times { ActiveJob::Base.execute(enqueued_jobs.shift) } }
        .not_to raise_error

      expect(Rails.logger).to have_received(:warn).with(/\[analysis-archive\] abbandonato .*Net::ReadTimeout/)
    end

    it "non riprova un ticket la cui spiegazione non sta nel campo: è da guardare a mano" do
      stub_archive(Result.err(AppError.new("non ci sta", code: "R422-ANALYSIS-001")))

      expect { described_class.perform_now(ticket_id: ticket.id) }
        .not_to have_enqueued_job(described_class)
    end
  end
end
