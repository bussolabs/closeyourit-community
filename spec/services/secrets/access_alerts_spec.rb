# frozen_string_literal: true

require "rails_helper"

# CYRA-77 — l'accesso a un segreto sensibile finiva in un registro che nessuno apriva mai: la lettura
# della chiave di produzione era indistinguibile da un download di routine finché qualcuno non andava
# a cercarla. Da qui parte un avviso, con due paletti: solo dove esiste una regola che lo chiede, e
# mai per le letture programmatiche del terminale (una pipeline che gira ogni cinque minuti
# spegnerebbe l'attenzione di chiunque nel giro di un giorno).
RSpec.describe "Secrets — avvisi sugli accessi (CYRA-77)" do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let(:production) { create(:environment, organization:, code: "production").tap { |e| project.environments << e } }
  let(:staging) { create(:environment, organization:, code: "staging").tap { |e| project.environments << e } }
  let(:actor) { create(:account) }

  describe "Secrets::RecordEvent — chi accoda la valutazione" do
    it "una lettura dal sito accoda la valutazione delle regole" do
      expect do
        Secrets::RecordEvent.call(action: "read", project:, environment: production, actor:,
                                  name: "API_KEY", channel: "web")
      end.to have_enqueued_job(Alerting::EvaluateJob).with(
        hash_including(event_type: "secret_read", subject_type: "Secrets::Event",
                       project_id: project.id, environment_id: production.id)
      )
    end

    it "un tentativo bloccato dal sito accoda la valutazione" do
      expect do
        Secrets::RecordEvent.call(action: "denied", project:, environment: production, actor:,
                                  name: "API_KEY", channel: "web")
      end.to have_enqueued_job(Alerting::EvaluateJob).with(
        hash_including(event_type: "secret_denied")
      )
    end

    # Il paletto anti-rumore: `cyi run` legge il vault a ogni avvio di un processo.
    it "la stessa lettura dal terminale NON accoda niente" do
      expect do
        Secrets::RecordEvent.call(action: "read", project:, environment: production, actor:,
                                  name: "API_KEY", channel: "cli")
      end.not_to have_enqueued_job(Alerting::EvaluateJob)
    end

    it "le scritture non accodano niente (l'avviso è sugli accessi, non sulle modifiche)" do
      expect do
        Secrets::RecordEvent.call(action: "set", project:, environment: production, actor:, name: "API_KEY",
                                  channel: "web")
      end.not_to have_enqueued_job(Alerting::EvaluateJob)
    end

    # Un evento che non si è potuto scrivere non è successo: accodare comunque farebbe partire un
    # avviso senza la riga d'audit a cui punta, e Evaluate cadrebbe su un subject inesistente.
    it "se l'audit fallisce non parte alcun avviso" do
      allow(Secrets::Event).to receive(:create!).and_raise(ActiveRecord::StatementInvalid, "boom")

      expect do
        Secrets::RecordEvent.call(action: "read", project:, environment: production, actor:,
                                  name: "API_KEY", channel: "web")
      end.not_to have_enqueued_job(Alerting::EvaluateJob)
    end
  end

  describe "Alerting::Content" do
    it "la lettura dice chi, quale segreto e dove" do
      event = Secrets::RecordEvent.call(action: "read", project:, environment: production, actor:,
                                        name: "API_KEY", channel: "web")

      content = Alerting::Content.for(event_type: "secret_read", subject: event)

      expect(content.title).to include("API_KEY")
      expect(content.body).to include(actor.email).and include(production.label)
      expect(content.project).to eq(project)
      expect(content.url).to eq(Rails.application.routes.url_helpers.member_project_secret_events_path(project))
    end

    it "il tentativo bloccato si legge come tale" do
      event = Secrets::RecordEvent.call(action: "denied", project:, environment: production, actor:,
                                        name: "API_KEY", channel: "web")

      content = Alerting::Content.for(event_type: "secret_denied", subject: event)

      expect(content.title).to include("API_KEY")
      expect(content.body).to include(actor.email)
    end

    it "un accesso senza attore né nome non lascia buchi nel testo" do
      event = Secrets::RecordEvent.call(action: "read", project:, environment: nil, actor: nil, channel: "web")

      content = Alerting::Content.for(event_type: "secret_read", subject: event)

      expect(content.title).to be_present
      expect(content.body).to be_present
      expect(content.body).not_to include("translation missing")
    end

    # Il valore è l'unica cosa che non deve mai uscire da qui: title/body finiscono in una notifica
    # in-app, in un'email e magari su un webhook esterno.
    it "non porta MAI il valore del segreto" do
      Secrets::Variables::Set.call(project:, environment: production, name: "API_KEY", value: "PLAINTEXT-CANARY")
      event = Secrets::RecordEvent.call(action: "read", project:, environment: production, actor:,
                                        name: "API_KEY", channel: "web")

      content = Alerting::Content.for(event_type: "secret_read", subject: event)

      expect([ content.title, content.body ].join(" ")).not_to include("PLAINTEXT-CANARY")
    end
  end

  describe "Alerting::Evaluate — dalla regola alla notifica" do
    let(:owner) { create(:account) }

    before { create(:membership, account: owner, organization:, role: :owner) }

    def read_event(environment:, channel: "web")
      Secrets::RecordEvent.call(action: "read", project:, environment:, actor:, name: "API_KEY", channel:)
    end

    def evaluate(event, event_type: "secret_read")
      Alerting::Evaluate.call(event_type:, subject_type: "Secrets::Event", subject_id: event.id,
                              project_id: project.id, environment_id: event.environment_id)
    end

    it "una regola secret_read su production avvisa chi gestisce i segreti" do
      create(:alerting_rule, organization:, event_type: :secret_read, environment: production)

      expect { evaluate(read_event(environment: production)) }
        .to change { Alerting::Notification.where(account: owner, event_type: "secret_read", via: :in_app).count }.by(1)
    end

    it "la stessa regola tace su un altro ambiente" do
      create(:alerting_rule, organization:, event_type: :secret_read, environment: production)

      expect { evaluate(read_event(environment: staging)) }
        .not_to change { Alerting::Notification.count }
    end

    it "senza regole non arriva niente" do
      expect { evaluate(read_event(environment: production)) }.not_to change { Alerting::Notification.count }
    end

    # Chi consuma i segreti non deve ricevere l'avviso che qualcun altro li ha letti: la lista è
    # quella di chi ne risponde, la stessa dell'approvazione a due.
    it "chi vede il progetto ma non gestisce i segreti non riceve l'avviso" do
      spettatore = create(:account)
      create(:membership, account: spettatore, organization:, role: :member)
      create(:project_membership, account: spettatore, project:)
      create(:alerting_rule, organization:, event_type: :secret_read, environment: production)

      evaluate(read_event(environment: production))

      expect(Alerting::Notification.where(account: spettatore)).not_to exist
    end

    it "il tentativo bloccato ha la sua regola" do
      create(:alerting_rule, organization:, event_type: :secret_denied)
      event = Secrets::RecordEvent.call(action: "denied", project:, environment: production, actor:,
                                        name: "API_KEY", channel: "web")

      expect { evaluate(event, event_type: "secret_denied") }
        .to change { Alerting::Notification.where(event_type: "secret_denied", via: :in_app).count }.by(1)
    end
  end

  # Il form delle regole nasconde progetto e ambiente per gli avvisi che non ne hanno (macchine,
  # agenti): questi due invece vivono di scoping — «avvisami sulle letture di PRODUCTION» è
  # esattamente il caso d'uso, e senza i campi non si può nemmeno esprimere.
  describe "Alerting::Rule.fields_for" do
    it "gli avvisi sugli accessi ai segreti si possono restringere a progetto e ambiente" do
      expect(Alerting::Rule.fields_for("secret_read")).to include("project_id", "environment_id")
      expect(Alerting::Rule.fields_for("secret_denied")).to include("project_id", "environment_id")
    end
  end
end
