# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ticketing::Notifications::DispatchComment do
  include ActiveJob::TestHelper

  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization: organization) }
  let(:author) { member }
  let(:watcher) { member }
  let(:mentioned) { member }
  let(:ticket) { create(:ticket, organization: organization, project: project, reporter: author) }
  let(:comment) { create(:ticket_comment, ticket: ticket, author: author, body: "ping @#{mentioned.handle}") }

  def member
    create(:account).tap { |a| create(:membership, account: a, organization: organization, role: :member) }
  end

  before do
    Ticketing::Subscription.ensure_for(ticket: ticket, account: watcher, source: :manual)
    Ticketing::Subscription.ensure_for(ticket: ticket, account: author, source: :commenter)
    Ticketing::Subscription.ensure_for(ticket: ticket, account: mentioned, source: :mentioned)
  end

  it "notifica il menzionato come 'mentioned', gli altri watcher come 'commented', escluso l'autore" do
    described_class.call(comment: comment, mentioned_ids: [ mentioned.id ])
    expect(Alerting::Notification.where(account: mentioned, event_type: :ticket_mentioned, via: :in_app)).to exist
    expect(Alerting::Notification.where(account: watcher, event_type: :ticket_commented, via: :in_app)).to exist
    expect(Alerting::Notification.where(account: author)).not_to exist
  end

  it "un menzionato riceve SOLO la menzione (non anche il commented)" do
    described_class.call(comment: comment, mentioned_ids: [ mentioned.id ])
    expect(Alerting::Notification.where(account: mentioned, via: :in_app).count).to eq(1)
    expect(Alerting::Notification.where(account: mentioned, event_type: :ticket_commented)).not_to exist
  end

  it "cadenza email off per l'evento → nessuna email, ma l'in-app resta" do
    create(:alerting_preference, account: watcher, organization: organization,
                                 email_cadences: { "ticket_commented" => "off" })
    described_class.call(comment: comment, mentioned_ids: [ mentioned.id ])
    expect(Alerting::Notification.where(account: watcher, via: :in_app)).to exist
    expect(Alerting::Notification.where(account: watcher, via: :email)).not_to exist
  end

  it "in-app sempre attiva anche col vecchio flag in_app_enabled = false" do
    create(:alerting_preference, account: watcher, organization: organization, in_app_enabled: false)
    described_class.call(comment: comment, mentioned_ids: [ mentioned.id ])
    expect(Alerting::Notification.where(account: watcher, via: :in_app)).to exist
  end

  it "email_enabled = false → solo in-app per il watcher (nessuna email)" do
    create(:alerting_preference, account: watcher, organization: organization, email_enabled: false)
    described_class.call(comment: comment, mentioned_ids: [ mentioned.id ])
    expect(Alerting::Notification.where(account: watcher, via: :in_app)).to exist
    expect(Alerting::Notification.where(account: watcher, via: :email)).not_to exist
  end

  it "commento senza ticket → no-op (Result.ok 0)" do
    allow(comment).to receive(:ticket).and_return(nil)
    result = described_class.call(comment: comment, mentioned_ids: [])
    expect(result).to be_ok
    expect(result.value).to eq(0)
  end

  it "re-dispatch dello stesso commento → 0 consegne (tutti duplicati, dedup_key)" do
    described_class.call(comment: comment, mentioned_ids: [ mentioned.id ])
    result = described_class.call(comment: comment, mentioned_ids: [ mentioned.id ])
    expect(result.value).to eq(0)
  end

  it "autore rimosso (author nil) → titolo con name nil, i watcher ricevono comunque" do
    allow(comment).to receive(:author).and_return(nil)
    described_class.call(comment: comment, mentioned_ids: [ mentioned.id ])
    expect(Alerting::Notification.where(account: watcher, event_type: :ticket_commented, via: :in_app)).to exist
  end
end
