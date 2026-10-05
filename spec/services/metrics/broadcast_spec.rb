# frozen_string_literal: true

require "rails_helper"

# Page-refresh Turbo realtime dei gruppi-metrica (CYRA-41). Su nuovo campione l'ingest non ricalcola
# più aggregati org-wide né spedisce HTML: emette solo un segnale di refresh (action="refresh") sui due
# stream toccati — lista org (metrics) e show del gruppo (metric_group) — e ogni viewer connesso
# ri-fetcha il PROPRIO URL e morpha. Throttle via cache = un refresh per finestra per stream.
# (have_broadcasted_to su stream String legge il broadcast Turbo grezzo, niente .from_channel.)
RSpec.describe Metrics::Broadcast, type: :service do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let(:group) { create(:metric_group, project:) }
  let(:list_stream) { Realtime::Streams.metrics(organization) }
  let(:group_stream) { Realtime::Streams.metric_group(group) }

  describe ".refresh" do
    it "emette un page-refresh Turbo (action=refresh) sullo stream lista dell'org" do
      expect { described_class.refresh(group) }
        .to have_broadcasted_to(list_stream).with(a_string_including('action="refresh"'))
    end

    it "emette un page-refresh Turbo (action=refresh) sullo stream della show del gruppo" do
      expect { described_class.refresh(group) }
        .to have_broadcasted_to(group_stream).with(a_string_including('action="refresh"'))
    end

    it "un solo refresh per stream a chiamata (null_store in test: il throttle non blocca)" do
      expect { described_class.refresh(group) }.to have_broadcasted_to(list_stream).once
    end

    it "NON esegue aggregazioni org-wide (nessun GROUP BY kind, nessun MAX della durata)" do
      queries = captured_sql { described_class.refresh(group) }
      expect(queries).not_to include(a_string_matching(/group by.*kind/i))
      expect(queries).not_to include(a_string_matching(/max\(duration_total_ms/i))
    end

    it "isolamento tenant: non broadcasta sullo stream metrics di un'ALTRA org" do
      other = Realtime::Streams.metrics(create(:organization))
      expect { described_class.refresh(group) }.not_to have_broadcasted_to(other)
    end

    it "throttla i leading ravvicinati sullo stesso stream (una finestra = un leading immediato)" do
      allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new)
      expect do
        described_class.refresh(group)
        described_class.refresh(group)
      end.to have_broadcasted_to(list_stream).once
    end

    it "trailing: gli eventi dopo il leading coalescono in UN refresh differito (stato finale del burst)" do
      allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new)
      described_class.refresh(group)   # 1° → leading immediato

      expect { described_class.refresh(group) }   # 2° → trailing schedulato a fine finestra
        .to have_enqueued_job(Realtime::BroadcastRefreshJob).with(list_stream)
    end
  end

  # CYRA-822 — due livelli: org-wide per chi guarda tutto, progetto dell'evento per chi guarda solo
  # quello. Chi sta osservando un altro progetto non riceve più il segnale.
  describe "fan-out per progetto della lista (CYRA-822)" do
    let(:altro_progetto) { create(:project, organization:) }
    let(:stream_progetto) { Realtime::Streams.project_metrics_list(project) }
    let(:stream_altro) { Realtime::Streams.project_metrics_list(altro_progetto) }

    it "manda il refresh anche sullo stream lista del progetto del campione" do
      expect { described_class.refresh(group) }
        .to have_broadcasted_to(stream_progetto).with(a_string_including('action="refresh"'))
    end

    it "NON manda niente sullo stream lista di un ALTRO progetto della stessa org" do
      altro_progetto # creato prima della misura
      expect { described_class.refresh(group) }.not_to have_broadcasted_to(stream_altro)
    end

    it "tiene il refresh org-wide: chi non filtra continua a vedere gli aggiornamenti" do
      expect { described_class.refresh(group) }
        .to have_broadcasted_to(list_stream).with(a_string_including('action="refresh"'))
    end

    it "sullo stream lista del progetto viaggia il solo segnale, mai HTML renderizzato" do
      visti = []
      expect { described_class.refresh(group) }
        .to have_broadcasted_to(stream_progetto).with { |html| visti << html }

      expect(visti.join).not_to include(ActionView::RecordIdentifier.dom_id(group))
    end

    it "throttla i due livelli separatamente" do
      allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new)

      expect do
        described_class.refresh(group)
        described_class.refresh(group)
      end.to have_broadcasted_to(stream_progetto).once
    end
  end
end
