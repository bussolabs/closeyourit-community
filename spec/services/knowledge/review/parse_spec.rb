# frozen_string_literal: true

require "rails_helper"

RSpec.describe Knowledge::Review::Parse do
  def fixture(name) = JSON.parse(Rails.root.join("spec/fixtures/knowledge/review/verdict_#{name}.json").read)

  def parse(payload, **options) = described_class.call(payload:, model: "qwen-test", **options)

  it "legge un verdetto di accettazione" do
    result = parse(fixture("accept"))

    expect(result).to be_ok
    verdict = result.value
    expect(verdict).to be_accepted
    expect(verdict.format).to eq("troubleshooting")
    expect(verdict.suggested_kind).to eq("note")
    expect(verdict.model).to eq("qwen-test")
    expect(verdict.violations).to be_empty
  end

  it "legge un rifiuto con le violazioni del modello e il doppione" do
    verdict = parse(fixture("reject")).value

    expect(verdict).to be_rejected
    expect(verdict.violations.map(&:code)).to eq(%w[T01 K04])
    expect(verdict.violations).to all(be_blocking)
    expect(verdict.duplicate_of).to eq("Rails — la cache non tiene niente in prova")
    expect(verdict.split_suggestion).to eq([ "Rails — una cosa", "Rails — l'altra" ])
  end

  it "un accept con formato unknown è un rifiuto (fail-closed)" do
    verdict = parse(fixture("unknown_format")).value

    expect(verdict).to be_rejected
    expect(verdict.violations.map(&:code)).to eq([ "K00" ])
  end

  it "un reject con formato unknown e nessuna violazione spiega comunque perché (K00)" do
    verdict = parse(fixture("accept").merge("format" => "unknown", "verdict" => "reject")).value

    expect(verdict).to be_rejected
    expect(verdict.violations.map(&:code)).to eq([ "K00" ])
  end

  it "un accept con violazioni bloccanti è un rifiuto" do
    verdict = parse(fixture("inconsistent")).value

    expect(verdict).to be_rejected
    expect(verdict.violations.map(&:code)).to eq([ "D01" ])
  end

  it "mette davanti le violazioni del pre-check" do
    pre = [ Knowledge::Review::Violation.new(code: "K11", message: "tag") ]
    verdict = parse(fixture("accept"), precheck_violations: pre).value

    expect(verdict).to be_rejected
    expect(verdict.violations.map(&:code)).to eq([ "K11" ])
  end

  it "un avviso non bloccante del pre-check non ribalta un accept" do
    pre = [ Knowledge::Review::Violation.new(code: "P05_missing", message: "manca", blocking: false) ]
    verdict = parse(fixture("accept"), precheck_violations: pre).value

    expect(verdict).to be_accepted
    expect(verdict.blocking_violations).to be_empty
  end

  it "un formato o un verdetto fuori enum è R502-KNOWLEDGE-001" do
    %w[malformed].each do |name|
      result = parse(fixture(name))
      expect(result).to be_err
      expect(result.error.code).to eq("R502-KNOWLEDGE-001")
      expect(result.error.status).to eq(:bad_gateway)
    end
    expect(parse("stringa").error.code).to eq("R502-KNOWLEDGE-001")
    expect(parse(fixture("accept").except("violations")).error.code).to eq("R502-KNOWLEDGE-001")
    expect(parse(fixture("accept").merge("violations" => [ { "code" => "T01" } ])).error.code).to eq("R502-KNOWLEDGE-001")
  end

  it "il riassunto elenca solo le prime violazioni, per la CLI" do
    verdict = parse(fixture("reject")).value
    expect(verdict.summary(limit: 1)).to eq("T01 — Il sintomo non cita il messaggio esatto.")
  end

  it "page_attributes riempie le colonne ai_review_*" do
    attrs = parse(fixture("reject")).value.page_attributes(reviewed_at: Time.zone.parse("2026-09-03 10:00"))
    expect(attrs[:ai_review_verdict]).to eq(:rejected)
    expect(attrs[:ai_review_format]).to eq("troubleshooting")
    expect(attrs[:ai_review_violations].first).to include(code: "T01", blocking: true)
    expect(attrs[:ai_review_model]).to eq("qwen-test")
  end
