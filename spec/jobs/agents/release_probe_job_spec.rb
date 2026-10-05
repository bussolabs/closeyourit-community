# frozen_string_literal: true

require "rails_helper"

# CYRA-624/CYRA-667 — gemello di StagingProofJob sull'altra sponda: qui si guarda se il rilascio in
# produzione e' davvero in piedi. Stessi tre casi: con id, senza id, e l'eccezione che deve restare
# dentro — un job che solleva ritenta e poi tace, e il silenzio direbbe «il rilascio e' andato bene».
RSpec.describe Agents::ReleaseProbeJob do
  def prova(prossimo_controllo: 1.minute.ago, chiusa: nil, workflow: create(:agent_workflow))
    Agents::WorkflowProbe.create!(workflow:, kind: "deploy_smoke", bound_at: 1.hour.ago,
                                  next_check_at: prossimo_controllo, closed_at: chiusa)
  end

  it "con l'id di una lavorazione guarda le sue prove ancora agganciate" do
    lavorazione = create(:agent_workflow)
    mia = prova(workflow: lavorazione)
    chiusa = prova(workflow: lavorazione, chiusa: 1.minute.ago)
    altrui = prova
    visti = []
    allow(Agents::Probes::Observe).to receive(:call) { |probe:| visti << probe.id }

    described_class.perform_now(lavorazione.id)

    expect(visti).to eq([ mia.id ])
    expect(visti).not_to include(chiusa.id, altrui.id)
  end

  it "senza id raccoglie le prove scadute e ancora aperte" do
    scaduta = prova
    futura = prova(prossimo_controllo: 5.minutes.from_now)
    chiusa = prova(chiusa: 1.minute.ago)
    visti = []
    allow(Agents::Probes::Observe).to receive(:call) { |probe:| visti << probe.id }

    described_class.perform_now

    expect(visti).to eq([ scaduta.id ])
    expect(visti).not_to include(futura.id, chiusa.id)
  end

  it "una prova che esplode non ferma le altre e finisce nei log" do
    prima = prova(prossimo_controllo: 2.minutes.ago)
    seconda = prova(prossimo_controllo: 1.minute.ago)
    visti = []
    allow(Agents::Probes::Observe).to receive(:call) do |probe:|
      raise "GitHub non risponde" if probe.id == prima.id

      visti << probe.id
    end
    allow(Rails.logger).to receive(:error)

    expect { described_class.perform_now }.not_to raise_error

    expect(visti).to eq([ seconda.id ])
    expect(Rails.logger).to have_received(:error).with(/ReleaseProbeJob: #{prima.id} RuntimeError: GitHub non risponde/)
  end

  it "prende al massimo un lotto per volta" do
    expect(described_class::BATCH).to eq(25)
  end
  it "rispetta scadenza e limite anche quando gli ID hanno ordine opposto" do
    stub_const("#{described_class}::BATCH", 2)
    righe = 3.times.map do |index|
      id = "00000000-0000-4000-8000-#{format('%012d', index + 1)}"
      Agents::WorkflowProbe.create!(workflow: create(:agent_workflow), id: id, kind: "deploy_smoke",
                                    bound_at: 1.hour.ago, next_check_at: (index + 1).minutes.ago)
    end
    visti = []
    allow(Agents::Probes::Observe).to receive(:call) { |probe:| visti << probe.id }

    described_class.perform_now

    expect(visti).to eq([ righe[2].id, righe[1].id ])
  end
end
