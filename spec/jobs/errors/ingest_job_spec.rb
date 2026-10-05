# frozen_string_literal: true

require "rails_helper"

# CYRA-211 — Il job legge il payload dalla staging effimera (in coda viaggia solo l'id) e la cancella
# una volta persistito.
RSpec.describe Errors::IngestJob, type: :job do
  let(:project) { create(:project) }

  def stage(event_id: "e1")
    Errors::IngestPayload.create!(
      project: project,
      payload: { "event_id" => event_id, "level" => "error", "message" => "boom" }
    )
  end

  it "persiste l'evento via Record leggendo il payload dalla staging" do
    staged = stage
    expect { described_class.perform_now(payload_id: staged.id) }
      .to change(Errors::Event, :count).by(1)
    expect(project.error_groups.count).to eq(1)
  end

  it "cancella la riga di staging dopo aver persistito (transitoria)" do
    staged = stage
    described_class.perform_now(payload_id: staged.id)
    expect(Errors::IngestPayload.exists?(staged.id)).to be(false)
  end

  it "staging assente (già processata o potata) → no-op idempotente, nessun errore" do
    expect { described_class.perform_now(payload_id: SecureRandom.uuid) }
      .not_to change(Errors::Event, :count)
  end

  it "è idempotente: stesso event_id due volte → un solo evento" do
    described_class.perform_now(payload_id: stage(event_id: "dup").id)
    expect { described_class.perform_now(payload_id: stage(event_id: "dup").id) }
      .not_to change(Errors::Event, :count)
  end

  it "progetto cancellato prima del processing → nessun evento, staging rimossa a cascata" do
    staged = stage
    project.destroy

    expect(Errors::IngestPayload.exists?(staged.id)).to be(false)   # ON DELETE CASCADE
    expect { described_class.perform_now(payload_id: staged.id) }
      .not_to change(Errors::Event, :count)
  end

  # Deploy rolling: un job accodato con la firma vecchia (project_id + payload inline) da un web non
  # ancora aggiornato deve essere processato lo stesso, senza ArgumentError né perdita dell'evento.
  describe "retrocompat firma pre-CYRA-211" do
    it "firma vecchia (project_id + payload) persiste l'evento senza passare dalla staging" do
      expect do
        described_class.perform_now(
          project_id: project.id,
          payload: { "event_id" => "legacy", "level" => "error", "message" => "boom" }
        )
      end.to change(Errors::Event, :count).by(1)
      expect(project.error_groups.count).to eq(1)
      expect(Errors::IngestPayload.count).to eq(0)
    end

    it "firma vecchia con progetto inesistente → scarta senza errore" do
      expect { described_class.perform_now(project_id: SecureRandom.uuid, payload: { "event_id" => "x" }) }
        .not_to change(Errors::Event, :count)
    end
  end
end
