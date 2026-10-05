# frozen_string_literal: true

require "rails_helper"

# CYRA-672 — la prova che il cerchio si chiude: la riga diventa «inviata» quando il messaggio esce
# davvero, non quando lo si mette in coda.
RSpec.describe Notifications::DeliveryObserver do
  include ActiveJob::TestHelper

  let(:organization) { create(:organization) }
  let(:account) do
    create(:account).tap { |a| create(:membership, account: a, organization: organization, role: :member) }
  end
  # La factory nasce :sent (e' lo stato piu' comune a riposo): qui serve una riga che la consegna
  # non ha ancora toccato, altrimenti la prova non distingue il prima dal dopo.
  let(:notification) do
    create(:alerting_notification, :email, account: account, organization: organization,
                                           title: "Guasto", body: "corpo", url: "/member/home",
                                           status: :pending, delivered_at: nil)
  end

  it "l'accodamento da solo non basta: la riga resta :pending" do
    Alerting::AlertsMailer.triggered(notification).deliver_later

    expect(notification.reload.status_sent?).to be(false)
    expect(notification.delivered_at).to be_nil
  end

  it "quando il messaggio esce davvero, la riga diventa inviata" do
    perform_enqueued_jobs do
      Alerting::AlertsMailer.triggered(notification).deliver_later
    end

    notification.reload
    expect(notification.status_sent?).to be(true)
    expect(notification.delivered_at).to be_present
  end

  it "il riepilogo periodico chiude tutte le righe che rappresenta, non solo una" do
    altra = create(:alerting_notification, :email, account: account, organization: organization,
                                                   title: "Secondo", body: "corpo", url: "/member/home",
                                                   status: :pending, delivered_at: nil)

    perform_enqueued_jobs do
      Notifications::DigestMailer.summary(account, organization, [ notification, altra ]).deliver_later
    end

    expect(notification.reload.status_sent?).to be(true)
    expect(altra.reload.status_sent?).to be(true)
  end

  it "una email che non rappresenta nessuna notifica non tocca niente" do
    prima = notification.status

    perform_enqueued_jobs { Auth::PasswordsMailer.reset(account).deliver_later }

    expect(notification.reload.status).to eq(prima)
  end
end
