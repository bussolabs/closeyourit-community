# frozen_string_literal: true

require "rails_helper"

RSpec.describe Logs::PruneJob do
  before { Settings::Global.instance.update!(logs_retention_days: 14) }

  it "cancella i log oltre la retention e tiene quelli entro" do
    project = create(:project)
    old = create(:log_entry, project:, created_at: 20.days.ago)
    fresh = create(:log_entry, project:, created_at: 1.day.ago)
    described_class.perform_now
    expect(Logs::Entry.exists?(old.id)).to be(false)
    expect(Logs::Entry.exists?(fresh.id)).to be(true)
  end

  it "rispetta l'override per-progetto (A 7g potato vs B 30g tenuto)" do
    a = create(:project).tap { |p| p.update!(logs_retention_days: 7) }
    b = create(:project).tap { |p| p.update!(logs_retention_days: 30) }
    log_a = create(:log_entry, project: a, created_at: 10.days.ago)
    log_b = create(:log_entry, project: b, created_at: 10.days.ago)
    described_class.perform_now
    expect(Logs::Entry.exists?(log_a.id)).to be(false)
    expect(Logs::Entry.exists?(log_b.id)).to be(true)
  end

  it "applica la retention dell'org quando il progetto non ha override" do
    org = create(:organization).tap { |o| o.update!(logs_retention_days: 5) }
    project = create(:project, organization: org) # nessun override progetto
    old = create(:log_entry, project:, created_at: 8.days.ago)
    fresh = create(:log_entry, project:, created_at: 2.days.ago)
    described_class.perform_now
    expect(Logs::Entry.exists?(old.id)).to be(false)  # 8 > 5 (org) → potato
    expect(Logs::Entry.exists?(fresh.id)).to be(true) # 2 < 5 → resta
  end

  it "risolve Settings::Global una sola volta (no N+1 sul singleton)" do
    create_list(:project, 3).each { |p| create(:log_entry, project: p) }
    expect(Settings::Global).to receive(:instance).once.and_call_original
    described_class.perform_now
  end

  it "usa la coda :batch dei lavori lunghi" do
    expect(described_class.new.queue_name).to eq("batch")
  end

  # CYRA-750, scenario del ticket: passata la finestra di conservazione di un periodo, la fetta di
  # quel periodo se ne va in un istante — e leggere e scrivere continua a funzionare come prima.
  describe "le fette scadute" do
    def crea_fetta(mese)
      nome = Ops::Partitions.partition_name("logs_entries", mese)
      da, a = Ops::Partitions.bounds_for(mese)
      ActiveRecord::Base.connection.execute(<<~SQL.squish)
        CREATE TABLE IF NOT EXISTS "#{nome}" PARTITION OF "logs_entries"
          FOR VALUES FROM ('#{da.strftime('%Y-%m-%d %H:%M:%S')}') TO ('#{a.strftime('%Y-%m-%d %H:%M:%S')}')
      SQL
      nome
    end

    def fetta_esiste?(nome)
      ActiveRecord::Base.connection.select_value("SELECT to_regclass('#{nome}')::text").present?
    end

    it "toglie la fetta interamente fuori dalla finestra, con tutto il suo contenuto" do
      vecchia = crea_fetta(10.months.ago)
      create(:log_entry, project: create(:project), created_at: 10.months.ago)

      described_class.perform_now

      expect(fetta_esiste?(vecchia)).to be(false)
    end

    it "non tocca la fetta del mese in corso, dove si sta ancora scrivendo" do
      corrente = Ops::Partitions.partition_name("logs_entries", Time.current)
      fresco = create(:log_entry, project: create(:project), created_at: 1.day.ago)

      described_class.perform_now

      expect(fetta_esiste?(corrente)).to be(true)
      expect(Logs::Entry.exists?(fresco.id)).to be(true)
    end

    # La finestra che decide il distacco è la PIÙ LUNGA in vigore, non quella del singolo cliente:
    # nella fetta ci sono le righe di tutti, e chi conserva di più deve ritrovarcele.
    it "tiene la fetta finché il cliente che conserva più a lungo ne ha diritto" do
      create(:project).update!(logs_retention_days: 365)
      vecchia = crea_fetta(3.months.ago)
      create(:log_entry, project: create(:project), created_at: 3.months.ago)

      described_class.perform_now

      expect(fetta_esiste?(vecchia)).to be(true)
    end
  end

  # CYRA-750 — un collegamento manuale non può più essere tenuto dal database (una chiave esterna
  # verso una tabella a fette pretenderebbe un'unicità che lì non può esistere): se restasse, la
  # pagina dell'errore mostrerebbe un log che non c'è più.
  it "pota i collegamenti rimasti senza il loro log" do
    project = create(:project)
    entry = create(:log_entry, project:, created_at: 20.days.ago)
    link = create(:log_link, log_entry: entry, linkable: create(:error_group, project:))

    described_class.perform_now

    expect(Logs::Link.exists?(link.id)).to be(false)
  end
end
