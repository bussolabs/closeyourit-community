# frozen_string_literal: true

require "rails_helper"

# CYRA-730 — il contratto in scrittura degli aggiornamenti dal vivo della flotta: lo usano l'ingest
# dei campioni, il controllo delle macchine mute e le azioni della pagina. I nomi dei canali vengono
# SOLO da Realtime::Streams, che porta l'organizzazione dentro il nome: sbagliare canale qui vuol
# dire mandare la riga di una macchina a un'altra organizzazione.
RSpec.describe Servers::Broadcast, type: :service do
  let(:organization) { create(:organization) }
  let(:host) { create(:server_host, :up, organization: organization) }
  let(:fleet_stream) { Realtime::Streams.servers(organization.id) }
  let(:host_stream) { Realtime::Streams.server_host(host) }

  describe ".row (la riga della macchina nella lista)" do
    it "sostituisce la riga della macchina sul canale della flotta" do
      expect { described_class.row(host) }
        .to have_broadcasted_to(fleet_stream)
        .with(a_string_including(ActionView::RecordIdentifier.dom_id(host)))
    end

    it "isolamento fra organizzazioni: nulla arriva sul canale di un'altra" do
      altra = Realtime::Streams.servers(create(:organization).id)

      expect { described_class.row(host) }.not_to have_broadcasted_to(altra)
    end

    # CYRA-458: la riga aggiornata dal vivo conserva il limite accanto al valore, senza aspettare un
    # ricaricamento della pagina.
    it "porta con sé la soglia d'allarme in vigore per quella macchina" do
      create(:alerting_rule, organization: organization, event_type: :server_mem, threshold: 77)

      expect { described_class.row(host) }
        .to have_broadcasted_to(fleet_stream)
        .with(a_string_including("server-threshold-mem-#{host.id}"))
    end

    it "nessuna regola a soglia → la riga non mostra nessun limite" do
      expect { described_class.row(host) }
        .to have_broadcasted_to(fleet_stream) { |payload|
          expect(payload).not_to include("server-threshold-mem-#{host.id}")
        }
    end

    # CYRA-465: la riga deve avere le stesse colonne dell'intestazione; una cella in più romperebbe
    # l'allineamento della tabella dopo un aggiornamento.
    it "con la temperatura riportata dalla flotta la cella della temperatura compare" do
      host.update!(temp_max: 61.0)
      create(:server_sample, host: host, organization: organization, temp_max: 61.0)

      expect { described_class.row(host) }
        .to have_broadcasted_to(fleet_stream).with(a_string_including("61°"))
    end

    it "senza un solo sensore nella flotta la cella della temperatura non compare" do
      host.update!(temp_max: 61.0)
      Servers::Sample.where(organization: organization).delete_all

      expect { described_class.row(host) }
        .to have_broadcasted_to(fleet_stream) { |payload| expect(payload).not_to include("61°") }
    end
  end

  describe ".stats (i conteggi in cima alla lista)" do
    it "sostituisce il blocco dei conteggi sul canale della flotta" do
      expect { described_class.stats(organization.id) }
        .to have_broadcasted_to(fleet_stream).with(a_string_including("servers_stats"))
    end

    it "conta le macchine attive, quelle cadute e il totale" do
      host
      create(:server_host, :down, organization: organization)
      create(:server_host, organization: organization) # in attesa: né su né giù, ma nel totale

      expect(Turbo::StreamsChannel).to receive(:broadcast_replace_to)
        .with(fleet_stream, hash_including(locals: { up_count: 1, down_count: 1, total: 3 }))

      described_class.stats(organization.id)
    end

    it "non conta le macchine di un'altra organizzazione" do
      host
      create(:server_host, :up, organization: create(:organization))

      expect(Turbo::StreamsChannel).to receive(:broadcast_replace_to)
        .with(fleet_stream, hash_including(locals: { up_count: 1, down_count: 0, total: 1 }))

      described_class.stats(organization.id)
    end

    # Un solo raggruppamento per stato: la lista della flotta non deve fare una query per riga.
    it "usa una sola lettura aggregata, non una per macchina" do
      3.times { create(:server_host, :up, organization: organization) }

      query = captured_sql { described_class.stats(organization.id) }

      expect(query.grep(/from "servers_hosts"/i).size).to eq(1)
    end
  end

  describe ".refresh (la pagina della macchina)" do
    it "chiede alla pagina della macchina di rileggersi, senza spedire contenuto" do
      expect { described_class.refresh(host) }
        .to have_broadcasted_to(host_stream).with(a_string_including('action="refresh"'))
    end

    it "isolamento fra macchine: la pagina di un'altra macchina non viene toccata" do
      altra = Realtime::Streams.server_host(create(:server_host, organization: organization))

      expect { described_class.refresh(host) }.not_to have_broadcasted_to(altra)
    end
  end
end
