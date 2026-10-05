# frozen_string_literal: true

require "rails_helper"

# CYRA-614 — due ingressi, e servono entrambi: la consegna accoda il job subito dopo il commit (così
# nel caso normale non si aspetta il giro), e un ricorrente ripassa le righe scadute (così una
# consegna arrivata mentre il lavoro era giù non resta lì per sempre).
RSpec.describe Agents::CandidateVerificationJob do
  let(:organization) { create(:organization) }

  it "col suo id verifica quella riga e basta" do
    dovuta = create(:agent_delivery_candidate, organization:, next_check_at: 1.minute.ago)
    altra = create(:agent_delivery_candidate, organization:, next_check_at: 1.minute.ago)
    visti = []
    allow(Agents::Candidates::Verify).to receive(:call) { |candidate:| visti << candidate.id }

    described_class.perform_now(dovuta.id)

    expect(visti).to eq([ dovuta.id ])
    expect(visti).not_to include(altra.id)
  end

  it "senza id raccoglie le righe scadute, e lascia stare quelle che aspettano ancora" do
    scaduta = create(:agent_delivery_candidate, organization:, next_check_at: 1.minute.ago)
    futura = create(:agent_delivery_candidate, organization:, next_check_at: 5.minutes.from_now)
    verificata = create(:agent_delivery_candidate, :verified_passing, organization:, next_check_at: 1.minute.ago)
    visti = []
    allow(Agents::Candidates::Verify).to receive(:call) { |candidate:| visti << candidate.id }

    described_class.perform_now

    expect(visti).to eq([ scaduta.id ])
    expect(visti).not_to include(futura.id, verificata.id)
  end

  # Una riga che esplode non deve portarsi dietro le altre del lotto: il silenzio su un lotto intero
  # sarebbe indistinguibile da «non c'era niente da fare».
  it "una riga che esplode non ferma le altre" do
    prima = create(:agent_delivery_candidate, organization:, next_check_at: 2.minutes.ago)
    seconda = create(:agent_delivery_candidate, organization:, next_check_at: 1.minute.ago)
    visti = []
    allow(Agents::Candidates::Verify).to receive(:call) do |candidate:|
      raise "esplosa" if candidate.id == prima.id

      visti << candidate.id
    end

    expect { described_class.perform_now }.not_to raise_error
    expect(visti).to eq([ seconda.id ])
  end
  it "rispetta scadenza e limite anche quando gli ID hanno ordine opposto" do
    stub_const("#{described_class}::BATCH", 2)
    righe = 3.times.map do |index|
      id = "00000000-0000-4000-8000-#{format('%012d', index + 1)}"
      create(:agent_delivery_candidate, organization:, id: id, next_check_at: (index + 1).minutes.ago)
    end
    visti = []
    allow(Agents::Candidates::Verify).to receive(:call) { |candidate:| visti << candidate.id }

    described_class.perform_now

    expect(visti).to eq([ righe[2].id, righe[1].id ])
  end
end
