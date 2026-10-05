# frozen_string_literal: true

require "rails_helper"

# CYRA-539 — una misura di velocità, dal primo all'ultimo passo. Le decisioni che questo servizio
# porta sono quasi tutte NEGATIVE: cosa non cancellare, cosa non ritentare, cosa non nascondere.
RSpec.describe Seo::MeasureLab do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let(:environment) { create(:environment, organization:) }
  let(:site) do
    project.environments << environment
    project.project_platforms.create!(platform: create(:platform, organization:, supports_analytics: true))
    create(:seo_site, project:, environment:, base_url: "https://acme.example")
  end

  def risposta = JSON.parse(Rails.root.join("spec/fixtures/seo/pagespeed_success.json").read)

  def client_che(esito)
    doppio = instance_double(Seo::PageSpeed::Client)
    if esito.is_a?(StandardError)
      allow(doppio).to receive(:run).and_raise(esito)
    else
      allow(doppio).to receive(:run).and_return(esito)
    end
    doppio
  end

  # CYRA-546 — chi paga la misura è l'organizzazione del sito, non chi gestisce l'installazione.
  describe "la chiave con cui si misura" do
    it "è quella dell'organizzazione del sito" do
      create(:integration_credential, :pagespeed, organization:, api_key: "chiave-della-organizzazione")
      stub_request(:get, %r{pagespeedonline\.googleapis\.com})
        .to_return(status: 200, body: Rails.root.join("spec/fixtures/seo/pagespeed_success.json").read)

      run = described_class.call(site:, strategy: "mobile")

      expect(run).to be_status_completed
      expect(a_request(:get, %r{pagespeedonline\.googleapis\.com})
        .with { |req| req.uri.query.include?("key=chiave-della-organizzazione") }).to have_been_made
    end

    # Il dispatcher salta già le organizzazioni non collegate: qui si arriva solo se la chiave è
    # sparita fra l'accodamento e l'esecuzione. Non è un guasto del sito e non deve lasciarne
    # traccia: niente riga fallita, e la scadenza NON si sposta, così il sito riparte da solo appena
    # la chiave torna.
    it "senza collegamento non nasce nessuna riga e la scadenza resta dov'era" do
      site.update!(next_lab_run_at: 1.hour.ago)

      expect(described_class.call(site:, strategy: "mobile")).to be_nil
      expect(site.lab_runs.reload).to be_empty
      expect(site.reload.next_lab_run_at).to be < Time.current
      expect(site.last_lab_run_at).to be_nil
    end
  end

  it "scrive i numeri della misura e la porta a riuscita" do
    run = described_class.call(site:, strategy: "mobile", client: client_che(risposta))

    expect(run).to be_status_completed
    expect(run.performance_score).to eq(72)
    expect(run.field_lcp_ms).to eq(3_120)
    expect(run.finished_at).to be_present
    expect(site.reload.last_lab_error).to be_nil
    expect(site.next_lab_run_at).to be_present
  end

  # Un worker ucciso a metà deve lasciare una riga visibile, non il nulla: dal nulla non si capisce
  # se la misura non è mai partita o se è morta.
  it "la riga nasce prima della chiamata, in corso" do
    doppio = instance_double(Seo::PageSpeed::Client)
    allow(doppio).to receive(:run) do
      expect(site.lab_runs.reload.first).to be_status_running
      risposta
    end

    described_class.call(site:, strategy: "mobile", client: doppio)
  end

  describe "quando la misura fallisce" do
    let(:errore) do
      Seo::PageSpeed::Client::Error.new("giù", code: "R502-PAGESPEED-002", reason: "upstream_error")
    end

    # LA regola: i numeri buoni di ieri sono l'unica cosa che sappiamo. Cancellarli perché l'ultimo
    # tentativo è andato male vorrebbe dire perderla.
    it "non tocca la riga riuscita precedente" do
      buona = create(:seo_lab_run, :completed, site:, strategy: :mobile, started_at: 1.day.ago)

      described_class.call(site:, strategy: "mobile", client: client_che(errore))

      expect(buona.reload).to be_status_completed
      expect(buona.performance_score).to eq(72)
      expect(Seo::LabRun.last_completed("mobile")).to eq(buona)
    end

    it "resta in elenco col suo motivo, e il sito lo dichiara" do
      run = described_class.call(site:, strategy: "mobile", client: client_che(errore))

      expect(run).to be_nil
      expect(site.lab_runs.reload.first).to be_status_failed
      expect(site.lab_runs.first.error).to eq("upstream_error")
      expect(site.reload.last_lab_error).to eq("upstream_error")
    end

    # Senza questo, un sito che Google non raggiunge verrebbe ritentato a ogni giro del dispatcher —
    # cioè ogni ora, per sempre, bruciando quota per tutti gli altri.
    it "la prossima scadenza si scrive comunque" do
      described_class.call(site:, strategy: "mobile", client: client_che(errore))

      expect(site.reload.next_lab_run_at).to be_within(1.minute).of(site.next_lab_run_after)
    end

    # La quota è di CHI HA COLLEGATO la chiave, non dell'installazione (CYRA-546): l'interruttore
    # porta il nome dell'organizzazione, o la quota finita di una fermerebbe le misure di tutte.
    #
    # In test la cache è `:null_store` (niente si conserva): qui serve una cache vera, altrimenti il
    # controllo passerebbe qualunque cosa faccia il servizio.
    it "una quota esaurita alza l'interruttore della sola organizzazione del sito" do
      allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new)
      altra = create(:organization)
      quota = Seo::PageSpeed::Client::Error.new("finita", code: "R429-PAGESPEED-001", reason: "quota_exceeded")

      described_class.call(site:, strategy: "mobile", client: client_che(quota))

      expect(Rails.cache.read(Seo::PageSpeed::Constants.quota_exhausted_key(organization.id))).to be(true)
      expect(Rails.cache.read(Seo::PageSpeed::Constants.quota_exhausted_key(altra.id))).to be_nil
    end

    it "un guasto imprevisto non resta nascosto: la riga si chiude e l'errore risale" do
      esploso = client_che(ArgumentError.new("boom"))

      expect { described_class.call(site:, strategy: "mobile", client: esploso) }.to raise_error(ArgumentError)
      expect(site.lab_runs.reload.first).to be_status_failed
      expect(site.lab_runs.first.error).to eq("argument_error")
    end
  end

  # CYRA-824 — la misura arriva minuti dopo, su una pagina già aperta. Il segnale parte da dove il
  # giro si chiude davvero, riuscito o fallito che sia: è l'unico momento in cui la scheda ha
  # qualcosa di nuovo da dire.
  describe "il segnale a chi sta guardando la scheda" do
    let(:stream) { Realtime::Streams.seo_site(site) }

    it "parte quando la misura riesce" do
      expect { described_class.call(site:, strategy: "mobile", client: client_che(risposta)) }
        .to have_broadcasted_to(stream).at_least(:once)
    end

    it "parte anche quando la misura fallisce" do
      errore = Seo::PageSpeed::Client::Error.new("giù", code: "R502-PAGESPEED-002", reason: "upstream_error")

      expect { described_class.call(site:, strategy: "mobile", client: client_che(errore)) }
        .to have_broadcasted_to(stream).at_least(:once)
    end

    # Il segnale parte da DENTRO il `rescue StandardError` che porta la riga a fallita: se un guasto
    # del trasporto risalisse, una misura già scritta come riuscita verrebbe ribaltata in fallita e
    # i numeri appena arrivati passerebbero per vecchi. Avvisare chi guarda non è parte della misura.
    it "un guasto del segnale non fa risultare fallita una misura riuscita" do
      allow(Realtime::ThrottledRefresh).to receive(:call).and_raise(IOError.new("cable giù"))

      run = nil
      expect { run = described_class.call(site:, strategy: "mobile", client: client_che(risposta)) }
        .not_to raise_error

      expect(run).to be_status_completed
      expect(site.reload.last_lab_error).to be_nil
    end

    # Senza collegamento non è successo niente: nessuna riga, nessuna scadenza spostata, e quindi
    # nemmeno un segnale che farebbe ri-chiedere una scheda identica a prima.
    it "senza collegamento non parte nessun segnale" do
      site.update!(next_lab_run_at: 1.hour.ago)

      expect { described_class.call(site:, strategy: "mobile") }.not_to have_broadcasted_to(stream)
    end
  end
end
