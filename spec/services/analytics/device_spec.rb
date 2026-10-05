# frozen_string_literal: true

require "rails_helper"

RSpec.describe Analytics::Device do
  describe ".parse" do
    it "riconosce Chrome su macOS" do
      parsed = described_class.parse(
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"
      )
      expect(parsed.browser).to eq("Chrome")
      expect(parsed.os).to eq("macOS")
      expect(parsed.bot).to be(false)
    end

    it "riconosce Safari su iOS (iPhone contiene 'like Mac OS X': iOS vince su macOS)" do
      parsed = described_class.parse(
        "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1"
      )
      expect(parsed.browser).to eq("Safari")
      expect(parsed.os).to eq("iOS")
    end

    it "riconosce Firefox su Windows" do
      parsed = described_class.parse(
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:127.0) Gecko/20100101 Firefox/127.0"
      )
      expect(parsed.browser).to eq("Firefox")
      expect(parsed.os).to eq("Windows")
    end

    it "riconosce Edge prima di Chrome (Edge si spaccia per Chrome)" do
      parsed = described_class.parse(
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36 Edg/126.0.2592.87"
      )
      expect(parsed.browser).to eq("Edge")
    end

    it "riconosce Chrome su Android (Android vince su Linux)" do
      parsed = described_class.parse(
        "Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Mobile Safari/537.36"
      )
      expect(parsed.browser).to eq("Chrome")
      expect(parsed.os).to eq("Android")
    end

    it "UA sconosciuto ma non-bot → browser/os nil, bot false" do
      parsed = described_class.parse("StranoBrowser/1.0")
      expect(parsed.browser).to be_nil
      expect(parsed.os).to be_nil
      expect(parsed.bot).to be(false)
    end

    it "marca i crawler come bot" do
      expect(described_class.parse("Mozilla/5.0 (compatible; Googlebot/2.1)").bot).to be(true)
      expect(described_class.parse("curl/8.4.0").bot).to be(true)
      expect(described_class.parse("HeadlessChrome/126.0.0.0").bot).to be(true)
    end

    it "UA vuoto o nil → bot (nessun browser reale gira senza UA)" do
      expect(described_class.parse("").bot).to be(true)
      expect(described_class.parse(nil).bot).to be(true)
    end
  end

  describe ".parse — device_type" do
    it "desktop di default (Windows/Mac senza marker mobile)" do
      ua = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"
      expect(described_class.parse(ua).device_type).to eq("desktop")
    end

    it "iPhone → mobile" do
      ua = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1"
      expect(described_class.parse(ua).device_type).to eq("mobile")
    end

    it "Android con 'Mobile' → mobile" do
      ua = "Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Mobile Safari/537.36"
      expect(described_class.parse(ua).device_type).to eq("mobile")
    end

    it "iPad → tablet" do
      ua = "Mozilla/5.0 (iPad; CPU OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Safari/604.1"
      expect(described_class.parse(ua).device_type).to eq("tablet")
    end

    it "Android senza 'Mobile' → tablet" do
      ua = "Mozilla/5.0 (Linux; Android 14; SM-X710) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"
      expect(described_class.parse(ua).device_type).to eq("tablet")
    end

    it "bot → device_type nil" do
      expect(described_class.parse("curl/8.4.0").device_type).to be_nil
    end
  end

  describe ".parse — versioni browser/os (major)" do
    it "Chrome/126 su macOS 10_15_7" do
      ua = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"
      parsed = described_class.parse(ua)
      expect(parsed.browser_version).to eq("126")
      expect(parsed.os_version).to eq("10.15")
    end

    it "Safari usa Version/17.5 (non Safari/604) su iOS 17_5" do
      ua = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1"
      parsed = described_class.parse(ua)
      expect(parsed.browser_version).to eq("17")
      expect(parsed.os_version).to eq("17")
    end

    it "Firefox/127 su Windows NT 10.0" do
      ua = "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:127.0) Gecko/20100101 Firefox/127.0"
      parsed = described_class.parse(ua)
      expect(parsed.browser_version).to eq("127")
      expect(parsed.os_version).to eq("10")
    end

    it "Edg/126 e Android 14" do
      ua = "Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Mobile Safari/537.36 EdgA/126.0.0.0"
      parsed = described_class.parse(ua)
      expect(parsed.browser_version).to eq("126")
      expect(parsed.os_version).to eq("14")
    end

    it "versione assente → nil (browser noto senza numero estraibile)" do
      parsed = described_class.parse("StranoBrowser/1.0")
      expect(parsed.browser_version).to be_nil
      expect(parsed.os_version).to be_nil
    end
  end
end
