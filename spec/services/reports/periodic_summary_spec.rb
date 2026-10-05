# frozen_string_literal: true

require "rails_helper"

# CYRA-160 — i numeri che finiscono nel riepilogo periodico via email. Quello che si presidia qui è
# che siano gli STESSI che si leggono nelle pagine: una finestra sbagliata o un progetto che non si
# dovrebbe vedere valgono più di un'email brutta.
RSpec.describe Reports::PeriodicSummary, type: :service do
  let(:organization) { create(:organization) }
  let(:account) { create(:account) }
  let(:project) { create(:project, organization: organization, name: "Sito") }
  let(:now) { Time.zone.local(2026, 8, 10, 8, 0) }

  # owner: vede tutti i progetti dell'organizzazione senza collegamenti espliciti.
  before { create(:membership, account: account, organization: organization, role: :owner) }

  def summary(cadence: "weekly")
    described_class.call(account: account, organization: organization, cadence: cadence, now: now)
  end

  describe "finestra" do
    it "settimanale guarda gli ultimi 7 giorni" do
      result = summary
      expect(result.to).to eq(now)
      expect(result.from).to eq(now - 7.days)
    end

    it "giornaliero guarda le ultime 24 ore, mensile gli ultimi 30 giorni" do
      expect(summary(cadence: "daily").from).to eq(now - 24.hours)
      expect(summary(cadence: "monthly").from).to eq(now - 30.days)
    end
  end

  describe "traffico" do
    it "conta le visite del periodo e i visitatori distinti" do
      create(:pageview, project: project, occurred_at: now - 2.days, visitor_hash: "v1")
      create(:pageview, project: project, occurred_at: now - 1.day, visitor_hash: "v1")
      create(:pageview, project: project, occurred_at: now - 1.day, visitor_hash: "v2")

      result = summary
      expect(result.pageviews).to eq(3)
      expect(result.visitors).to eq(2)
    end

    it "lascia fuori ciò che è successo prima della finestra" do
      create(:pageview, project: project, occurred_at: now - 20.days)
      expect(summary.pageviews).to eq(0)
    end

    it "confronta col periodo precedente della stessa durata" do
      create(:pageview, project: project, occurred_at: now - 1.day)
      create(:pageview, project: project, occurred_at: now - 9.days)
      create(:pageview, project: project, occurred_at: now - 10.days)

      result = summary
      expect(result.pageviews).to eq(1)
      expect(result.previous_pageviews).to eq(2)
      expect(result.pageviews_delta).to eq(-50)
    end

    it "senza periodo precedente non inventa una variazione" do
      create(:pageview, project: project, occurred_at: now - 1.day)
      expect(summary.pageviews_delta).to be_nil
    end

    # Gli indirizzi che servono solo a controllare che il sito sia acceso non sono visite di persone:
    # la dashboard li esclude, l'email deve dire lo stesso numero.
    it "non conta i controlli automatici (/up, /health)" do
      create(:pageview, project: project, occurred_at: now - 1.day, path: "/up")
      expect(summary.pageviews).to eq(0)
    end
  end

  describe "errori" do
    let(:group) { create(:error_group, project: project, first_seen_at: now - 3.days) }

    it "conta gli errori avvenuti nel periodo, i problemi nuovi e quelli ancora aperti" do
      create(:error_event, group: group, project: project, occurred_at: now - 2.days)
      create(:error_event, group: group, project: project, occurred_at: now - 1.day)
      create(:error_group, project: project, first_seen_at: now - 40.days, status: :unresolved)

      result = summary
      expect(result.error_events).to eq(2)
      expect(result.new_error_groups).to eq(1)
      expect(result.open_error_groups).to eq(2)
    end

    it "i problemi già risolti non contano fra quelli aperti" do
      create(:error_group, project: project, first_seen_at: now - 3.days, status: :resolved)
      expect(summary.open_error_groups).to eq(0)
    end
  end

  describe "affidabilità dei siti" do
    it "media la percentuale di disponibilità dei monitor del periodo" do
      monitor = create(:uptime_monitor, project: project)
      create(:uptime_check, :hourly, monitor: monitor, checked_at: now - 2.days,
                                     checks_total: 100, checks_up: 90)

      expect(summary.uptime_percent).to eq(90.0)
    end

    it "senza monitor non dichiara una disponibilità che non ha misurato" do
      expect(summary.uptime_percent).to be_nil
    end

    # La finestra giornaliera legge i ping veri (la storia oraria non è ancora aggregata).
    it "il riepilogo giornaliero legge i controlli veri" do
      monitor = create(:uptime_monitor, project: project)
      create(:uptime_check, monitor: monitor, checked_at: now - 2.hours, up: true)
      create(:uptime_check, monitor: monitor, checked_at: now - 1.hour, up: false)

      expect(summary(cadence: "daily").uptime_percent).to eq(50.0)
    end
  end

  describe "righe per progetto" do
    it "una riga per progetto con dati, ordinata per traffico" do
      other = create(:project, organization: organization, name: "Blog")
      create(:pageview, project: project, occurred_at: now - 1.day)
      create(:pageview, project: other, occurred_at: now - 1.day)
      create(:pageview, project: other, occurred_at: now - 2.days)

      expect(summary.rows.map(&:name)).to eq([ "Blog", "Sito" ])
    end

    it "i progetti senza nulla da dire restano fuori" do
      create(:project, organization: organization, name: "Fermo")
      create(:pageview, project: project, occurred_at: now - 1.day)

      expect(summary.rows.map(&:name)).to eq([ "Sito" ])
    end

    # Un'organizzazione con trenta progetti riceverebbe un tabulato: si mostrano i più attivi e si
    # dice quanti restano fuori, invece di far finta che non ci siano.
    it "oltre dieci progetti mostra i più attivi e conta gli altri" do
      11.times do |i|
        altro = create(:project, organization: organization, name: "P#{i}")
        (i + 1).times { create(:pageview, project: altro, occurred_at: now - 1.day) }
      end

      result = summary
      expect(result.rows.size).to eq(described_class::MAX_ROWS)
      expect(result.other_projects).to eq(1)
      expect(result.rows.first.name).to eq("P10")
    end

    it "un progetto con soli errori compare comunque" do
      group = create(:error_group, project: project, first_seen_at: now - 2.days)
      create(:error_event, group: group, project: project, occurred_at: now - 2.days)

      row = summary.rows.first
      expect(row.name).to eq("Sito")
      expect(row.error_events).to eq(1)
    end
  end

  # Isolamento: il riepilogo è personale, e non può portare in un'email progetti che aprendo il
  # pannello non si vedrebbero.
  describe "visibilità" do
    let(:ristretto) { create(:account) }

    before { create(:membership, account: ristretto, organization: organization, role: :member) }

    it "chi non ha accesso al progetto non ne riceve i numeri" do
      create(:pageview, project: project, occurred_at: now - 1.day)

      result = described_class.call(account: ristretto, organization: organization,
                                    cadence: "weekly", now: now)
      expect(result.rows).to be_empty
      expect(result.pageviews).to eq(0)
    end

    it "i progetti di un'altra organizzazione non entrano" do
      altrove = create(:project, name: "Altrove")
      create(:pageview, project: altrove, occurred_at: now - 1.day)

      expect(summary.rows).to be_empty
    end
  end

  describe "#any_data?" do
    it "è falso quando non c'è niente da raccontare" do
      expect(summary.any_data?).to be(false)
    end

    it "è vero appena c'è un dato" do
      create(:pageview, project: project, occurred_at: now - 1.day)
      expect(summary.any_data?).to be(true)
    end
  end
end
