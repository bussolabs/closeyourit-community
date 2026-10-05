# frozen_string_literal: true

require "rails_helper"

RSpec.describe Analytics::Query, type: :service do
  let(:project) { create(:project) }
  let(:pid) { project.id }

  def query(range = "24h", environment: "production")
    described_class.new(project_id: pid, range: range, environment: environment)
  end

  def pv(over = {})
    create(:pageview, { project: project, occurred_at: 1.hour.ago }.merge(over))
  end

  it "riusa un unico aggregato per visite e visitatori nello stesso snapshot, anche vuoto" do
    q = query
    sql = captured_sql do
      expect(q.pageviews_count).to eq(0)
      expect(q.visitors_count).to eq(0)
      expect(q.summary).to eq(pageviews: 0, visitors: 0)
    end
    expect(sql.grep(/SELECT.*COUNT.*FROM "analytics_pageviews"/i).size).to eq(1)
  end

  describe "#timeseries" do
    it "conta pageview e visitatori unici per bucket, zeri sui bucket vuoti" do
      pv(visitor_hash: "a", occurred_at: 30.minutes.ago)
      pv(visitor_hash: "a", occurred_at: 31.minutes.ago)
      pv(visitor_hash: "b", occurred_at: 32.minutes.ago)

      buckets = query("24h").timeseries
      expect(buckets.size).to eq(Analytics::Pageview::BUCKETS["24h"][:count])
      hot = buckets.max_by { |b| b[:pageviews] }
      expect(hot[:pageviews]).to eq(3)
      expect(hot[:visitors]).to eq(2)
      expect(buckets.count { |b| b[:pageviews].zero? }).to be >= buckets.size - 2
    end

    it "esclude il traffico fuori range e di altri environment" do
      pv(occurred_at: 2.days.ago)
      pv(environment: "staging")
      buckets = query("24h").timeseries
      expect(buckets.sum { |b| b[:pageviews] }).to eq(0)
    end

    it "porta l'istante d'inizio (:at) di ogni bucket, ordinato vecchio→nuovo (label asse X del componente)" do
      now = Time.zone.local(2026, 7, 2, 12, 0, 0)
      cfg = Analytics::Pageview::BUCKETS["24h"]
      buckets = described_class.new(project_id: pid, range: "24h", environment: "production", now: now).timeseries

      expect(buckets).to all(include(:at, :pageviews, :visitors))
      expect(buckets.first[:at]).to eq(now - (cfg[:count] * cfg[:seconds]))
      expect(buckets.last[:at]).to eq(now - cfg[:seconds])
      expect(buckets[1][:at] - buckets[0][:at]).to eq(cfg[:seconds])
    end
  end

  describe "#top_paths / #top_referrers" do
    it "ordina le pagine per volume con conteggio visitatori" do
      2.times { |i| pv(path: "/a", visitor_hash: "v#{i}") }
      pv(path: "/b")

      top = query("24h").top_paths
      expect(top.first).to eq({ path: "/a", pageviews: 2, visitors: 2 })
      expect(top.map { |r| r[:path] }).to eq(%w[/a /b])
    end

    it "esclude il traffico diretto dai referrer" do
      pv(referrer_host: "www.google.com")
      pv(referrer_host: nil)

      top = query("24h").top_referrers
      expect(top).to eq([ { referrer_host: "www.google.com", visitors: 1 } ])
    end
  end

  describe "#breakdown" do
    it "aggrega i visitatori unici per colonna, NULL escluso" do
      pv(browser: "Chrome", visitor_hash: "a")
      pv(browser: "Chrome", visitor_hash: "b")
      pv(browser: nil)

      rows = query("24h").breakdown(column: "browser")
      expect(rows).to eq([ { value: "Chrome", visitors: 2 } ])
    end

    it "rifiuta colonne fuori allowlist (mai colonna dai params)" do
      expect do
        query("24h").breakdown(column: "visitor_hash")
      end.to raise_error(ArgumentError)
    end
  end

  describe "conteggi" do
    it "pageviews/visitors/bounce/realtime sul range e sull'environment" do
      pv(visitor_hash: "a", occurred_at: 2.minutes.ago)
      pv(visitor_hash: "a", occurred_at: 1.minute.ago)
      pv(visitor_hash: "b", occurred_at: 3.minutes.ago)

      q = query("24h")
      expect(q.pageviews_count).to eq(3)
      expect(q.visitors_count).to eq(2)
      # b ha esattamente 1 pageview su 2 visitatori → bounce 50%
      expect(q.bounce_rate).to eq(50)
      expect(q.realtime_count).to eq(2)
    end

    it "bounce_rate nil senza traffico; realtime esclude visite fuori finestra" do
      expect(query("24h").bounce_rate).to be_nil

      pv(occurred_at: (Analytics::Constants::REALTIME_WINDOW + 1.minute).ago)
      expect(query("24h").realtime_count).to eq(0)
    end
  end

  describe "range non valido" do
    it "ripiega sul range di default" do
      expect(query("bogus").timeseries.size).to eq(Analytics::Pageview::BUCKETS[Analytics::Pageview::DEFAULT_RANGE][:count])
    end
  end

  describe "traffico vs eventi custom" do
    it "le metriche di traffico contano solo gli eventi 'pageview', mai i custom event" do
      pv(name: "pageview", visitor_hash: "a")
      pv(name: "pageview", visitor_hash: "b")
      pv(name: "Signup", visitor_hash: "a") # custom event → non è traffico

      q = query("24h")
      expect(q.pageviews_count).to eq(2)
      expect(q.visitors_count).to eq(2)
    end
  end

  describe "#conversions" do
    it "pageview_path goal: unique/total conversioni + rate sui visitatori totali" do
      pv(name: "pageview", path: "/pricing", visitor_hash: "a")
      pv(name: "pageview", path: "/pricing", visitor_hash: "a") # stesso visitatore, 2 pageview
      pv(name: "pageview", path: "/pricing", visitor_hash: "b")
      pv(name: "pageview", path: "/home", visitor_hash: "c") # non converte

      goal = build(:analytics_goal, project: project, path_pattern: "/pricing")
      result = query("24h").conversions(goal)
      expect(result[:unique_conversions]).to eq(2) # a, b
      expect(result[:total_conversions]).to eq(3)  # 3 pageview su /pricing
      expect(result[:conversion_rate]).to eq(66.7) # 2 su 3 visitatori totali (a,b,c)
    end

    it "custom_event goal: conta gli eventi col nome" do
      pv(name: "pageview", visitor_hash: "a")
      pv(name: "Signup", visitor_hash: "a")
      pv(name: "Signup", visitor_hash: "b")

      goal = build(:analytics_goal, :custom_event, project: project, event_name: "Signup")
      result = query("24h").conversions(goal)
      expect(result[:unique_conversions]).to eq(2)
      expect(result[:total_conversions]).to eq(2)
    end

    it "conversion_rate nil senza traffico" do
      goal = build(:analytics_goal, project: project, path_pattern: "/x")
      expect(query("24h").conversions(goal)[:conversion_rate]).to be_nil
    end
  end

  describe "#session_summary (sessionizzazione window-function)" do
    let(:t) { Time.current }

    it "raggruppa i pageview in sessioni (gap 30min): durata, views/visit, bounce per-sessione" do
      # a: 2 pageview a 5 min → 1 sessione, 2 pageview, durata 300s, non-bounce
      pv(visitor_hash: "a", path: "/home", occurred_at: t - 20.minutes)
      pv(visitor_hash: "a", path: "/pricing", occurred_at: t - 15.minutes)
      # b: 1 pageview → 1 sessione, bounce
      pv(visitor_hash: "b", path: "/home", occurred_at: t - 10.minutes)

      s = query("24h").session_summary
      expect(s[:sessions]).to eq(2)
      expect(s[:views_per_visit]).to eq(1.5) # (2+1)/2
      expect(s[:visit_duration]).to eq(150)  # media (300 + 0)/2
      expect(s[:bounce_rate]).to eq(50)      # 1 bounce su 2 sessioni
    end

    it "gap = 30min esatti → stessa sessione (non strettamente maggiore)" do
      pv(visitor_hash: "a", occurred_at: t - 40.minutes)
      pv(visitor_hash: "a", occurred_at: t - 10.minutes)
      expect(query("24h").session_summary[:sessions]).to eq(1)
    end

    it "gap = 31min → due sessioni per lo stesso visitatore" do
      pv(visitor_hash: "a", occurred_at: t - 41.minutes)
      pv(visitor_hash: "a", occurred_at: t - 10.minutes)
      expect(query("24h").session_summary[:sessions]).to eq(2)
    end

    it "esclude i custom event (solo traffico pageview)" do
      pv(visitor_hash: "a", name: "pageview", occurred_at: t - 10.minutes)
      pv(visitor_hash: "a", name: "Signup", occurred_at: t - 9.minutes)
      s = query("24h").session_summary
      expect(s[:sessions]).to eq(1)
      expect(s[:views_per_visit]).to eq(1.0)
    end

    it "bounce_rate nil senza traffico" do
      expect(query("24h").session_summary[:bounce_rate]).to be_nil
    end
  end

  describe "#entry_pages / #exit_pages" do
    it "prima e ultima pagina di ogni sessione, contate per sessione" do
      t = Time.current
      pv(visitor_hash: "a", path: "/landing", occurred_at: t - 20.minutes)
      pv(visitor_hash: "a", path: "/exit", occurred_at: t - 15.minutes)

      expect(query("24h").entry_pages.first).to eq({ path: "/landing", sessions: 1 })
      expect(query("24h").exit_pages.first).to eq({ path: "/exit", sessions: 1 })
    end
  end

  describe "#channels" do
    it "classifica le sorgenti in canali di acquisizione" do
      pv(referrer_host: "www.google.com", visitor_hash: "a")
      pv(referrer_host: "l.facebook.com", visitor_hash: "b")
      pv(referrer_host: nil, visitor_hash: "c") # traffico diretto

      labels = query("24h").channels.map { |r| r[:value] }
      expect(labels).to include("Organic Search", "Organic Social", "Direct")
    end
  end

  describe "#comparison" do
    it "confronta il periodo corrente col precedente allineato" do
      t = Time.current
      pv(occurred_at: t - 1.hour)    # periodo corrente (ultime 24h)
      pv(occurred_at: t - 25.hours)  # periodo precedente (24-48h fa)

      comp = query("24h").comparison
      expect(comp[:current][:pageviews]).to eq(1)
      expect(comp[:previous][:pageviews]).to eq(1)
    end

    it "espone solo current e previous, senza timeseries del periodo precedente (CYRA-247)" do
      comp = query("24h").comparison
      expect(comp.keys).to contain_exactly(:current, :previous)
    end
  end

  describe "filtri (allowlist)" do
    def filtered(over)
      described_class.new(project_id: pid, range: "24h", environment: "production", filters: over)
    end

    it "filtra le metriche di traffico e i breakdown per colonna ammessa" do
      pv(browser: "Chrome", path: "/a", visitor_hash: "x")
      pv(browser: "Firefox", path: "/b", visitor_hash: "y")

      q = filtered("browser" => "Chrome")
      expect(q.pageviews_count).to eq(1)
      expect(q.top_paths.map { |r| r[:path] }).to eq(%w[/a])
    end

    it "ignora i filtri fuori allowlist (mai colonne arbitrarie)" do
      pv(browser: "Chrome", visitor_hash: "x")
      q = filtered("visitor_hash" => "y", "id" => "1")
      expect(q.pageviews_count).to eq(1) # filtri ignorati → conta tutto
    end

    it "i filtri valgono anche per le sessioni (SQL raw)" do
      t = Time.current
      pv(browser: "Chrome", visitor_hash: "a", occurred_at: t - 10.minutes)
      pv(browser: "Firefox", visitor_hash: "b", occurred_at: t - 9.minutes)

      expect(filtered("browser" => "Chrome").session_summary[:sessions]).to eq(1)
    end
  end

  describe "#realtime_series" do
    it "ritorna 30 bucket da 1 minuto con i pageview per minuto" do
      pv(occurred_at: 2.minutes.ago)
      pv(occurred_at: 2.minutes.ago)

      series = query("24h").realtime_series
      expect(series.size).to eq(30)
      expect(series.sum).to eq(2)
    end
  end
end
