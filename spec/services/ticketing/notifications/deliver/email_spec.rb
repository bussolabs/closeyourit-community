# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ticketing::Notifications::Deliver do
  include ActiveJob::TestHelper

  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization: organization) }
  let(:ticket) { create(:ticket, organization: organization, project: project) }
  let(:account) do
    create(:account).tap { |a| create(:membership, account: a, organization: organization, role: :member) }
  end
  let(:content) { Ticketing::Notifications::Content.new(title: "Titolo", body: "Corpo", url: "/member/x") }

  def call(dedup_key: "email:1", quiet: false)
    described_class.email(account: account, ticket: ticket, organization: organization,
                         event_type: :ticket_commented, content: content, dedup_key: dedup_key, quiet: quiet)
  end

  it "consegna email → Result.ok, accoda il mailer e lascia la riga :pending (CYRA-672)" do
    result = nil
    expect { result = call }.to have_enqueued_mail(Ticketing::TicketNotificationsMailer, :notify)
    expect(result).to be_ok
    expect(result.value.status_pending?).to be(true)
  end

  it "quiet hours → notifica trattenuta (:held), nessuna mail accodata" do
    result = nil
    expect { result = call(quiet: true) }.not_to have_enqueued_mail(Ticketing::TicketNotificationsMailer, :notify)
    expect(result).to be_ok
    expect(result.value.status_held?).to be(true)
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
