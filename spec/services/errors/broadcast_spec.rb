# frozen_string_literal: true

require "rails_helper"

# Page-refresh Turbo realtime dei gruppi d'errore (CYRA-41). Errors::Broadcast.refresh è il contratto
# write-side del PATH CALDO d'ingest: non ricalcola stats org-wide né spedisce HTML, emette solo un
# segnale di refresh (action="refresh") sulla lista org (errors) e sulla show del gruppo (error_group).
# Il triage (Errors::Broadcast.group, basso volume) resta il replace chirurgico di prima ed è coperto
# da spec/requests/member/monitoring/error_groups_realtime_spec.rb.
RSpec.describe Errors::Broadcast, type: :service do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let(:group) { create(:error_group, project:) }
  let(:list_stream) { Realtime::Streams.errors(organization) }
  let(:group_stream) { Realtime::Streams.error_group(group) }

  describe ".refresh" do
    it "emette un page-refresh Turbo (action=refresh) sullo stream lista dell'org" do
      expect { described_class.refresh(group) }
        .to have_broadcasted_to(list_stream).with(a_string_including('action="refresh"'))
    end

    it "emette un page-refresh Turbo (action=refresh) sullo stream della show del gruppo" do
      expect { described_class.refresh(group) }
        .to have_broadcasted_to(group_stream).with(a_string_including('action="refresh"'))
    end

    it "NON esegue aggregazioni org-wide (nessun GROUP BY status)" do
      queries = captured_sql { described_class.refresh(group) }
      expect(queries).not_to include(a_string_matching(/group by[^;]*status/i))
    end

    it "isolamento tenant: non broadcasta sullo stream errors di un'ALTRA org" do
      other = Realtime::Streams.errors(create(:organization))
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

  # CYRA-822 — il segnale di aggiornamento della lista viaggia su DUE livelli: quello org-wide, per
  # chi guarda tutta l'organizzazione, e quello del progetto dell'evento, per chi sta guardando
  # soltanto quel progetto. Chi guarda un altro progetto non riceve più niente.
  describe "fan-out per progetto della lista (CYRA-822)" do
    let(:altro_progetto) { create(:project, organization:) }
    let(:stream_progetto) { Realtime::Streams.project_errors_list(project) }
    let(:stream_altro) { Realtime::Streams.project_errors_list(altro_progetto) }

    it "manda il refresh anche sullo stream lista del progetto dell'evento" do
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

      expect(visti.join).not_to include("errors_group_#{group.id}")
      expect(visti.join).not_to include(group.title)
    end

    # Il throttle è per stream: due livelli vuol dire due finestre indipendenti, non una che spegne
    # l'altra. Senza questo, il leading del livello org consumerebbe anche quello del progetto.
    it "throttla i due livelli separatamente" do
      allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new)

      expect do
        described_class.refresh(group)
        described_class.refresh(group)
      end.to have_broadcasted_to(stream_progetto).once
    end

    it "il triage manda il refresh su entrambi i livelli" do
      expect { described_class.group(group) }
        .to have_broadcasted_to(stream_progetto).with(a_string_including('action="refresh"'))
    end

    it "il triage non aggiorna la lista filtrata su un altro progetto" do
      altro_progetto
      expect { described_class.group(group) }.not_to have_broadcasted_to(stream_altro)
    end
  end

  # CYRA-271: il replace della riga (HTML) va sullo stream PER-PROGETTO, non su quello org-wide, o
  # l'HTML della riga (titolo/culprit dell'errore) viaggerebbe sul wire anche a chi il progetto non lo vede.
  describe ".group (replace riga, path triage)" do
    let(:project_stream) { Realtime::Streams.project_errors(project) }
    let(:target) { ActionView::RecordIdentifier.dom_id(group) }

    it "manda il replace della riga sullo stream per-progetto" do
      expect { described_class.group(group) }
        .to have_broadcasted_to(project_stream).with(a_string_including(target))
    end

    it "NON fa viaggiare l'HTML della riga sullo stream org-wide" do
      expect { described_class.group(group) }
        .not_to have_broadcasted_to(list_stream).with(a_string_including(target))
    end
  end
end
