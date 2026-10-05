# frozen_string_literal: true

require "rails_helper"

# CYRA-736 — la sequenza con cui si registra un dato RAGGRUPPATO vive qui e in nessun altro posto.
#
# Errori e performance fanno gli stessi cinque passi: trova o crea il gruppo dall'impronta, decide il
# tetto sul contatore PRIMA che si muova, scrive la riga, aggiorna gli aggregati, registra la fonte
# osservata. Prima la sequenza era scritta due volte, e una correzione al tetto o al tracciamento
# dell'origine andava fatta in entrambe le copie.
#
# Quello che segue prova due cose diverse e complementari: che i passi hanno UN solo proprietario
# (nessun dominio se ne è ricopiato uno) e che, passando di lì, i due domini si comportano come prima.
RSpec.describe Ingest::GroupedRecord, type: :service do
  let(:project) { create(:project) }

  # I due domini a dato raggruppato, elencati a mano e NON letti dalle dichiarazioni delle classi: un
  # catalogo che verifica sé stesso non si accorgerebbe di una riga cambiata per sbaglio.
  def domains
    {
      errors: { service: Errors::Ingest::Record, groups: :error_groups, occurrences: :error_events,
                key: :event_id, counter: :events_count },
      metrics: { service: Metrics::Ingest::Record, groups: :metric_groups, occurrences: :metric_samples,
                 key: :sample_id, counter: :samples_count }
    }
  end

  # I passi della sequenza. Se un dominio ne ridefinisce uno, il proprietario non è più questa classe
  # e l'esempio qui sotto lo dice per nome: è esattamente la ricaduta che il ticket chiede di impedire.
  def sequence_steps
    %i[already_recorded upsert_group over_cap? over_cap_at? store_occurrence track_source track_source_batch]
  end

  describe "la sequenza ha un solo proprietario" do
    it "nessuno dei due domini si ricopia un passo" do
      domains.each do |name, domain|
        sequence_steps.each do |step|
          owner = domain[:service].instance_method(step).owner
          expect(owner).to eq(described_class), "#{name}: #{step} è ricopiato in #{owner}, non ereditato"
        end
      end
    end

    it "ogni dominio dichiara soltanto dove vivono i suoi gruppi, le sue righe, la sua chiave e il suo contatore" do
      domains.each do |name, domain|
        shape = domain[:service].shape
        expect(shape.groups).to eq(domain[:groups]), "#{name}: gruppi"
        expect(shape.occurrences).to eq(domain[:occurrences]), "#{name}: righe"
        expect(shape.key).to eq(domain[:key]), "#{name}: chiave idempotente"
        expect(shape.counter).to eq(domain[:counter]), "#{name}: contatore del tetto"
      end
    end

    # Un dominio nuovo che si scorda la dichiarazione deve fermarsi subito, non ereditare in silenzio
    # le associazioni di un altro.
    it "una classe che non dichiara il proprio dominio non parte nemmeno" do
      anonima = Class.new(described_class)

      expect { anonima.shape }.to raise_error(NotImplementedError)
    end
  end

  # Scenario 1 del ticket: la regola del tetto si corregge in un punto solo e vale per entrambi.
  describe "il tetto" do
    it "è la stessa regola e la stessa soglia per entrambi i domini" do
      stub_const("Monitoring::Constants::TELEMETRY_FULL_FIDELITY_COUNT", 3)

      domains.each do |name, domain|
        service = domain[:service].new(project: project)
        expect(service.send(:over_cap_at?, 2)).to be(false), "#{name}: sotto il tetto"
        expect(service.send(:over_cap_at?, 3)).to be(true), "#{name}: al tetto"
        expect(service.send(:over_cap_at?, 4)).to be(true), "#{name}: oltre il tetto"
      end
    end

    # Il contatore è l'unica cosa che cambia fra i due: gli errori contano gli eventi, le performance
    # i campioni. La regola che li confronta con la soglia è la stessa.
    it "legge il contatore dichiarato dal dominio" do
      stub_const("Monitoring::Constants::TELEMETRY_FULL_FIDELITY_COUNT", 2)
      error_group = create(:error_group, project: project, events_count: 5)
      metric_group = create(:metric_group, project: project, samples_count: 1)

      expect(Errors::Ingest::Record.new(project: project).send(:over_cap?, error_group)).to be(true)
      expect(Metrics::Ingest::Record.new(project: project).send(:over_cap?, metric_group)).to be(false)
    end
  end

  describe "la ricerca della riga già registrata (idempotenza)" do
    it "cerca sulla chiave dichiarata dal dominio, dentro il progetto" do
      event = create(:error_event, group: create(:error_group, project: project), event_id: "evento-noto")
      sample = create(:metric_sample, group: create(:metric_group, project: project), sample_id: "campione-noto")

      expect(Errors::Ingest::Record.new(project: project).send(:already_recorded, "evento-noto")).to eq(event)
      expect(Metrics::Ingest::Record.new(project: project).send(:already_recorded, "campione-noto")).to eq(sample)
    end

    it "una chiave mai vista non trova niente, per entrambi i domini" do
      domains.each do |name, domain|
        service = domain[:service].new(project: project)
        expect(service.send(:already_recorded, "mai-vista")).to be_nil, "#{name}: chiave sconosciuta"
      end
    end
  end

  describe "trova o crea il gruppo" do
    [ :errors, :metrics ].each do |name|
      it "recupera il gruppo #{name} creato fra lettura e validazione" do
        domain = domains.fetch(name)
        payload = name == :errors ? error_payload("race") : metric_payload("race")
        domain[:service].call(project: project, payload: payload)
        group = project.public_send(domain[:groups]).sole
        service = domain[:service].new(project: project)
        normalized = (name == :errors ? Errors::Ingest::Normalize : Metrics::Ingest::Normalize).call(payload: payload)
        scope = project.public_send(domain[:groups])
        allow(service).to receive(:groups).and_return(scope)
        # La create esegue davvero la validazione contro la riga concorrente.
        allow(scope).to receive(:find_or_create_by!).and_wrap_original do |_original, attributes, &block|
          scope.create!(attributes, &block)
        end

        expect(service.send(:upsert_group, group.fingerprint, normalized)).to eq(group)
        expect(scope.count).to eq(1)
      end
    end

    it "non nasconde altre validazioni quando l'impronta è duplicata" do
      payload = error_payload("invalid")
      Errors::Ingest::Record.call(project: project, payload: payload)
      group = project.error_groups.sole
      service = Errors::Ingest::Record.new(project: project)
      scope = project.error_groups
      allow(service).to receive(:groups).and_return(scope)
      allow(scope).to receive(:find_or_create_by!) do |attributes|
        scope.create!(attributes.merge(title: nil))
      end

      expect {
        service.send(:upsert_group, group.fingerprint, Errors::Ingest::Normalize.call(payload: payload))
      }.to raise_error(ActiveRecord::RecordInvalid)
    end

    it "la prima impronta crea il gruppo, la seconda lo ritrova, per entrambi i domini" do
      Errors::Ingest::Record.call(project: project, payload: error_payload("uno"))
      Errors::Ingest::Record.call(project: project, payload: error_payload("due"))
      Metrics::Ingest::Record.call(project: project, payload: metric_payload("uno"))
      Metrics::Ingest::Record.call(project: project, payload: metric_payload("due"))

      expect(project.error_groups.count).to eq(1)
      expect(project.error_groups.sole.events_count).to eq(2)
      expect(project.metric_groups.count).to eq(1)
      expect(project.metric_groups.sole.samples_count).to eq(2)
    end
  end

  # Scenario 1, esito atteso: «i due domini si comportano come prima». La sequenza passa di qui, ma
  # ciascuno continua a scrivere i propri aggregati con le proprie regole.
  describe "i due domini si comportano come prima" do
    it "gli errori tengono il proprio conteggio e il proprio ultimo avvistamento" do
      istante = 2.hours.ago.change(usec: 0)
      Errors::Ingest::Record.call(project: project, payload: error_payload("uno", occurred: istante))

      group = project.error_groups.sole
      expect(group.events_count).to eq(1)
      expect(group.last_seen_at).to be_within(1.second).of(istante)
      expect(group.events.sole.event_id).to eq("uno")
    end

    it "le performance tengono i propri aggregati di durata" do
      Metrics::Ingest::Record.call(project: project, payload: metric_payload("uno", duration_ms: 90.0))
      Metrics::Ingest::Record.call(project: project, payload: metric_payload("due", duration_ms: 310.0))

      group = project.metric_groups.sole
      expect(group.samples_count).to eq(2)
      expect(group.duration_min_ms).to eq(90.0)
      expect(group.duration_max_ms).to eq(310.0)
      expect(group.duration_total_ms).to eq(400.0)
    end

    it "oltre il tetto entrambi scrivono la riga e buttano il corpo" do
      stub_const("Monitoring::Constants::TELEMETRY_FULL_FIDELITY_COUNT", 1)
      2.times { |i| Errors::Ingest::Record.call(project: project, payload: error_payload("e#{i}")) }
      2.times { |i| Metrics::Ingest::Record.call(project: project, payload: metric_payload("m#{i}")) }

      expect(project.error_groups.sole.events.order(:created_at).last.payload).to eq({})
      expect(project.metric_groups.sole.samples.order(:created_at).last.payload).to eq({})
    end
  end

  # Il secondo pezzo che la description del ticket cita: il tracciamento dell'origine.
  describe "la fonte osservata" do
    it "entrambi i domini registrano lo strumento che ha mandato il dato" do
      Errors::Ingest::Record.call(project: project, payload: error_payload("uno").merge("sdk" => { "name" => "closeyourit-ruby", "version" => "1.0.0" }))

      expect(project.sources.sole.tool_code).to eq("closeyourit-ruby")

      Metrics::Ingest::Record.call(project: project, payload: metric_payload("uno").merge("sdk" => { "name" => "closeyourit-js", "version" => "2.0.0" }))

      expect(project.sources.map(&:tool_code)).to contain_exactly("closeyourit-ruby", "closeyourit-js")
    end
  end

  def error_payload(event_id, occurred: Time.current)
    {
      "event_id" => event_id,
      "level" => "error",
      "timestamp" => occurred.to_f,
      "exception" => { "values" => [ {
        "type" => "RuntimeError", "value" => "boom",
        "stacktrace" => { "frames" => [ { "module" => "App", "function" => "call", "in_app" => true } ] }
      } ] }
    }
  end

  def metric_payload(sample_id, duration_ms: 120.0)
    {
      "kind" => "slow_query",
      "sample_id" => sample_id,
      "duration_ms" => duration_ms,
      "occurred_at" => Time.current.iso8601,
      "environment" => "production",
      "sql" => "SELECT * FROM users WHERE id = 42"
    }
  end
end
