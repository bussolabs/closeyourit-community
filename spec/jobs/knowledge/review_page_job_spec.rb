# frozen_string_literal: true

require "rails_helper"

RSpec.describe Knowledge::ReviewPageJob, type: :job, knowledge_review: true do
  let(:reviewer) { create(:account) }
  let(:page) { create(:knowledge_page, title: "Rails — x", body: "Formato: troubleshooting", status: :published, reviewed_by: reviewer, reviewed_at: 1.day.ago) }
  let(:accepted) do
    Knowledge::Review::Verdict.new(format: "troubleshooting", verdict: "accept", violations: [], suggested_kind: "note",
                                   suggested_title: nil, split_suggestion: [], duplicate_of: nil, model: "qwen")
  end
  let(:rejected) do
    Knowledge::Review::Verdict.new(format: "unknown", verdict: "reject", suggested_kind: nil, suggested_title: nil,
                                   split_suggestion: [], duplicate_of: nil, model: "qwen",
                                   violations: [ Knowledge::Review::Violation.new(code: "K01", message: "manca Formato:") ])
  end

  it "accettata: scrive il verdetto senza versioni né re-embed" do
    allow(Knowledge::ReviewPage).to receive(:call).and_return(Result.ok(accepted))

    expect { described_class.perform_now(page_id: page.id) }.not_to have_enqueued_job(Knowledge::EmbedPageJob)
    expect(page.reload).to be_ai_review_accepted
    expect(page).to be_status_published
    expect(page.versions.count).to eq(0)
  end

  it "pubblicata e rifiutata: torna in revisione con la nota, senza toccare chi l'aveva accettata" do
    allow(Knowledge::ReviewPage).to receive(:call).and_return(Result.ok(rejected))

    described_class.perform_now(page_id: page.id)
    page.reload
    expect(page).to be_status_in_review
    expect(page).to be_ai_review_rejected
    expect(page.review_note).to include("K01 — manca Formato:")
    expect(page.reviewed_by).to eq(reviewer)
    expect(page.ai_review_violations.first).to include("code" => "K01")
  end

  it "dopo la retrocessione un rilancio non rigiudica: i due orologi coincidono" do
    allow(Knowledge::ReviewPage).to receive(:call).and_return(Result.ok(rejected))

    described_class.perform_now(page_id: page.id)
    expect(page.reload.ai_reviewed_at).to be >= page.updated_at

    described_class.perform_now(page_id: page.id)
    expect(Knowledge::ReviewPage).to have_received(:call).once
  end

  it "una causa definitiva (chiave rifiutata, ENV assenti) non si ritenta: si abbandona con un warn" do
    allow(Rails.logger).to receive(:warn)
    %w[R502-LLM-002 unconfigured].each do |cause|
      allow(Knowledge::ReviewPage).to receive(:call).and_return(Result.err(AppError.new("giù", code: "R503-KNOWLEDGE-001", status: :service_unavailable, details: { cause: })))
      expect { described_class.perform_now(page_id: page.id) }.not_to raise_error
    end
    expect(Rails.logger).to have_received(:warn).with(/senza ritentare/).twice
  end

  it "un server giù invece si ritenta: il job si riaccoda con l'attesa crescente" do
    allow(Knowledge::ReviewPage).to receive(:call).and_return(Result.err(AppError.new("giù", code: "R503-KNOWLEDGE-001", status: :service_unavailable, details: { cause: "R503-LLM-001" })))
    expect { described_class.perform_now(page_id: page.id) }.to have_enqueued_job(described_class)
  end

  it "legacy: passa il flag al revisore e mette in regola la promossa (non nel dry_run)" do
    allow(Knowledge::ReviewPage).to receive(:call).and_return(Result.ok(accepted))
    allow(Knowledge::Review::Normalize).to receive(:call).and_return(Result.ok(page))

    described_class.perform_now(page_id: page.id, legacy: true, dry_run: true)
    expect(Knowledge::ReviewPage).to have_received(:call).with(hash_including(legacy: true))
    expect(Knowledge::Review::Normalize).not_to have_received(:call)

    described_class.perform_now(page_id: page.id, legacy: true, force: true)
    expect(Knowledge::Review::Normalize).to have_received(:call).with(page: page, format: "troubleshooting")
  end

  it "non sovrascrive una review_note già scritta" do
    page.update_columns(review_note: "Vale perché…")
    allow(Knowledge::ReviewPage).to receive(:call).and_return(Result.ok(rejected))

    described_class.perform_now(page_id: page.id)
    expect(page.reload.review_note).to eq("Vale perché…")
  end

  it "dry_run: scrive il verdetto e lascia la pagina pubblicata; il giro reale poi la retrocede SENZA rigiudicarla" do
    allow(Knowledge::ReviewPage).to receive(:call).and_return(Result.ok(rejected))

    described_class.perform_now(page_id: page.id, dry_run: true)
    expect(page.reload).to be_status_published
    expect(page).to be_ai_review_rejected

    described_class.perform_now(page_id: page.id)
    expect(page.reload).to be_status_in_review
    expect(page.review_note).to include("K01")
    expect(Knowledge::ReviewPage).to have_received(:call).once
  end

  it "se nel frattempo la pagina è cambiata o è stata scartata, il verdetto non si scrive" do
    allow(Knowledge::ReviewPage).to receive(:call) {
      page.update_columns(body: "riscritta", updated_at: 1.minute.from_now)
      Result.ok(rejected)
    }
    described_class.perform_now(page_id: page.id)
    expect(page.reload.ai_review_verdict).to be_nil
    expect(page).to be_status_published

    allow(Knowledge::ReviewPage).to receive(:call) {
      page.update_columns(status: Knowledge::Page.statuses[:rejected])
      Result.ok(rejected)
    }
    described_class.perform_now(page_id: page.id, force: true)
    expect(page.reload).to be_status_rejected
    expect(page.ai_review_verdict).to be_nil
  end

  it "già in revisione e rifiutata: solo le colonne del verdetto" do
    page.update_columns(status: Knowledge::Page.statuses[:in_review])
    allow(Knowledge::ReviewPage).to receive(:call).and_return(Result.ok(rejected))

    described_class.perform_now(page_id: page.id)
    expect(page.reload).to be_ai_review_rejected
    expect(page.review_note).to be_nil
  end

  it "è idempotente sul testo già giudicato, salvo force" do
    page.update_columns(ai_reviewed_at: Time.current, updated_at: 1.hour.ago)
    allow(Knowledge::ReviewPage).to receive(:call).and_return(Result.ok(accepted))

    described_class.perform_now(page_id: page.id)
    expect(Knowledge::ReviewPage).not_to have_received(:call)

    described_class.perform_now(page_id: page.id, force: true)
    expect(Knowledge::ReviewPage).to have_received(:call).once
  end

  it "salta le scartate, le cancellate e il revisore spento" do
    allow(Knowledge::ReviewPage).to receive(:call)
    page.update_columns(status: Knowledge::Page.statuses[:rejected])
    described_class.perform_now(page_id: page.id)
    described_class.perform_now(page_id: SecureRandom.uuid)

    page.update_columns(status: Knowledge::Page.statuses[:published])
    Settings::Global.instance.update!(ai_knowledge_review_enabled: false)
    described_class.perform_now(page_id: page.id)

    expect(Knowledge::ReviewPage).not_to have_received(:call)
  end

  it "un 503 del revisore è ritentabile, una chiave rifiutata no" do
    expect(TransientFailure === AppError.new("giù", code: "R503-KNOWLEDGE-001", status: :service_unavailable)).to be(true)
    expect(TransientFailure === Ai::Llm::Client::Error.new("no", code: "R502-LLM-002")).to be(false)
  end
end
