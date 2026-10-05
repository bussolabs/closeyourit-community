# frozen_string_literal: true

require "rails_helper"

RSpec.describe Notifications::TelegramText do
  let(:account) { build(:account) }

  before do
    allow(account).to receive(:effective_locale).and_return(:it)
    allow(App::Host).to receive(:base_url).and_return("https://www.closeyour.it")
  end

  def notification(attrs = {})
    Alerting::Notification.new({
      event_type: :ticket_commented,
      title: "Mario ha commentato PROJ-123",
      body: "Ho sistemato il bug del login",
      url: "/member/tickets/42",
      account: account
    }.merge(attrs))
  end

  describe ".for" do
    it "compone titolo con emoji e grassetto, corpo in blockquote, link footer con url assoluto" do
      expect(described_class.for(notification)).to eq(
        "💬 <b>Mario ha commentato PROJ-123</b>\n" \
        "<blockquote>Ho sistemato il bug del login</blockquote>\n" \
        "📄 <a href=\"https://www.closeyour.it/member/tickets/42\">vai al ticket</a>"
      )
    end

    it "usa l'emoji del tipo di evento" do
      expect(described_class.for(notification(event_type: :uptime_down, url: nil, body: nil))).to start_with("🔴 <b>")
    end

    it "sceglie la label del link in base al dominio dell'evento" do
      text = described_class.for(notification(event_type: :chat_message, url: "/member/chat/1"))
      expect(text).to include(">vai alla conversazione</a>")
    end

    it "localizza la label nella lingua del destinatario" do
      allow(account).to receive(:effective_locale).and_return(:en)
      expect(described_class.for(notification)).to include(">Open ticket</a>")
    end

    it "escapa i caratteri HTML di titolo e corpo (input arbitrario)" do
      text = described_class.for(notification(title: "A <b>& B", body: "x < y & \"z\""))
      expect(text).to include("💬 <b>A &lt;b&gt;&amp; B</b>")
      expect(text).to include("<blockquote>x &lt; y &amp; &quot;z&quot;</blockquote>")
    end

    it "omette il blockquote se il corpo è assente" do
      expect(described_class.for(notification(body: nil))).not_to include("<blockquote>")
    end

    it "omette il link se l'url è assente" do
      expect(described_class.for(notification(url: nil))).not_to include("<a href")
    end

    it "lascia l'url invariato se già assoluto" do
      expect(described_class.for(notification(url: "https://example.test/x"))).to include('href="https://example.test/x"')
    end

    # CYRA-874 — Telegram rejects messages over 4096 characters.
    it "shortens a very long title and body so the message stays under the Telegram limit" do
      text = described_class.for(notification(title: "t" * 5000, body: "&" * 10_000))
      visible = CGI.unescapeHTML(text.gsub(/<[^>]+>/, ""))

      expect(visible.length).to be < 4096
      expect(text).to include("...</blockquote>")
    end
  end

  describe ".digest_line" do
    it "emoji + titolo cliccabile verso l'url assoluto" do
      expect(described_class.digest_line(notification)).to eq(
        "💬 <a href=\"https://www.closeyour.it/member/tickets/42\">Mario ha commentato PROJ-123</a>"
      )
    end

    it "solo emoji + titolo se manca l'url" do
      expect(described_class.digest_line(notification(url: nil))).to eq("💬 Mario ha commentato PROJ-123")
    end
  end
end
