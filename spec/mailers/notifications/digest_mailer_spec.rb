# frozen_string_literal: true

require "rails_helper"

RSpec.describe Notifications::DigestMailer, type: :mailer do
  it "summary renderizza (view sotto mails/notifications/digest_mailer) con subject i18n" do
    account = create(:account)
    organization = create(:organization)
    notifications = [
      create(:alerting_notification, account: account, organization: organization, title: "Prima notifica"),
      create(:alerting_notification, account: account, organization: organization, title: "Seconda notifica")
    ]

    mail = described_class.summary(account, organization, notifications)

    expect(mail.to).to eq([ account.email ])
    expect(mail.subject).to be_present
    expect(mail.body.encoded).to include("Prima notifica").and include("Seconda notifica")
  end

  it "i link del riepilogo (HTML e testo) usano l'URL assoluto, non il path relativo" do
    account = create(:account)
    organization = create(:organization)
    notifications = [
      create(:alerting_notification, account: account, organization: organization,
                                     title: "Prima notifica", url: "/member/monitoring/error/1")
    ]

    mail = described_class.summary(account, organization, notifications)

    path = "/member/monitoring/error/#{notifications.first.subject_id}"
    expect(mail.html_part.decoded).to include(%(href="http://example.com#{path}"))
    expect(mail.text_part.decoded).to include("http://example.com#{path}")
  end
end
