# frozen_string_literal: true

require "rails_helper"

RSpec.describe Errors::ApplyGroupingRules do
  let(:project) { create(:project) }
  let(:payload) { { "exception" => { "values" => [ { "type" => "PaymentError" } ] } } }
  let(:base_fp) { "original-fingerprint" }

  def apply = described_class.call(project:, payload:, fingerprint: base_fp)

  it "senza regole → fingerprint invariato" do
    expect(apply).to eq(base_fp)
  end

  it "una regola che matcha → il fingerprint della regola" do
    rule = create(:error_grouping_rule, project:, field: :exception_type, operator: :contains,
                                        value: "Payment", fingerprint_key: "payments")
    expect(apply).to eq(rule.target_fingerprint)
  end

  it "una regola che NON matcha → invariato" do
    create(:error_grouping_rule, project:, field: :exception_type, operator: :equals,
                                 value: "OtherError", fingerprint_key: "x")
    expect(apply).to eq(base_fp)
  end

  it "la PRIMA regola attiva in ordine di position vince" do
    create(:error_grouping_rule, project:, position: 2, field: :exception_type, operator: :contains,
                                 value: "Payment", fingerprint_key: "second")
    first = create(:error_grouping_rule, project:, position: 1, field: :exception_type, operator: :contains,
                                         value: "Payment", fingerprint_key: "first")
    expect(apply).to eq(first.target_fingerprint)
  end

  it "ignora le regole disattivate" do
    create(:error_grouping_rule, project:, active: false, field: :exception_type, operator: :contains,
                                 value: "Payment", fingerprint_key: "x")
    expect(apply).to eq(base_fp)
  end

  # Anti-BOLA: una regola di un ALTRO progetto non tocca questo ingest.
  it "applica solo le regole del progetto in ingest" do
    create(:error_grouping_rule, project: create(:project), field: :exception_type, operator: :contains,
                                 value: "Payment", fingerprint_key: "x")
    expect(apply).to eq(base_fp)
  end

  # La prova end-to-end: due errori con TIPO diverso, che senza regole formerebbero due gruppi, con
  # regole a stesso fingerprint_key confluiscono in uno solo.
  describe "integrazione con l'ingest" do
    it "unifica errori diversi che colpiscono regole con lo stesso fingerprint_key" do
      create(:error_grouping_rule, project:, field: :exception_type, operator: :contains,
                                   value: "Timeout", fingerprint_key: "timeouts")
      create(:error_grouping_rule, project:, field: :exception_type, operator: :contains,
                                   value: "Deadline", fingerprint_key: "timeouts")

      Errors::Ingest::Record.call(project:, payload: {
        "event_id" => SecureRandom.hex(16), "exception" => { "values" => [ { "type" => "ConnectionTimeoutError" } ] }
      })
      Errors::Ingest::Record.call(project:, payload: {
        "event_id" => SecureRandom.hex(16), "exception" => { "values" => [ { "type" => "DeadlineExceededError" } ] }
      })

      expect(project.error_groups.count).to eq(1)
      expect(project.error_groups.first.events_count).to eq(2)
    end
  end
end
