# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatHelper, type: :helper do
  it "restituisce 0 senza account corrente" do
    Current.account = nil
    expect(helper.chat_unread_count).to eq(0)
  end

  it "conta le notifiche chat in-app non lette dell'account corrente" do
    org = create(:organization)
    account = create(:account)
    create(:membership, account: account, organization: org, role: :member)
    Current.account = account

    conversation = create(:chat_conversation, :direct, organization: org)
    message = create(:chat_message, conversation: conversation)
    Alerting::Notification.create!(
      organization: org, account: account, subject: message, rule: nil, via: :in_app,
      event_type: :chat_mentioned, title: "t", body: "b", url: "/x",
      dedup_key: "chat:#{message.id}:#{account.id}:in_app", status: :sent
    )

    expect(helper.chat_unread_count).to eq(1)
  end

  describe "#chat_reference_visible?" do
    let(:org) { create(:organization) }
    let(:project) { create(:project, organization: org) }

    it "nil (broadcast at-post-time) → sempre visibile" do
      expect(helper.chat_reference_visible?(project, nil)).to be(true)
    end

    it "un progetto è visibile solo se tra gli id passati" do
      expect(helper.chat_reference_visible?(project, [ project.id ])).to be(true)
      expect(helper.chat_reference_visible?(project, [])).to be(false)
    end

    it "una risorsa con project_id segue la visibilità del suo progetto" do
      ticket = create(:ticket, organization: org, project: project)
      expect(helper.chat_reference_visible?(ticket, [ project.id ])).to be(true)
      expect(helper.chat_reference_visible?(ticket, [])).to be(false)
    end
  end

  describe "#chat_day_label" do
    it "says Today and Yesterday, then a short date" do
      travel_to(Time.zone.local(2026, 10, 1, 12)) do
        expect(helper.chat_day_label(Date.new(2026, 10, 1))).to eq(I18n.t("member.chat.days.today"))
        expect(helper.chat_day_label(Date.new(2026, 9, 30))).to eq(I18n.t("member.chat.days.yesterday"))
        expect(helper.chat_day_label(Date.new(2026, 9, 28))).to eq(I18n.l(Date.new(2026, 9, 28), format: :day_month))
      end
    end
  end
end
