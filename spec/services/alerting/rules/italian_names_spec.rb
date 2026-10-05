# frozen_string_literal: true

require "rails_helper"

# CYRA-494 — nella stessa riga una regola aveva il nome in inglese e il suo evento in italiano, e
# nell'elenco convivevano le due lingue più alcuni ibridi: cercare una regola voleva dire indovinare
# la lingua giusta.
RSpec.describe "Nomi delle regole preconfigurate", type: :service do
  let(:organization) { create(:organization) }

  it "le regole installate portano il nome italiano del loro evento" do
    Alerting::Rules::InstallDefaults.call(organization:)

    rule = organization.alerting_rules.find_by(event_type: :uptime_down)
    expect(rule.name).to eq(I18n.t("member.notifications.catalog.uptime_down.title", locale: :it))
  end

  it "nessuna regola preconfigurata nasce con un nome inglese" do
    Alerting::Rules::InstallDefaults.call(organization:)

    inglesi = organization.alerting_rules.pluck(:name).select do |name|
      name.match?(/\b(down|up|failing|unreachable|stalled|usage|recovered|disconnected|stable|restart loop|host)\b/i)
    end

    expect(inglesi).to be_empty
  end

  # Il rischio dichiarato nel ticket: rinominare le regole non deve cambiare le notifiche già emesse.
  it "le notifiche già emesse conservano il proprio titolo" do
    Alerting::Rules::InstallDefaults.call(organization:)
    rule = organization.alerting_rules.find_by(event_type: :uptime_down)
    notification = create(:alerting_notification, organization:, rule:, title: "Titolo di allora")

    rule.update!(name: "Un altro nome")

    expect(notification.reload.title).to eq("Titolo di allora")
  end
end
