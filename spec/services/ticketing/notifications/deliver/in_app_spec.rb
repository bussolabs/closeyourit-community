# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ticketing::Notifications::Deliver do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization: organization) }
  let(:ticket) { create(:ticket, organization: organization, project: project) }
  let(:account) do
    create(:account).tap { |a| create(:membership, account: a, organization: organization, role: :member) }
  end
  let(:content) { Ticketing::Notifications::Content.new(title: "Titolo", body: "Corpo", url: "/member/x") }

  def call(dedup_key: "in_app:1")
    described_class.in_app(account: account, ticket: ticket, organization: organization,
                         event_type: :ticket_commented, content: content, dedup_key: dedup_key)
  end

  it "consegna in-app → Result.ok con la notifica creata (via in_app, rule nil, subject = ticket)" do
    result = call
    expect(result).to be_ok
    notification = result.value
    expect(notification).to be_a(Alerting::Notification)
    expect(notification.via_in_app?).to be(true)
    expect(notification.subject).to eq(ticket)
    expect(notification.rule_id).to be_nil
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
