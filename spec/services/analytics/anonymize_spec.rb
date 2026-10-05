# frozen_string_literal: true

require "rails_helper"

RSpec.describe Analytics::Anonymize do
  let(:chrome_ua) do
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"
  end
  let(:project_id) { SecureRandom.uuid }

  def identity(ip: "203.0.113.9", user_agent: chrome_ua, project: project_id)
    described_class.call(ip: ip, user_agent: user_agent, project_id: project).value
  end

  it "produce un hash SHA-256 esadecimale con browser, os, device e versioni derivati" do
    result = identity
    expect(result.visitor_hash).to match(/\A[0-9a-f]{64}\z/)
    expect(result.browser).to eq("Chrome")
    expect(result.os).to eq("macOS")
    expect(result.device_type).to eq("desktop")
    expect(result.browser_version).to eq("126")
    expect(result.os_version).to eq("10.15")
    expect(result.bot).to be(false)
  end

  it "è stabile nello stesso giorno per lo stesso (ip, ua, progetto)" do
    expect(identity.visitor_hash).to eq(identity.visitor_hash)
  end

  it "cambia al cambiare di ip, user_agent o progetto (no correlazione cross-progetto)" do
    base = identity.visitor_hash
    expect(identity(ip: "198.51.100.7").visitor_hash).not_to eq(base)
    expect(identity(user_agent: "#{chrome_ua} Extra").visitor_hash).not_to eq(base)
    expect(identity(project: SecureRandom.uuid).visitor_hash).not_to eq(base)
  end

  it "cambia al cambio di giorno (salt ruotato)" do
    today_hash = identity.visitor_hash
    travel_to(2.days.from_now) do
      expect(identity.visitor_hash).not_to eq(today_hash)
    end
  end

  it "bot → identity vuota senza creare il salt (nessun lavoro inutile)" do
    result = identity(user_agent: "curl/8.4.0")
    expect(result.bot).to be(true)
    expect(result.visitor_hash).to be_nil
    expect(Analytics::Salt.count).to eq(0)
  end
end
