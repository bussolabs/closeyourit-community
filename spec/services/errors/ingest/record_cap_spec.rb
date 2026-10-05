# frozen_string_literal: true

require "rails_helper"

# CYRA-196 — Tetto per gruppo al CORPO delle occorrenze conservate.
#
# Il throttle rack-attack è per PROGETTO (600/min): una raffica di un solo fingerprint ci passa sotto.
# Il 2026-07-29 sono stati 278.543 eventi identici in dieci ore contro le ~200/giorno normali, 8,6 GB
# e il disco di sentinel all'86%. Il peso erano i tre jsonb (payload/stacktrace/context), non le righe.
#
# Oltre il tetto la riga si scrive SEMPRE, senza corpo. Tenere la riga è ciò che salva l'idempotenza su
# `event_id`, `users_count`, e la rilevazione degli spike, che conta le occorrenze per bucket temporale.
#
# La soglia reale è 5.000: gli spec la abbassano via stub, perché scrivere cinquemila eventi per provare
# una funzione pura di un contatore sarebbe un test lento che verifica la stessa cosa.
RSpec.describe Errors::Ingest::Record, "tetto per gruppo (CYRA-196)", type: :service do
  let(:project) { create(:project) }

  def payload(event_id:, user: nil, occurred: nil)
    {
      "event_id" => event_id,
      "level" => "error",
      "timestamp" => (occurred || Time.current).to_f,
      "exception" => { "values" => [ {
        "type" => "RuntimeError", "value" => "boom",
        "stacktrace" => { "frames" => [ { "module" => "App", "function" => "call", "in_app" => true } ] }
      } ] }
    }.tap { |p| p["user"] = user if user }
  end

  def record(event_id, user: nil, occurred: nil)
    described_class.call(project: project, payload: payload(event_id: event_id, user: user, occurred: occurred))
  end

  def cap!(count) = stub_const("Monitoring::Constants::TELEMETRY_FULL_FIDELITY_COUNT", count)

  describe "confine del tetto (X-1 / X / X+1)" do
    before { cap!(2) }

    it "sotto il tetto l'occorrenza conserva il corpo" do
      record("e0")

      event = project.error_groups.sole.events.sole
      expect(event.stacktrace).to be_present
      expect(event.payload).to be_present
    end

    it "l'occorrenza che raggiunge il tetto conserva ancora il corpo (events_count 1 < 2)" do
      2.times { |i| record("e#{i}") }

      expect(project.error_groups.sole.events.map { |e| e.stacktrace.present? }).to eq([ true, true ])
    end

    it "oltre il tetto la riga c'è e il corpo no" do
      3.times { |i| record("e#{i}") }

      group = project.error_groups.sole
      expect(group.events_count).to eq(3)
      expect(group.events.count).to eq(3)          # la riga si scrive sempre
      spoglia = group.events.order(:created_at).last
      expect(spoglia.payload).to eq({})
      expect(spoglia.stacktrace).to eq({})
      expect(spoglia.context).to eq({})
    end

    it "l'occorrenza spoglia resta utile: quando, dove, release, trace restano" do
      2.times { |i| record("e#{i}") }
      record("e-spoglia")

      spoglia = project.error_groups.sole.events.order(:created_at).last
      expect(spoglia.event_id).to eq("e-spoglia")
      expect(spoglia.occurred_at).to be_present
      expect(spoglia.level).to eq("error")
    end
  end

  # La soglia CONTRATTUALE (Scenario 2 / DoD: "i primi cinquemila"). Ogni altro esempio abbassa la
  # costante via `cap!` per non scrivere cinquemila righe a ogni run: comodo, ma nessuno di quei test
  # fallirebbe se il default reale cambiasse. Questo è l'UNICO anello che lega il "cinquemila" del
  # requisito al codice — così un cambio silenzioso del valore rompe un test qui, non lo Scenario 2 in
  # produzione.
  describe "la soglia reale (Scenario 2: cinquemila)" do
    it "il tetto è 5.000 occorrenze conservate per intero" do
      expect(Monitoring::Constants::TELEMETRY_FULL_FIDELITY_COUNT).to eq(5_000)
    end
  end

  # I quattro invarianti che si sarebbero rotti campionando le RIGHE invece del corpo.
  describe "invarianti che la riga tiene in piedi" do
    before { cap!(1) }

    it "l'idempotenza su event_id vale anche oltre il tetto" do
      record("e0")            # riempie fino al tetto
      record("ripetuto")      # oltre il tetto, riga spoglia
      record("ripetuto")      # replay: deve essere un no-op

      group = project.error_groups.sole
      expect(group.events_count).to eq(2)
      expect(group.events.count).to eq(2)
    end

    it "users_count continua a contare gli utenti distinti oltre il tetto" do
      record("e0", user: { "id" => "primo" })
      record("e1", user: { "id" => "secondo" })   # oltre il tetto

      expect(project.error_groups.sole.users_count).to eq(2)
    end

    it "gli istogrammi, che contano le occorrenze, le trovano tutte" do
      3.times { |i| record("e#{i}") }

      group = project.error_groups.sole
      counts = Errors::Group.buckets_for([ group.id ], "30m").fetch(group.id).sum { |b| b[:count] }
      expect(counts).to eq(3)
    end
  end

  describe "il monitoraggio non si morde più la coda durante una raffica" do
    # Due chiamanti scrivono su Rails.cache a ogni occorrenza — che in produzione è SQLite: la probe
    # dello spike (una scrittura) e Errors::Broadcast.refresh, che tocca DUE stream con una o due
    # scritture ciascuno. Da due a quattro per occorrenza: oltre un milione durante la raffica del
    # 2026-07-29, su un file già in lock, ed è quel lock che generava l'errore in arrivo.
    def spy_cache!
      allow(Rails.cache).to receive(:write).and_call_original
    end

    it "in raffica (grande E caldo) smette di sondare per lo spike" do
      cap!(1)
      now = Time.utc(2026, 7, 29, 12)
      record("e0", occurred: now)   # riempie il tetto, fissa last_seen_at

      spy_cache!
      record("e1", occurred: now + 1.second)   # a un secondo di distanza = raffica

      expect(Rails.cache).not_to have_received(:write).with(/errors:spike:probe/, anything, anything)
    end

    it "in raffica salta anche il segnale di refresh realtime, che è l'altra fonte di scritture" do
      cap!(1)
      now = Time.utc(2026, 7, 29, 12)
      record("e0", occurred: now)

      allow(Errors::Broadcast).to receive(:refresh)
      record("e1", occurred: now + 1.second)

      expect(Errors::Broadcast).not_to have_received(:refresh)
    end

    it "fuori dalla raffica il refresh realtime parte come prima" do
      cap!(1)
      now = Time.utc(2026, 7, 29, 12)
      record("e0", occurred: now)

      allow(Errors::Broadcast).to receive(:refresh)
      record("e1", occurred: now + 1.hour)   # cronico, non raffica

      expect(Errors::Broadcast).to have_received(:refresh)
    end

    it "in raffica il lavoro riparte un'occorrenza ogni N, non si spegne del tutto" do
      cap!(1)
      stub_const("Monitoring::Constants::TELEMETRY_BURST_WORK_EVERY", 3)
      now = Time.utc(2026, 7, 29, 12)
      record("e0", occurred: now)   # events_count → 1

      allow(Errors::Broadcast).to receive(:refresh)
      # events_count pre-bump 1,2 → salta; 3 → multiplo di 3, il lavoro si fa.
      record("e1", occurred: now + 1.second)
      record("e2", occurred: now + 2.seconds)
      record("e3", occurred: now + 3.seconds)

      expect(Errors::Broadcast).to have_received(:refresh).once
    end

    # Il bug che questo spec impedisce di rifare: `events_count` è CUMULATIVO. Gatando la probe sul solo
    # conteggio, un errore cronico che accumula cinquemila occorrenze in sei mesi perdeva la rilevazione
    # degli spike PER SEMPRE — proprio il gruppo che un giorno potrebbe esplodere.
    it "un gruppo grande ma NON in raffica continua a essere sondato" do
      cap!(1)
      now = Time.utc(2026, 7, 29, 12)
      record("e0", occurred: now)   # oltre il tetto, ma la prossima arriva molto dopo

      spy_cache!
      record("e1", occurred: now + 1.hour)   # un'ora dopo: cronico, non raffica

      expect(Rails.cache).to have_received(:write).with(/errors:spike:probe/, anything, anything)
    end

    it "sotto il tetto la sonda gira comunque, raffica o no" do
      cap!(100)
      now = Time.utc(2026, 7, 29, 12)
      record("e0", occurred: now)

      spy_cache!
      record("e1", occurred: now + 1.second)

      expect(Rails.cache).to have_received(:write).with(/errors:spike:probe/, anything, anything)
    end

    it "un evento arretrato (clock del client indietro) non viene letto come raffica" do
      cap!(1)
      now = Time.utc(2026, 7, 29, 12)
      record("e0", occurred: now)

      spy_cache!
      record("e1", occurred: now - 1.hour)   # delta negativo

      expect(Rails.cache).to have_received(:write).with(/errors:spike:probe/, anything, anything)
    end
  end
end
