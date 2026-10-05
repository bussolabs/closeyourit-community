# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Email agli account di servizio", type: :mailer do
  let(:service_account) { create(:account, :service) }
  let(:human) { create(:account) }

  [ Alerting::AlertsMailer, Secrets::SecretNotificationsMailer ].each do |mailer|
    it "#{mailer} non spedisce una notifica già accodata a un service account" do
      notification = create(:alerting_notification, :email, account: service_account, status: :pending)
      action = mailer == Alerting::AlertsMailer ? :triggered : :notify

      expect do
        perform_enqueued_jobs { mailer.public_send(action, notification).deliver_later }
      end.not_to change(ActionMailer::Base.deliveries, :count)
      expect(notification.reload).not_to be_status_sent
      expect(notification.delivered_at).to be_nil
    end
  end

  it "consegna normalmente agli utenti umani" do
    expect do
      Ops::ProbeMailer.probe(human.email, "Prova", "Contenuto").deliver_now
    end.to change(ActionMailer::Base.deliveries, :count).by(1)
    expect(ActionMailer::Base.deliveries.last.to).to eq([ human.email ])
  end

  it "preserva gli umani in un invio misto e confronta gli indirizzi senza distinzione di maiuscole" do
    expect do
      Ops::ProbeMailer.probe([ human.email, service_account.email.upcase ], "Prova", "Contenuto").deliver_now
    end.to change(ActionMailer::Base.deliveries, :count).by(1)
    expect(ActionMailer::Base.deliveries.last.to).to eq([ human.email ])
  end

  it "rimuove i service account anche da CC e BCC" do
    delivery = Ops::ProbeMailer.probe(human.email, "Prova", "Contenuto")
    delivery.message.cc = [ service_account.email ]
    delivery.message.bcc = [ service_account.email ]
    delivery.deliver_now

    expect(ActionMailer::Base.deliveries.last.destinations).to eq([ human.email ])
  end

  it "blocca anche un service account con un indirizzo pubblico" do
    service_account.update!(email: "automation@example.com")
    expect do
      Ops::ProbeMailer.probe(service_account.email, "Prova", "Contenuto").deliver_now
    end.not_to change(ActionMailer::Base.deliveries, :count)
  end
end
