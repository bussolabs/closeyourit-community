# frozen_string_literal: true

require "rails_helper"

RSpec.describe Notifications::TelegramEmoji do
  describe ".for" do
    it "has a dedicated emoji for every notification event type" do
      Alerting::Notification.event_types.each_key do |event_type|
        expect(described_class.for(event_type)).to be_present
        expect(described_class.for(event_type)).not_to eq(described_class::DEFAULT),
                                                        "missing dedicated emoji for #{event_type}"
      end
    end

    it "returns the dedicated emoji for a known type" do
      expect(described_class.for(:ticket_commented)).to eq("💬")
    end

    it "returns the default emoji for an unknown type" do
      expect(described_class.for(:unknown_type)).to eq("🔔")
    end
  end

  { it: "vai alla metrica", en: "Open metric" }.each do |locale, label|
    it "renders measurement notifications with the metric emoji and #{locale} metric link" do
      account = build_stubbed(:account)
      allow(account).to receive(:effective_locale).and_return(locale)
      notification = Alerting::Notification.new(event_type: :measurement_threshold,
        title: "CPU threshold", body: "Latest value: 85 %.",
        url: "/member/monitoring/measurements", account: account)

      text = Notifications::TelegramText.for(notification)

      expect(text).to start_with("📈 <b>CPU threshold</b>")
      expect(text).to include(">#{label}</a>")
    end
  end

  describe ".domain_for" do
    it "maps every notification event prefix to a known domain" do
      Alerting::Notification.event_types.each_key do |event_type|
        prefix = event_type.split("_").first
        expect(described_class::DOMAIN).to have_key(prefix), "prefix #{prefix} (#{event_type}) is absent from DOMAIN"
      end
    end

    it "resolves the domain from the prefix" do
      expect(described_class.domain_for(:ticket_commented)).to eq(:ticket)
      expect(described_class.domain_for(:chat_message)).to eq(:chat)
      expect(described_class.domain_for(:metric_threshold)).to eq(:metric)
      expect(described_class.domain_for(:measurement_threshold)).to eq(:metric)
      expect(described_class.domain_for(:cron_missed)).to eq(:cron)
      expect(described_class.domain_for(:server_cpu)).to eq(:server)
    end
  end
end
