# frozen_string_literal: true

require "rails_helper"

RSpec.describe Monitoring::Retention do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }

  # I cinque domini con livello progetto: attributo (omonimo sui tre livelli), default di sistema e
  # il modulo di dominio che lo espone. Elencati a mano di proposito, NON letti da DOMAINS: un
  # catalogo che verifica sé stesso non si accorgerebbe di una riga cambiata per sbaglio.
  def project_domains
    {
      logs: { attribute: :logs_retention_days, default: Logs::Constants::RETENTION_DEFAULT_DAYS, facade: Logs::Retention },
      analytics: { attribute: :analytics_retention_days, default: Analytics::Constants::RETENTION_DEFAULT_DAYS, facade: Analytics::Retention },
      errors: { attribute: :errors_retention_days, default: Errors::Constants::RETENTION_DEFAULT_DAYS, facade: Errors::Retention },
      metrics: { attribute: :performance_retention_days, default: Metrics::Constants::RETENTION_DEFAULT_DAYS, facade: Metrics::Retention },
      uptime: { attribute: :uptime_retention_days, default: Uptime::Constants::RETENTION_DEFAULT_DAYS, facade: Uptime::Retention }
    }
  end

  describe ".for (domini con livello progetto)" do
    it "il livello più vicino con un valore positivo vince, per ognuno dei cinque domini" do
      project_domains.each do |key, domain|
        Settings::Global.instance.update!(domain[:attribute] => 10)
        organization.update!(domain[:attribute] => 20)
        project.update!(domain[:attribute] => 30)
        expect(described_class.for(project, key: key)).to eq(30), "#{key}: il progetto deve vincere"

        project.update!(domain[:attribute] => nil)
        expect(described_class.for(project, key: key)).to eq(20), "#{key}: senza progetto vince l'org"

        organization.update!(domain[:attribute] => nil)
        expect(described_class.for(project, key: key)).to eq(10), "#{key}: senza org vince il globale"

        expect(described_class.for(project, key: key, global_days: nil)).to eq(domain[:default]),
                                                                            "#{key}: senza nessun livello resta il default di sistema"
      end
    end

    it "un valore blank a un livello eredita dal superiore, per ognuno dei cinque domini" do
      project_domains.each do |key, domain|
        Settings::Global.instance.update!(domain[:attribute] => 10)
        organization.update!(domain[:attribute] => 20)
        project.update!(domain[:attribute] => "")
        expect(described_class.for(project, key: key)).to eq(20), "#{key}: un valore vuoto non è una scelta"
      end
    end

    it "usa il globale già risolto dal chiamante invece di rileggerlo" do
      expect(described_class.for(project, key: :logs, global_days: 21)).to eq(21)
    end

    it "non legge la configurazione globale quando il livello più vicino decide già" do
      project.update!(logs_retention_days: 7)
      expect(Settings::Global).not_to receive(:instance)
      expect(described_class.for(project, key: :logs)).to eq(7)
    end
  end

  describe ".for (domini org-scoped)" do
    # I campioni dei server sono org-scoped nel data model (CYRA-159): il livello progetto non
    # esiste e lo scope ricevuto è già l'organizzazione.
    it "l'org vince sul globale, e senza nessuno dei due resta il default di sistema" do
      Settings::Global.instance.update!(servers_retention_days: 30)
      organization.update!(servers_retention_days: 15)
      expect(described_class.for(organization, key: :servers)).to eq(15)

      organization.update!(servers_retention_days: nil)
      expect(described_class.for(organization, key: :servers)).to eq(30)
      expect(described_class.for(organization, key: :servers, global_days: nil))
        .to eq(Servers::Constants::RETENTION_DEFAULT_DAYS)
    end
  end

  describe ".for (uniformità della regola)" do
    it "un globale pre-risolto a zero o negativo eredita il default invece di azzerare la conservazione" do
      # Zero giorni non è «tieni zero giorni»: è un valore mancante. Prima quattro domini su sei lo
      # prendevano alla lettera e avrebbero potato TUTTO, uno lo ereditava. Ora è una regola sola.
      expect(described_class.for(project, key: :errors, global_days: 0))
        .to eq(Errors::Constants::RETENTION_DEFAULT_DAYS)
      expect(described_class.for(project, key: :errors, global_days: -5))
        .to eq(Errors::Constants::RETENTION_DEFAULT_DAYS)
      expect(described_class.for(organization, key: :servers, global_days: 0))
        .to eq(Servers::Constants::RETENTION_DEFAULT_DAYS)
    end

    it "una chiave fuori catalogo solleva invece di inventare una conservazione" do
      expect { described_class.for(project, key: :inesistente) }.to raise_error(KeyError)
    end
  end

  describe ".resolve" do
    it "intero positivo o nil (zero/blank/negativo → eredita)" do
      expect(described_class.resolve(10)).to eq(10)
      expect(described_class.resolve("15")).to eq(15)
      expect(described_class.resolve(0)).to be_nil
      expect(described_class.resolve(-1)).to be_nil
      expect(described_class.resolve(nil)).to be_nil
      expect(described_class.resolve("")).to be_nil
    end
  end

  describe "i sei domini" do
    # Lo scenario del ticket: la regola cambia in un punto solo e vale per tutti e sei. Se un
    # dominio tornasse a ricopiarsi la catena, qui resterebbe col proprio numero.
    it "leggono tutti la stessa regola" do
      allow(described_class).to receive(:for).and_return(99)

      expect(Logs::Retention.for(project)).to eq(99)
      expect(Analytics::Retention.for(project)).to eq(99)
      expect(Errors::Retention.for(project)).to eq(99)
      expect(Metrics::Retention.for(project)).to eq(99)
      expect(Uptime::Retention.for(project)).to eq(99)
      expect(Servers::Retention.for(organization)).to eq(99)
    end

    it "chiedono la propria chiave, e il globale pre-risolto arriva intatto" do
      project_domains.each do |key, domain|
        expect(described_class).to receive(:for).with(project, key: key, global_days: 21).and_return(7)
        expect(domain[:facade].for(project, global_days: 21)).to eq(7)
      end

      expect(described_class).to receive(:for).with(organization, key: :servers, global_days: 21).and_return(7)
      expect(Servers::Retention.for(organization, global_days: 21)).to eq(7)
    end
  end

  # CYRA-750 — la finestra più lunga in vigore, che dice quando una FETTA intera è staccabile. Non è
  # la finestra di un cliente: è il limite oltre il quale nessuno ha più diritto a niente.
  describe ".longest" do
    it "vince il valore più alto dichiarato a qualunque livello" do
      Settings::Global.instance.update!(logs_retention_days: 10)
      organization.update!(logs_retention_days: 40)
      project.update!(logs_retention_days: 25)

      expect(described_class.longest(key: :logs)).to eq(40)
    end

    it "vale anche quando il valore più alto è quello di un singolo progetto" do
      Settings::Global.instance.update!(logs_retention_days: 10)
      project.update!(logs_retention_days: 200)

      expect(described_class.longest(key: :logs)).to eq(200)
    end

    # Il default di sistema è la finestra di chi non ha scelto niente e resta sempre nel conto: è la
    # metà prudente della regola. Il prezzo è tenere una fetta qualche giorno più del necessario; il
    # prezzo dell'errore opposto sarebbe buttare dati che qualcuno doveva ancora avere.
    it "non scende mai sotto il default di sistema" do
      Settings::Global.instance.update!(logs_retention_days: 1)

      expect(described_class.longest(key: :logs)).to eq(Logs::Constants::RETENTION_DEFAULT_DAYS)
    end

    # I campioni dei server non hanno livello progetto: la catena parte dall'organizzazione.
    it "per i domini senza livello progetto guarda solo organizzazioni e globale" do
      organization.update!(servers_retention_days: 90)

      expect(described_class.longest(key: :servers)).to eq(90)
    end

    it "accetta il globale già risolto, come .for" do
      Settings::Global.instance.update!(logs_retention_days: 10)

      expect(described_class.longest(key: :logs, global_days: 400)).to eq(400)
    end

    it "una preferenza scritta con un valore non numerico non fa cadere il conto" do
      project.update_column(:preferences, project.preferences.merge("logs_retention_days" => "sempre"))

      expect { described_class.longest(key: :logs) }.not_to raise_error
    end
  end
end
