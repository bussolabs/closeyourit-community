# frozen_string_literal: true

require "rails_helper"

# CYRA-852 — il gruppo Telegram con argomenti dove l'owner riceve i suoi avvisi.
RSpec.describe Alerting::TelegramGroup do
  let(:organization) { create(:organization) }
  let(:owner) { create(:account).tap { |a| create(:membership, account: a, organization: organization, role: :owner) } }
  let(:member) { create(:account).tap { |a| create(:membership, account: a, organization: organization, role: :member) } }

  describe ".for_recipient" do
    it "torna il gruppo all'owner che l'ha collegato" do
      group = described_class.create!(organization: organization, account: owner, chat_id: "-100")

      expect(described_class.for_recipient(account: owner, organization: organization)).to eq(group)
    end

    it "per gli altri utenti non cambia nulla" do
      described_class.create!(organization: organization, account: owner, chat_id: "-100")

      expect(described_class.for_recipient(account: member, organization: organization)).to be_nil
    end

    it "chi l'ha collegato e non è più owner non lo riceve più" do
      described_class.create!(organization: organization, account: member, chat_id: "-100")

      expect(described_class.for_recipient(account: member, organization: organization)).to be_nil
    end
  end

  describe ".topic_key" do
    it "i critici stanno insieme, gli altri nel loro gruppo del catalogo" do
      expect(described_class.topic_key("uptime_down")).to eq("critical")
      expect(described_class.topic_key("server_cpu")).to eq("servers")
      expect(described_class.topic_key("ticket_assigned")).to eq("tickets")
      expect(described_class.topic_key("sconosciuto")).to eq("other")
    end

    # CYRA-865 — un gruppo del catalogo senza icona finirebbe con quella di «Altro» senza che nessuno lo noti.
    it "ogni argomento ha la sua icona, fra quelle che Telegram ammette" do
      keys = %w[critical other] + Notifications::Catalog.groups.map { |g| g.key.to_s }

      expect(described_class::TOPIC_ICONS.keys).to match_array(keys)
      expect(described_class::TOPIC_ICONS.values).to all(match(/\A\d+\z/))
      expect(described_class::TOPIC_ICONS.values.uniq.size).to eq(keys.size)
    end

    it "ogni argomento ha un nome nelle due lingue" do
      keys = %w[critical other] + Notifications::Catalog.groups.map { |g| g.key.to_s }
      %i[it en].each do |locale|
        I18n.with_locale(locale) do
          keys.each { |key| expect(described_class.topic_name(key)).not_to include("translation missing") }
        end
      end
    end
  end
end
