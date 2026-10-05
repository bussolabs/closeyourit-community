# frozen_string_literal: true

require "rails_helper"

RSpec.describe Reports::DeliverJob, type: :job do
  let(:organization) { create(:organization) }
  let(:account) { create(:account) }
  let(:project) { create(:project, organization: organization) }
  let(:lunedi) { Time.zone.local(2026, 8, 10, 8, 0) }
  let(:preference) do
    create(:alerting_preference, account: account, organization: organization, report_cadence: :weekly)
  end

  before { create(:membership, account: account, organization: organization, role: :owner) }

  def con_traffico
    create(:pageview, project: project, occurred_at: lunedi - 1.day)
  end

  it "spedisce il riepilogo e segna il periodo come fatto" do
    con_traffico

    expect { travel_to(lunedi) { described_class.perform_now(preference.id) } }
      .to change { ActionMailer::Base.deliveries.size }.by(1)

    expect(preference.reload.report_last_sent_at).to be_within(1.minute).of(lunedi)
  end

  it "un secondo giro nello stesso periodo non spedisce di nuovo" do
    con_traffico
    travel_to(lunedi) { described_class.perform_now(preference.id) }

    expect { travel_to(lunedi + 1.hour) { described_class.perform_now(preference.id) } }
      .not_to change { ActionMailer::Base.deliveries.size }
  end

  # Un'email che dice zero su tutto è rumore: non si manda. Il periodo viene comunque segnato,
  # altrimenti il giro tornerebbe a chiederlo ogni giorno fino al lunedì successivo.
  it "senza niente da raccontare non spedisce, ma il periodo resta chiuso" do
    expect { travel_to(lunedi) { described_class.perform_now(preference.id) } }
      .not_to change { ActionMailer::Base.deliveries.size }

    expect(preference.reload.report_last_sent_at).to be_present
  end

  it "preferenza sparita nel frattempo → non fa niente" do
    id = preference.id
    preference.destroy!

    expect { described_class.perform_now(id) }.not_to change { ActionMailer::Base.deliveries.size }
  end

  it "frequenza spenta fra l'accodamento e l'esecuzione → non spedisce" do
    con_traffico
    preference.update!(report_cadence: :off)

    expect { travel_to(lunedi) { described_class.perform_now(preference.id) } }
      .not_to change { ActionMailer::Base.deliveries.size }
  end
end
