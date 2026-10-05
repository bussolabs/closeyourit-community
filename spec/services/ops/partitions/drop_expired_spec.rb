# frozen_string_literal: true

require "rails_helper"

# CYRA-750 — è il pezzo che rende istantanea la pulizia notturna: la fetta scaduta si stacca invece
# di essere svuotata riga per riga. Le creazioni e i distacchi di questa prova tornano indietro col
# rollback: in PostgreSQL anche il comando che crea o butta una tabella sta dentro la transazione.
RSpec.describe Ops::Partitions::DropExpired do
  def crea_fetta(tabella, mese)
    nome = Ops::Partitions.partition_name(tabella, mese)
    da, a = Ops::Partitions.bounds_for(mese)
    ActiveRecord::Base.connection.execute(<<~SQL.squish)
      CREATE TABLE IF NOT EXISTS "#{nome}" PARTITION OF "#{tabella}"
        FOR VALUES FROM ('#{da.strftime('%Y-%m-%d %H:%M:%S')}') TO ('#{a.strftime('%Y-%m-%d %H:%M:%S')}')
    SQL
    nome
  end

  def fetta_esiste?(nome)
    ActiveRecord::Base.connection.select_value("SELECT to_regclass('#{nome}')::text").present?
  end

  let(:vecchia) { crea_fetta("logs_entries", 10.months.ago) }
  let(:recente) { crea_fetta("logs_entries", 1.month.ago) }

  it "stacca la fetta interamente fuori dalla finestra" do
    vecchia

    esito = described_class.call(table: "logs_entries", keep_from: 3.months.ago)

    expect(esito).to include(vecchia)
    expect(fetta_esiste?(vecchia)).to be(false)
  end

  # Il confronto è sul limite ALTO della fetta proprio perché anche l'ultima riga che contiene deve
  # essere scaduta: bastasse il limite basso, si butterebbe via un mese di dati ancora dovuti.
  it "non tocca la fetta che contiene ancora righe dentro la finestra" do
    recente

    described_class.call(table: "logs_entries", keep_from: 3.months.ago)

    expect(fetta_esiste?(recente)).to be(true)
  end

  it "non tocca mai la fetta di riserva: non porta un mese nel nome, quindi non scade" do
    described_class.call(table: "logs_entries", keep_from: 100.years.from_now)

    expect(fetta_esiste?("logs_entries_pdefault")).to be(true)
  end

  it "non guarda le fette di un'altra tabella" do
    altra = crea_fetta("errors_events", 10.months.ago)

    described_class.call(table: "logs_entries", keep_from: 3.months.ago)

    expect(fetta_esiste?(altra)).to be(true)
  end

  it "rifiuta una tabella che non è divisa a fette" do
    expect { described_class.call(table: "projects", keep_from: 3.months.ago) }.to raise_error(KeyError)
  end

  it "non stacca niente senza una finestra" do
    vecchia

    expect(described_class.call(table: "logs_entries", keep_from: nil)).to eq([])
    expect(fetta_esiste?(vecchia)).to be(true)
  end
end
