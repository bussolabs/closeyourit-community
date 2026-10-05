# frozen_string_literal: true

require "rails_helper"

RSpec.describe Secrets::SecretNotificationsMailer, type: :mailer do
  describe "#notify" do
    let(:account) { create(:account, email: "manager@demo.test") }
    let(:organization) { create(:organization) }
    let(:project) { create(:project, organization: organization, key: "STR") }
    let(:environment) do
      create(:environment, organization: organization, label: "Production").tap { |e| project.environments << e }
    end
    let(:variable) do
      create(:secret_variable, project: project, environment: environment, name: "API_KEY",
                               rotation_interval_days: 1, rotated_at: Time.current - 2.days)
    end
    let(:notification) do
      create(:alerting_notification, :email, account: account, organization: organization, project: project,
                                             subject: variable, event_type: :secret_rotation_due,
                                             title: "Il secret API_KEY del progetto #{project.name} (Production) va ruotato",
                                             body: "scaduto da 1g", url: "/member/vault/rotation")
    end

    it "è indirizzata al destinatario" do
      expect(described_class.notify(notification).to).to eq([ account.email ])
    end

    it "ha un subject non vuoto (via i18n)" do
      expect(described_class.notify(notification).subject).to be_present
    end

    it "il corpo contiene il titolo snapshot e il nome della variabile" do
      body = described_class.notify(notification).parts.map(&:decoded).join
      expect(body).to include(notification.title)
      expect(body).to include("API_KEY")
    end

    it "il corpo NON contiene mai il valore del secret" do
      body = described_class.notify(notification).parts.map(&:decoded).join
      expect(body).not_to include(variable.value)
    end

    it "renderizza senza errori (template path mails/secrets)" do
      expect { described_class.notify(notification).parts.map(&:decoded).join }.not_to raise_error
    end

    it "l'HTML usa il frame condiviso (wordmark + footer)" do
      html = described_class.notify(notification).html_part.decoded
      expect(html).to include("CloseYourIt")
      expect(html).to include("bug tracking")
    end

    it "il pulsante HTML punta all'URL assoluto (host da default_url_options), non al path relativo" do
      html = described_class.notify(notification).html_part.decoded
      expect(html).to include(%(href="http://example.com#{Rails.application.routes.url_helpers.member_vault_attention_path}"))
    end

    it "la versione testuale contiene l'URL assoluto" do
      text = described_class.notify(notification).text_part.decoded
      expect(text).to include("http://example.com#{Rails.application.routes.url_helpers.member_vault_attention_path}")
    end
  end

  describe "#notify con subject = progetto (CYRA-138 Fase B: secret_deleted/secret_sync_failed, variabile assente)" do
    let(:account) { create(:account, email: "manager@demo.test") }
    let(:organization) { create(:organization) }
    let(:project) { create(:project, organization: organization, key: "STR") }
    let(:notification) do
      create(:alerting_notification, :email, account: account, organization: organization, project: project,
                                             subject: project, event_type: :secret_deleted,
                                             title: "Il secret API_KEY (progetto #{project.name}, ambiente Production) " \
                                                    "è stato cancellato da Mario Rossi",
                                             body: "Il secret non è più disponibile in questo ambiente.",
                                             url: "/member/projects/#{project.id}/secrets")
    end

    it "renderizza senza errori quando il subject non è una Secrets::Variable (niente @variable.environment)" do
      expect { described_class.notify(notification).parts.map(&:decoded).join }.not_to raise_error
    end

    it "il corpo contiene il titolo snapshot (nome/progetto/ambiente/attore già dentro il Content)" do
      body = described_class.notify(notification).parts.map(&:decoded).join
      expect(body).to include(notification.title)
    end

    it "il corpo NON mostra la pill/riga ambiente dedicata alla variabile (assente, già distrutta)" do
      body = described_class.notify(notification).html_part.decoded
      expect(body).not_to include(">Production<")
    end

    it "il meta-box mostra comunque il progetto (generico, non dipende dalla variabile)" do
      body = described_class.notify(notification).html_part.decoded
      expect(body).to include(project.key).and include(project.name)
    end
  end
end
