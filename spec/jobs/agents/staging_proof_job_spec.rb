# frozen_string_literal: true

require "rails_helper"

# CYRA-620/CYRA-667 — due ingressi, e servono entrambi: con un id si verifica quella lavorazione e
# basta, senza id si raccolgono le righe consegnate, non ancora verificate e scadute. Il terzo caso
# e' il rescue: qui un'eccezione NON deve propagarsi, perche' un job che solleva ritenta tre volte e
# poi tace, e il silenzio sarebbe indistinguibile da «e' andato tutto bene».
RSpec.describe Agents::StagingProofJob do
  def lavorazione(completata: 1.hour.ago, verificata: nil, prossimo_controllo: 1.minute.ago, annullata: nil)
    create(:agent_workflow).tap do |w|
      w.update!(closer_staging_completed_at: completata, closer_staging_verified_at: verificata,
                closer_staging_next_check_at: prossimo_controllo, cancelled_at: annullata)
    end
  end

  it "col suo id verifica quella lavorazione e basta" do
    dovuta = lavorazione
    altra = lavorazione
    visti = []
    allow(Agents::Staging::VerifyMerge).to receive(:call) { |workflow:| visti << workflow.id }

    described_class.perform_now(dovuta.id)

    expect(visti).to eq([ dovuta.id ])
    expect(visti).not_to include(altra.id)
  end

  it "senza id raccoglie le scadute e lascia stare le altre" do
    scaduta = lavorazione
    futura = lavorazione(prossimo_controllo: 5.minutes.from_now)
    gia_verificata = lavorazione(verificata: 1.minute.ago)
    annullata = lavorazione(annullata: 1.minute.ago)
    mai_consegnata = lavorazione(completata: nil)
    visti = []
    allow(Agents::Staging::VerifyMerge).to receive(:call) { |workflow:| visti << workflow.id }

    described_class.perform_now

    expect(visti).to eq([ scaduta.id ])
    expect(visti).not_to include(futura.id, gia_verificata.id, annullata.id, mai_consegnata.id)
  end

  it "una riga che esplode non ferma le altre e finisce nei log" do
    prima = lavorazione(prossimo_controllo: 2.minutes.ago)
    seconda = lavorazione(prossimo_controllo: 1.minute.ago)
    visti = []
    allow(Agents::Staging::VerifyMerge).to receive(:call) do |workflow:|
      raise "GitHub non risponde" if workflow.id == prima.id

      visti << workflow.id
    end
    allow(Rails.logger).to receive(:error)

    expect { described_class.perform_now }.not_to raise_error

    expect(visti).to eq([ seconda.id ])
    expect(Rails.logger).to have_received(:error).with(/StagingProofJob: #{prima.id} RuntimeError: GitHub non risponde/)
  end

  it "prende al massimo un lotto per volta" do
    expect(described_class::BATCH).to eq(25)
  end
  it "rispetta scadenza e limite anche quando gli ID hanno ordine opposto" do
    stub_const("#{described_class}::BATCH", 2)
    righe = 3.times.map do |index|
      id = "00000000-0000-4000-8000-#{format('%012d', index + 1)}"
      create(:agent_workflow, id: id, closer_staging_completed_at: 1.hour.ago,
               closer_staging_next_check_at: (index + 1).minutes.ago)
    end
    visti = []
    allow(Agents::Staging::VerifyMerge).to receive(:call) { |workflow:| visti << workflow.id }

    described_class.perform_now

    expect(visti).to eq([ righe[2].id, righe[1].id ])
  end
end