end

# CYRA-773 — le regole meccaniche le decide il pre-check: se le cita il modello sono avvisi.
RSpec.describe Knowledge::Review::Parse, "regole meccaniche dal modello" do
  def fixture(name) = JSON.parse(Rails.root.join("spec/fixtures/knowledge/review/verdict_#{name}.json").read)

  it "un reject del modello con soli avvisi diventa accept" do
    payload = fixture("reject").merge("violations" => [ { "code" => "K02", "message" => "titolo" }, { "code" => "K14", "message" => "link" } ])
    verdict = described_class.call(payload:).value
    expect(verdict).to be_accepted
    expect(verdict.violations.map(&:blocking)).to eq([ false, false ])
  end

  it "K02/K11 citate dal modello non bloccano un accept, una regola di sostanza sì" do
    payload = fixture("accept").merge("violations" => [ { "code" => "K02", "message" => "titolo narrativo" }, { "code" => "K11", "message" => "tag" } ])
    verdict = described_class.call(payload:).value
    expect(verdict).to be_accepted
    expect(verdict.violations.map(&:blocking)).to eq([ false, false ])

    payload["violations"] << { "code" => "K04", "message" => "per ora" }
    expect(described_class.call(payload:).value).to be_rejected
  end
end

# CYAU-200 — un rifiuto per una regola di sostanza dice anche DOVE: il passaggio della pagina che lo
# motiva. Una citazione che nel testo non c'è manderebbe a cercare una frase mai scritta.
RSpec.describe Knowledge::Review::Parse, "il passaggio citato" do
  def fixture(name) = JSON.parse(Rails.root.join("spec/fixtures/knowledge/review/verdict_#{name}.json").read)

  let(:body) { "Formato: riferimento\n\nPer ora la tabella sta qui.\n\n| a | b |" }

  def parse(violations, source: body)
    described_class.call(payload: fixture("accept").merge("verdict" => "reject", "violations" => violations), source: source)
  end

  it "tiene la citazione quando compare davvero nel testo" do
    verdict = parse([ { "code" => "K04", "message" => "Stato temporaneo.", "quote" => "Per ora la tabella sta qui." } ]).value

    expect(verdict.violations.first.quote).to eq("Per ora la tabella sta qui.")
    expect(verdict.violations.first.to_h).to include(quote: "Per ora la tabella sta qui.")
  end

  it "riconosce il passaggio anche se il modello lo ricopia con spazi o maiuscole diverse" do
    verdict = parse([ { "code" => "R01", "message" => "Narrazione.", "quote" => "per ora   la TABELLA sta qui." } ]).value

    expect(verdict.violations.first.quote).to eq("per ora   la TABELLA sta qui.")
  end

  it "scarta la citazione che nel testo non c'è" do
    allow(Rails.logger).to receive(:warn)

    verdict = parse([ { "code" => "R01", "message" => "Narrazione.", "quote" => "questa frase non l'ha scritta nessuno" } ]).value

    expect(verdict.violations.first.quote).to be_nil
    expect(verdict.violations.first.message).to eq("Narrazione.")
    expect(Rails.logger).to have_received(:warn).with(/citazione/)
  end

  it "una violazione per qualcosa che MANCA non ha niente da citare" do
    verdict = parse([ { "code" => "T04", "message" => "Manca la Verifica.", "quote" => "" } ]).value

    expect(verdict.violations.first.quote).to be_nil
    expect(verdict).to be_rejected
  end

  it "il riassunto per la CLI porta il passaggio accanto alla regola" do
    verdict = parse([ { "code" => "K04", "message" => "Stato temporaneo.", "quote" => "Per ora la tabella sta qui." } ]).value

    expect(verdict.summary(limit: 1)).to eq("K04 — Stato temporaneo. «Per ora la tabella sta qui.»")
  end

  it "le violazioni del pre-check restano senza citazione" do
    pre = [ Knowledge::Review::Violation.new(code: "K11", message: "tag") ]
    verdict = described_class.call(payload: fixture("accept"), precheck_violations: pre, source: body).value

    expect(verdict.violations.first.quote).to be_nil
    expect(verdict.summary).to eq("K11 — tag")
  end
end
