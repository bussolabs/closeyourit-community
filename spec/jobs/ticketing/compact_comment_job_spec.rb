require "rails_helper"

RSpec.describe Ticketing::CompactCommentJob, type: :job do
  let(:organization) { create(:organization) }
  let(:ticket) { create(:ticket, organization: organization) }
  let(:long_body) { "Fatto: coperti i rami scoperti. #{"x" * 400}" }
  # Riga storica: scritta prima che il tetto esistesse, quindi salvata aggirando le validazioni.
  let(:comment) do
    build(:ticket_comment, organization: organization, ticket: ticket, body: long_body)
      .tap { |record| record.save!(validate: false) }
  end

  # CYRA-547 — il riassunto gira sulla chiave dell'organizzazione del ticket.

  def stub_summary(value)
    allow(Ticketing::SummarizeComment).to receive(:call).and_return(Result.ok(value))
  end

  def stub_failure(code = "R429-LLM-001")
    allow(Ticketing::SummarizeComment).to receive(:call)
      .and_return(Result.err(AppError.new("quota", code: code)))
  end

  describe "compattazione" do
    it "sostituisce il corpo col riassunto e conserva l'integrale" do
      stub_summary("Coperti i rami scoperti. (resoconto v1)")

      described_class.perform_now(comment_id: comment.id)
      comment.reload

      expect(comment.body).to eq("Coperti i rami scoperti. (resoconto v1)")
      expect(comment.original_body).to eq(long_body)
      expect(comment.compacted_at).to be_present
    end

    it "passa al riassuntore la versione del resoconto che nasce da questo commento" do
      create(:ticket_report, organization: organization, ticket: ticket,
                             source: :migrated, source_comment: comment, body: long_body)
      stub_summary("Breve.")

      described_class.perform_now(comment_id: comment.id)

      # L'organizzazione viaggia col lavoro (CYRA-547): è chi paga la chiamata.
      expect(Ticketing::SummarizeComment).to have_received(:call)
        .with(body: long_body, report_version: 1, organization: organization.id)
    end
  end

  describe "idempotenza" do
    it "non richiama il modello su un commento già compattato" do
      comment.update_columns(compacted_at: Time.current)
      stub_summary("Non deve arrivarci.")

      described_class.perform_now(comment_id: comment.id)

      expect(Ticketing::SummarizeComment).not_to have_received(:call)
    end

    it "marca fatto un commento già corto senza chiamare il modello" do
      short = create(:ticket_comment, organization: organization, ticket: ticket, body: "Confermo.")
      stub_summary("Non deve arrivarci.")

      described_class.perform_now(comment_id: short.id)

      expect(short.reload.compacted_at).to be_present
      expect(short.body).to eq("Confermo.")
      expect(Ticketing::SummarizeComment).not_to have_received(:call)
    end

    it "non esplode se il commento è stato cancellato nel frattempo" do
      expect { described_class.perform_now(comment_id: SecureRandom.uuid) }.not_to raise_error
    end
  end

  describe "freno del god" do
    it "si ferma senza toccare niente se la compattazione è spenta" do
      Settings::Global.instance.update!(ai_comment_compaction_enabled: false)

      described_class.perform_now(comment_id: comment.id)

      expect(comment.reload.compacted_at).to be_nil
      expect(comment.body).to eq(long_body)
    end
  end

  describe "degrado" do
    it "rilancia l'errore ai primi tentativi, così il retry può fare il suo lavoro" do
      stub_failure

      expect { described_class.new.perform(comment_id: comment.id) }.to raise_error(AppError)
      expect(comment.reload.compacted_at).to be_nil
    end

    it "all'ultimo tentativo ripiega sul troncamento del testo vero invece di arrendersi" do
      stub_failure
      job = described_class.new(comment_id: comment.id)
      job.executions = described_class::MAX_ATTEMPTS

      job.perform(comment_id: comment.id)
      comment.reload

      expect(comment.compacted_at).to be_present
      expect(comment.body.length).to be <= Ticketing::Constants::COMMENT_MAX_CHARS
      expect(comment.body).to start_with("Fatto: coperti i rami scoperti.")
      expect(comment.original_body).to eq(long_body)
    end
  end

  describe "allegati legacy" do
    it "non rivalida gli allegati già attaccati mentre riscrive il corpo" do
      comment.files.attach(io: StringIO.new("x"), filename: "a.png", content_type: "image/png")
      comment.save!
      stub_summary("Breve.")

      described_class.perform_now(comment_id: comment.id)

      expect(comment.reload.files).to be_attached
      expect(comment.body).to eq("Breve.")
    end
  end
end
