# frozen_string_literal: true

require "rails_helper"

# Page-refresh Turbo realtime dello stream log dell'org (CYRA-57, gemello di Errors::Broadcast/CYRA-41).
# Logs::Broadcast.refresh è il contratto write-side del PATH CALDO d'ingest: non spedisce HTML né
# renderizza righe nel worker, emette solo un segnale di refresh (action="refresh") sulla lista log
# dell'org. Sostituisce il vecchio prepend PER OGNI riga inserita (fino a 1000 render+cable per batch)
# che bloccava la coda :ingest. Throttle leading + trailing (Solid Cache + Realtime::BroadcastRefreshJob).
RSpec.describe Logs::Broadcast, type: :service do
  let(:organization) { create(:organization) }
  let(:list_stream) { Realtime::Streams.logs(organization) }

  describe ".refresh" do
    it "emette un page-refresh Turbo (action=refresh) sullo stream log dell'org" do
      expect { described_class.refresh(organization) }
        .to have_broadcasted_to(list_stream).with(a_string_including('action="refresh"'))
    end

    it "isolamento tenant: non broadcasta sullo stream log di un'ALTRA org" do
      other = Realtime::Streams.logs(create(:organization))
      expect { described_class.refresh(organization) }.not_to have_broadcasted_to(other)
    end

    it "throttla i leading ravvicinati sullo stesso stream (una finestra = un leading immediato)" do
      allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new)
      expect do
        described_class.refresh(organization)
        described_class.refresh(organization)
      end.to have_broadcasted_to(list_stream).once
    end

    it "trailing: gli eventi dopo il leading coalescono in UN refresh differito (stato finale del burst)" do
      allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new)
      described_class.refresh(organization)   # 1° → leading immediato

      expect { described_class.refresh(organization) }   # 2° → trailing schedulato a fine finestra
        .to have_enqueued_job(Realtime::BroadcastRefreshJob).with(list_stream)
    end
  end

  # CYRA-822 — un batch di log appartiene a UN progetto, quindi il segnale sa già di chi è: oltre al
  # livello org-wide (chi guarda tutto) tocca il livello del progetto (chi guarda solo quello). Chi
  # sta osservando un altro progetto non riceve più niente.
  describe "fan-out per progetto della lista (CYRA-822)" do
    let(:project) { create(:project, organization:) }
    let(:altro_progetto) { create(:project, organization:) }
    let(:stream_progetto) { Realtime::Streams.project_logs_list(project) }
    let(:stream_altro) { Realtime::Streams.project_logs_list(altro_progetto) }

    it "manda il refresh anche sullo stream lista del progetto del batch" do
      expect { described_class.refresh(organization, projects: [ project ]) }
        .to have_broadcasted_to(stream_progetto).with(a_string_including('action="refresh"'))
    end

    it "NON manda niente sullo stream lista di un ALTRO progetto della stessa org" do
      altro_progetto # creato prima della misura
      expect { described_class.refresh(organization, projects: [ project ]) }
        .not_to have_broadcasted_to(stream_altro)
    end

    it "tiene il refresh org-wide: chi non filtra continua a vedere gli aggiornamenti" do
      expect { described_class.refresh(organization, projects: [ project ]) }
        .to have_broadcasted_to(list_stream).with(a_string_including('action="refresh"'))
    end

    it "senza progetto dichiarato resta il solo livello org-wide (nessun segnale perso)" do
      expect { described_class.refresh(organization) }
        .to have_broadcasted_to(list_stream).with(a_string_including('action="refresh"'))
    end

    it "sullo stream lista del progetto viaggia il solo segnale, mai HTML renderizzato" do
      visti = []
      expect { described_class.refresh(organization, projects: [ project ]) }
        .to have_broadcasted_to(stream_progetto).with { |html| visti << html }

      expect(visti.join).not_to include("log-entry-row")
    end

    it "throttla i due livelli separatamente" do
      allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new)

      expect do
        described_class.refresh(organization, projects: [ project ])
        described_class.refresh(organization, projects: [ project ])
      end.to have_broadcasted_to(stream_progetto).once
    end
  end
end
