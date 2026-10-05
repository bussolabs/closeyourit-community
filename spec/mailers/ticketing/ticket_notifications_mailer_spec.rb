# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ticketing::TicketNotificationsMailer, type: :mailer do
  describe "#notify" do
    let(:account) { create(:account, email: "watcher@demo.test") }
    let(:organization) { create(:organization) }
    let(:project) { create(:project, organization: organization, key: "STR") }
    let(:ticket) { create(:ticket, organization: organization, project: project, title: "Login broken") }
    let(:notification) do
      create(:alerting_notification, :email, account: account, organization: organization, project: project,
                                             subject: ticket, event_type: :ticket_status_changed,
                                             title: "#{ticket.code}: Open → In progress", body: ticket.title,
                                             url: "/member/tickets/#{ticket.id}")
    end

    it "è indirizzata al destinatario" do
      expect(described_class.notify(notification).to).to eq([ account.email ])
    end

    it "ha un subject con codice e titolo del ticket (via i18n)" do
      subject = described_class.notify(notification).subject
      expect(subject).to include(ticket.code)
      expect(subject).to include("Login broken")
    end

    context "quando il titolo del ticket contiene un a capo" do
      # Resend rifiuta l'intera spedizione: "The `\n` is not allowed in the `subject` field."
      # In produzione ha bloccato 3.718 invii in diciotto giorni (CYRA-671).
      let(:ticket) do
        create(:ticket, organization: organization, project: project,
                        title: "Login rotto\nsu Safari\r\ne su Firefox")
      end

      it "manda un subject su una riga sola" do
        subject = described_class.notify(notification).subject
        expect(subject).not_to include("\n")
        expect(subject).not_to include("\r")
      end

      it "non perde le parole, le unisce con uno spazio" do
        expect(described_class.notify(notification).subject).to include("Login rotto su Safari e su Firefox")
      end
    end

    it "il corpo contiene il titolo snapshot e il codice del ticket" do
      body = described_class.notify(notification).parts.map(&:decoded).join
      expect(body).to include("#{ticket.code}: Open → In progress")
      expect(body).to include(ticket.code)
    end

    it "renderizza senza errori (template path mails/ticketing)" do
      expect { described_class.notify(notification).parts.map(&:decoded).join }.not_to raise_error
    end

    it "l'HTML usa il frame condiviso (wordmark + footer)" do
      html = described_class.notify(notification).html_part.decoded
      expect(html).to include("CloseYourIt")
      expect(html).to include("bug tracking")
    end

    it "il pulsante HTML punta all'URL assoluto (host da default_url_options), non al path relativo" do
      html = described_class.notify(notification).html_part.decoded
      expect(html).to include(%(href="http://example.com/member/tickets/#{ticket.id}"))
    end

    it "la versione testuale contiene l'URL assoluto" do
      text = described_class.notify(notification).text_part.decoded
      expect(text).to include("http://example.com/member/tickets/#{ticket.id}")
    end
  end
end
