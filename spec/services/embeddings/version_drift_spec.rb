# frozen_string_literal: true

require "rails_helper"

RSpec.describe Embeddings::VersionDrift do
  # Conteggi ASSOLUTI → parto dalle 3 tabelle vuote. delete_all è transazionale (rollback a fine
  # esempio) e le FK figlie del ticket cascano nel DELETE (vedi Ticketing::Ticket).
  before do
    Ticketing::Ticket.delete_all
    Errors::Group.delete_all
    Knowledge::Page.delete_all
  end

  it "conta embeddate/correnti/invisibili per ciascuna delle tre tabelle" do
    current = create(:ticket)
    current.update_columns(embedding: basis_vector(0), embedding_version: Ai::Constants::EMBEDDING_VERSION)
    stale = create(:ticket)
    stale.update_columns(embedding: basis_vector(1), embedding_version: nil)
    create(:ticket) # senza embedding → non conta né tra le embeddate né tra le correnti

    tickets = described_class.call.tables.find { |t| t.key == :tickets }

    expect(tickets.embedded).to eq(2)
    expect(tickets.current).to eq(1)
    expect(tickets.stale).to eq(1)
    expect(tickets).to be_drift
  end

  it "una versione DIVERSA da quella corrente conta come invisibile" do
    group = create(:error_group)
    group.update_columns(embedding: basis_vector(0), embedding_version: "qwen3-emb-0.6b-1024-v0")

    groups = described_class.call.tables.find { |t| t.key == :error_groups }

    expect(groups.embedded).to eq(1)
    expect(groups.current).to eq(0)
    expect(groups.stale).to eq(1)
  end

  it "versione corrente + assente + obsoleta insieme: embedded le somma, current conta solo la corrente" do
    current = create(:ticket)
    current.update_columns(embedding: basis_vector(0), embedding_version: Ai::Constants::EMBEDDING_VERSION)
    missing = create(:ticket)
    missing.update_columns(embedding: basis_vector(1), embedding_version: nil)
    obsolete = create(:ticket)
    obsolete.update_columns(embedding: basis_vector(2), embedding_version: "qwen3-emb-0.6b-1024-v0")

    tickets = described_class.call.tables.find { |t| t.key == :tickets }

    expect(tickets.embedded).to eq(3)
    expect(tickets.current).to eq(1)
    expect(tickets.stale).to eq(2)
  end

  it "senza righe invisibili non c'è drift" do
    page = create(:knowledge_page)
    page.update_columns(embedding: basis_vector(0), embedding_version: Ai::Constants::EMBEDDING_VERSION)

    report = described_class.call

    expect(report.any_drift?).to be(false)
    expect(report.total_stale).to eq(0)
    expect(report.drifted).to be_empty
  end

  it "aggrega il totale invisibili e restituisce le sole tabelle in drift" do
    ticket = create(:ticket)
    ticket.update_columns(embedding: basis_vector(0), embedding_version: nil)
    group = create(:error_group)
    group.update_columns(embedding: basis_vector(0), embedding_version: nil)

    report = described_class.call

    expect(report.total_stale).to eq(2)
    expect(report.any_drift?).to be(true)
    expect(report.drifted.map(&:key)).to contain_exactly(:tickets, :error_groups)
  end

  # CYRA-232: le righe MAI embeddate (embedding NULL) restavano fuori da ogni conteggio → un guasto del
  # servizio embedding lasciava un buco invisibile e il pannello restava verde. Ora contano come missing,
  # ma solo oltre una grazia d'età (il NULL è transitorio subito dopo la create, job async in coda).
  describe "contenuti mai indicizzati (missing)" do
    it "una riga senza embedding oltre la grazia conta come missing e fa drift" do
      buried = create(:ticket)
      buried.update_columns(embedding: nil, created_at: (Embeddings::VersionDrift::MISSING_GRACE + 1.minute).ago)

      tickets = described_class.call.tables.find { |t| t.key == :tickets }

      expect(tickets.missing).to eq(1)
      expect(tickets.embedded).to eq(0)
      expect(tickets).to be_drift
    end

    it "una riga senza embedding entro la grazia NON conta (attesa normale post-creazione)" do
      fresh = create(:ticket)
      fresh.update_columns(embedding: nil, created_at: 1.minute.ago)

      tickets = described_class.call.tables.find { |t| t.key == :tickets }

      expect(tickets.missing).to eq(0)
      expect(tickets).not_to be_drift
    end

    it "aggrega il totale dei mai indicizzati oltre la grazia sulle tre tabelle" do
      ticket = create(:ticket)
      ticket.update_columns(embedding: nil, created_at: 2.hours.ago)
      group = create(:error_group)
      group.update_columns(embedding: nil, created_at: 2.hours.ago)

      report = described_class.call

      expect(report.total_missing).to eq(2)
      expect(report.any_drift?).to be(true)
      expect(report.drifted.map(&:key)).to contain_exactly(:tickets, :error_groups)
    end

    it "now iniettabile: sposta in avanti il confine della grazia" do
      row = create(:ticket)
      row.update_columns(embedding: nil, created_at: 30.minutes.ago)

      # grazia 1h, riga di 30' → ancora giovane
      expect(described_class.call.tables.find { |t| t.key == :tickets }.missing).to eq(0)
      # spostando "adesso" avanti di 1h, la stessa riga supera la grazia
      later = described_class.call(now: 1.hour.from_now).tables.find { |t| t.key == :tickets }
      expect(later.missing).to eq(1)
    end

    # Invariante: current ⊆ embedded → stale MAI negativo. Una versione corrente timbrata su una riga
    # SENZA vettore (anomalia possibile a livello dati) non deve entrare in current, o stale diventerebbe
    # negativo e nasconderebbe il drift reale delle altre righe.
    it "una versione corrente senza vettore non rende stale negativo (current ⊆ embedded)" do
      anomalous = create(:ticket)
      anomalous.update_columns(embedding: nil, embedding_version: Ai::Constants::EMBEDDING_VERSION)

      tickets = described_class.call.tables.find { |t| t.key == :tickets }

      expect(tickets.embedded).to eq(0)
      expect(tickets.current).to eq(0)
      expect(tickets.stale).to eq(0)
    end
  end
end

RSpec.describe Embeddings::VersionDrift, "helpdesk requests (CYRA-914 P8)" do
  it "counts a helpdesk request left on an old embedding version" do
    request = create(:helpdesk_request)
    request.update_columns(embedding: basis_vector(0), embedding_version: "old")

    helpdesk = described_class.call.tables.find { |t| t.key == :helpdesk_requests }

    expect(helpdesk.stale).to eq(1)
  end
end
