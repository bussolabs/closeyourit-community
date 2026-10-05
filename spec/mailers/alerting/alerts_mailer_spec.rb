# frozen_string_literal: true

require "rails_helper"

RSpec.describe Alerting::AlertsMailer, type: :mailer do
  describe "#triggered" do
    let(:account) { create(:account, email: "owner@demo.test") }
    let(:notification) do
      create(:alerting_notification, :email, account: account,
             title: "New error · RuntimeError", body: "boom in checkout", url: "/member/monitoring/error/x")
    end

    it "è indirizzata al destinatario" do
      expect(described_class.triggered(notification).to).to eq([ account.email ])
    end

    it "ha un subject non vuoto (via i18n)" do
      expect(described_class.triggered(notification).subject).to be_present
    end

    it "tiene il subject su una riga sola anche se il titolo dell'allarme va a capo" do
      # La difesa vive in ApplicationMailer, non in questo mailer: qui si prova che
      # copre anche una sorgente diversa dal titolo di un ticket (CYRA-671).
      multiriga = create(:alerting_notification, :email, account: account,
                         title: "New error\nRuntimeError\r\nin checkout", body: "boom", url: "/x")
      subject = described_class.triggered(multiriga).subject
      expect(subject).not_to match(/[\r\n]/)
      expect(subject).to include("New error RuntimeError in checkout")
    end

    it "il corpo contiene il titolo snapshot della notifica" do
      body = described_class.triggered(notification).parts.map(&:decoded).join
      expect(body).to include("New error · RuntimeError")
    end

    it "renderizza senza errori (template path mails/alerting)" do
      expect { described_class.triggered(notification).parts.map(&:decoded).join }.not_to raise_error
    end

    it "l'HTML usa il frame condiviso (wordmark + footer)" do
      html = described_class.triggered(notification).html_part.decoded
      expect(html).to include("CloseYourIt")
      expect(html).to include("bug tracking")    # tagline del footer condiviso
    end

    it "applica l'accento semantico: rosso per un nuovo errore" do
      notification.update!(event_type: :error_new)
      html = described_class.triggered(notification).html_part.decoded
      expect(html).to include(MailerHelper::ACCENTS[:red])      # #dc2626 nella riga d'accento/pill
    end

    it "applica l'accento verde per un recovery uptime" do
      notification.update!(event_type: :uptime_up)
      html = described_class.triggered(notification).html_part.decoded
      expect(html).to include(MailerHelper::ACCENTS[:green])    # #16a34a
    end

    it "il pulsante HTML punta all'URL assoluto (host da default_url_options), non al path relativo" do
      html = described_class.triggered(notification).html_part.decoded
      expect(html).to include(%(href="http://example.com/member/monitoring/error/#{notification.subject_id}"))
    end

    it "la versione testuale contiene l'URL assoluto" do
      text = described_class.triggered(notification).text_part.decoded
      expect(text).to include("http://example.com/member/monitoring/error/#{notification.subject_id}")
    end
  end
end
