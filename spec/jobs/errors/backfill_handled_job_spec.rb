# frozen_string_literal: true

require "rails_helper"

# CYRA-49: backfill dello storico. Il dato mechanism.handled è ancora nel payload conservato → il job
# lo recupera con la stessa logica dell'ingest e accende has_unhandled dei gruppi (monotòno).
RSpec.describe Errors::BackfillHandledJob, type: :job do
  let(:project) { create(:project) }

  def payload_with(handled)
    { "exception" => { "values" => [ { "type" => "E", "value" => "x", "mechanism" => { "handled" => handled } } ] } }
  end

  it "recupera handled=false dal payload e accende has_unhandled del gruppo" do
    group = create(:error_group, project:, has_unhandled: false)
    event = create(:error_event, group:, project:, handled: nil, payload: payload_with(false))

    described_class.perform_now

    expect(event.reload.handled).to be(false)
    expect(group.reload.has_unhandled).to be(true)
  end

  it "recupera handled=true e lascia il gruppo a false (nessun crash)" do
    group = create(:error_group, project:, has_unhandled: false)
    event = create(:error_event, group:, project:, handled: nil, payload: payload_with(true))

    described_class.perform_now

    expect(event.reload.handled).to be(true)
    expect(group.reload.has_unhandled).to be(false)
  end

  it "evento senza mechanism (capture_message) → handled resta nil, gruppo resta false" do
    group = create(:error_group, project:, has_unhandled: false)
    event = create(:error_event, group:, project:, handled: nil, payload: { "message" => "solo un log" })

    described_class.perform_now

    expect(event.reload.handled).to be_nil
    expect(group.reload.has_unhandled).to be(false)
  end

  it "gruppo misto: has_unhandled=true se ALMENO un'occorrenza è non gestita" do
    group = create(:error_group, project:, has_unhandled: false)
    create(:error_event, group:, project:, handled: nil, payload: payload_with(true))
    create(:error_event, group:, project:, handled: nil, payload: payload_with(false))

    described_class.perform_now

    expect(group.reload.has_unhandled).to be(true)
  end

  it "non ricalcola gli eventi già valorizzati (where handled: nil)" do
    group = create(:error_group, project:)
    event = create(:error_event, group:, project:, handled: true, payload: payload_with(false))

    described_class.perform_now

    expect(event.reload.handled).to be(true)
  end

  it "monotòno: un gruppo già has_unhandled=true NON viene spento se i suoi eventi-crash sono stati potati" do
    group = create(:error_group, :unhandled, project:)   # flag storico true, nessun evento crash residuo
    create(:error_event, group:, project:, handled: nil, payload: payload_with(true))

    described_class.perform_now

    expect(group.reload.has_unhandled).to be(true)
  end

  it "idempotente: due esecuzioni consecutive danno lo stesso esito" do
    group = create(:error_group, project:, has_unhandled: false)
    create(:error_event, group:, project:, handled: nil, payload: payload_with(false))

    described_class.perform_now
    described_class.perform_now

    expect(group.reload.has_unhandled).to be(true)
  end
end
