# frozen_string_literal: true

require "rails_helper"

RSpec.describe Reports::PeriodicMailer, type: :mailer do
  let(:organization) { create(:organization) }
  let(:account) { create(:account) }
  let(:project) { create(:project, organization: organization, name: "Sito") }
  let(:now) { Time.zone.local(2026, 8, 10, 8, 0) }

  before { create(:membership, account: account, organization: organization, role: :owner) }

  def report(cadence: "weekly")
    create(:pageview, project: project, occurred_at: now - 1.day, visitor_hash: "v1")
    Reports::PeriodicSummary.call(account: account, organization: organization,
                                  cadence: cadence, now: now)
  end

  it "il riepilogo arriva a chi l'ha chiesto, con oggetto tradotto e numeri dentro" do
    mail = described_class.summary(account, organization, report)

    expect(mail.to).to eq([ account.email ])
    expect(mail.subject).to eq(I18n.t("reports.periodic.mailer.subject.weekly", org: organization.name))
    expect(mail.html_part.decoded).to include("Sito")
    expect(mail.text_part.decoded).to include("Sito")
  end

  it "l'oggetto dice la frequenza: giornaliero, settimanale e mensile non si confondono" do
    daily = described_class.summary(account, organization, report(cadence: "daily"))
    expect(daily.subject).to eq(I18n.t("reports.periodic.mailer.subject.daily", org: organization.name))
  end

  it "il link al pannello è assoluto: nei client di posta un path relativo non porta da nessuna parte" do
    mail = described_class.summary(account, organization, report)

    expect(mail.html_part.decoded).to include('href="http://example.com/member/monitoring/analytics"')
    expect(mail.text_part.decoded).to include("http://example.com/member/monitoring/analytics")
  end

  it "parla la lingua del destinatario" do
    inglese = create(:account, locale: "en")
    create(:membership, account: inglese, organization: organization, role: :member)
    summary = Reports::PeriodicSummary.call(account: inglese, organization: organization,
                                            cadence: "weekly", now: now)

    mail = described_class.summary(inglese, organization, summary)

    expect(mail.subject).to eq(I18n.t("reports.periodic.mailer.subject.weekly",
                                      org: organization.name, locale: :en))
  end
end
