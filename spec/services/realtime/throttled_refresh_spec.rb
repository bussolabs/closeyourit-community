# frozen_string_literal: true

require "rails_helper"

RSpec.describe Realtime::ThrottledRefresh do
  subject(:stream) { "org:00000000-0000-0000-0000-000000000001:errors" }

  # In test la cache è null_store (ogni write "riesce") → il leading scatterebbe sempre e il throttle
  # non si vedrebbe. MemoryStore riproduce la semantica reale di `unless_exist`.
  before { allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new) }

  it "il primo evento della finestra fa il refresh subito" do
    expect { described_class.call(stream) }.to have_broadcasted_to(stream).once
  end

  it "il secondo evento non fa un secondo refresh immediato ma accoda il trailing" do
    described_class.call(stream)

    expect { described_class.call(stream) }
      .to have_enqueued_job(Realtime::BroadcastRefreshJob).with(stream)
  end

  # IL punto della modifica. Prima il lock trailing scadeva con la finestra (1 secondo), quindi un
  # burst prolungato accodava un job al secondo: il 2026-07-29 sono arrivati a 94 job identici sullo
  # stesso stream. Ora finché quel job non ha girato non se ne aggiungono altri.
  it "un burst di 50 eventi accoda UN SOLO job, non uno per evento" do
    described_class.call(stream) # leading

    expect { 50.times { described_class.call(stream) } }
      .to have_enqueued_job(Realtime::BroadcastRefreshJob).with(stream).exactly(:once)
  end

  it "does not touch the shared cache while its own trailing job is pending" do
    2.times { described_class.call(stream) } # leading, then trailing scheduled
    allow(Rails.cache).to receive(:write).and_call_original

    20.times { described_class.call(stream) }

    expect(Rails.cache).not_to have_received(:write)
  end

  it "goes back to the shared cache once the trailing window has passed" do
    2.times { described_class.call(stream) }

    travel(Monitoring::Constants::BROADCAST_THROTTLE + 1.second) do
      expect { described_class.call(stream) }.to have_broadcasted_to(stream).once
    end
  end

  it "tiene i lock separati per stream diversi" do
    altro = "org:00000000-0000-0000-0000-000000000001:metrics"
    described_class.call(stream)
    described_class.call(altro)

    described_class.call(stream)
    expect { described_class.call(altro) }
      .to have_enqueued_job(Realtime::BroadcastRefreshJob).with(altro).exactly(:once)
  end

  describe "rilascio del lock" do
    it "dopo che il job ha girato, un nuovo burst può accodare il prossimo trailing" do
      described_class.call(stream)
      described_class.call(stream) # accoda il primo trailing
      Realtime::BroadcastRefreshJob.perform_now(stream)

      # La finestra leading è ancora presa (stessa MemoryStore), quindi questo va in ramo trailing.
      expect { described_class.call(stream) }
        .to have_enqueued_job(Realtime::BroadcastRefreshJob).with(stream)
    end

    # Un lock non rilasciato per un broadcast fallito congelerebbe lo stream fino al TTL: il rilascio
    # sta in un `ensure` proprio per questo. Dal CYRA-713 l'eccezione RISALE (un difetto va visto,
    # non ritentato in silenzio), ma l'`ensure` gira comunque, ed è ciò che qui conta.
    it "rilascia il lock anche se il broadcast solleva" do
      described_class.call(stream)
      described_class.call(stream) # prende il lock trailing
      allow(Turbo::StreamsChannel).to receive(:broadcast_refresh_to).and_raise(StandardError, "boom")

      expect { Realtime::BroadcastRefreshJob.perform_now(stream) }.to raise_error(StandardError, "boom")

      expect(Rails.cache.read(described_class.tail_key(stream))).to be_nil
    end
  end
end
