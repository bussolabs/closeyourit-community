# frozen_string_literal: true

require "rails_helper"

RSpec.describe Alerting::Deliver do
  include ActiveJob::TestHelper

  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization: organization) }
  let(:group) { create(:error_group, project: project) }
  let(:account) do
    create(:account).tap { |a| create(:membership, account: a, organization: organization, role: :member) }
  end
  let(:rule) { create(:alerting_rule, organization: organization, event_type: :error_new) }
  let(:content) { Alerting::Content.new(title: "Titolo", body: "Corpo", url: "/x", project: project) }

  def call(dedup_key: "email:1", quiet: false, event_type: "error_new", bucket: nil)
    described_class.email(rule: rule, account: account, event_type: event_type,
                         subject: group, content: content, dedup_key: dedup_key, quiet: quiet, bucket: bucket)
  end

  it "consegna email → Result.ok, accoda il mailer e lascia la riga :pending (CYRA-672)" do
    result = nil
    expect { result = call }.to have_enqueued_mail(Alerting::AlertsMailer, :triggered)
    expect(result).to be_ok
    expect(result.value.status_pending?).to be(true)
  end

  it "quiet hours → notifica trattenuta (:held), nessuna mail accodata" do
    result = nil
    expect { result = call(quiet: true) }.not_to have_enqueued_mail(Alerting::AlertsMailer, :triggered)
    expect(result).to be_ok
    expect(result.value.status_held?).to be(true)
  end

  it "evento critico (guasto grave) in quiet hours → scavalca il silenzio: mail accodata subito (CYRA-479)" do
    result = nil
    expect { result = call(event_type: "uptime_down", quiet: true) }
      .to have_enqueued_mail(Alerting::AlertsMailer, :triggered)
    expect(result).to be_ok
    expect(result.value.status_pending?).to be(true)
  end

  it "evento critico ma con cadenza digest (bucket) → resta in coda: il bypass vale solo per le quiet hours (CYRA-479)" do
    result = nil
    expect { result = call(event_type: "uptime_down", quiet: true, bucket: :daily) }
      .not_to have_enqueued_mail(Alerting::AlertsMailer, :triggered)
    expect(result).to be_ok
    expect(result.value.status_queued?).to be(true)
  end

  it "duplicato sulla dedup_key (save = false per uniqueness) → Result.err(:duplicate)" do
    call
    expect(call).to be_err
  end

  it "race concorrente: save solleva RecordNotUnique → Result.err(:duplicate) (rescue)" do
    allow_any_instance_of(Alerting::Notification).to receive(:save).and_raise(ActiveRecord::RecordNotUnique)

    result = call

    expect(result).to be_err
    expect(result.error).to eq(:duplicate)
  end
end
