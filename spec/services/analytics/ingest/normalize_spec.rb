# frozen_string_literal: true

require "rails_helper"

RSpec.describe Analytics::Ingest::Normalize do
  def normalize(payload)
    described_class.call(payload: payload)
  end

  it "normalizza hostname in downcase e garantisce il leading slash sul path" do
    n = normalize({ "hostname" => "WWW.Example.TEST", "path" => "articles/foo" })
    expect(n.hostname).to eq("www.example.test")
    expect(n.path).to eq("/articles/foo")
  end

  it "strippa i null byte dai campi (Postgres li rifiuta: un pageview avvelenato affonda l'intero batch)" do
    nul = 0.chr
    n = normalize({
      "hostname" => "www.#{nul}example.test", "path" => "/lan#{nul}ding",
      "referrer" => "https://ref#{nul}errer.test/x", "utm_source" => "goo#{nul}gle",
      "name" => "sign#{nul}up", "environment" => "prod#{nul}uction"
    })
    expect(n.hostname).to eq("www.example.test")
    expect(n.path).to eq("/landing")
    expect(n.referrer_host).to eq("referrer.test")
    expect(n.utm_source).to eq("google")
    expect(n.name).to eq("signup")
    expect(n.environment).to eq("production")
  end

  it "tronca query e fragment dal path (non devono MAI essere persistiti)" do
    expect(normalize({ "path" => "/landing?utm_source=x&q=segreto" }).path).to eq("/landing")
    expect(normalize({ "path" => "/docs#sezione" }).path).to eq("/docs")
  end

  it "riduce il referrer al solo hostname (downcase, mai l'URL intero)" do
    n = normalize({ "hostname" => "www.example.test", "referrer" => "https://WWW.Google.com/search?q=x" })
    expect(n.referrer_host).to eq("www.google.com")
  end

  it "scarta il referrer same-host (navigazione interna = traffico diretto)" do
    n = normalize({ "hostname" => "www.example.test", "referrer" => "https://www.example.test/altra" })
    expect(n.referrer_host).to be_nil
  end

  it "referrer vuoto o non parsabile → nil" do
    expect(normalize({ "referrer" => "" }).referrer_host).to be_nil
    expect(normalize({ "referrer" => "::non-un-url::" }).referrer_host).to be_nil
    expect(normalize({ "referrer" => "google.com" }).referrer_host).to be_nil # senza scheme non c'è host
  end

  it "tronca gli UTM a 150 caratteri e scarta i blank (incluse term e content)" do
    n = normalize({
      "utm_source" => "a" * 300, "utm_medium" => "   ", "utm_campaign" => " launch ",
      "utm_term" => " scarpe rosse ", "utm_content" => "b" * 300
    })
    expect(n.utm_source.length).to eq(150)
    expect(n.utm_medium).to be_nil
    expect(n.utm_campaign).to eq("launch")
    expect(n.utm_term).to eq("scarpe rosse")
    expect(n.utm_content.length).to eq(150)
  end

  it "classifica screen_width in categoria di viewport, ai confini dei breakpoint" do
    expect(normalize({ "screen_width" => 375 }).screen_class).to eq("mobile")
    expect(normalize({ "screen_width" => 575 }).screen_class).to eq("mobile")
    expect(normalize({ "screen_width" => 576 }).screen_class).to eq("tablet")
    expect(normalize({ "screen_width" => 991 }).screen_class).to eq("tablet")
    expect(normalize({ "screen_width" => 992 }).screen_class).to eq("laptop")
    expect(normalize({ "screen_width" => 1439 }).screen_class).to eq("laptop")
    expect(normalize({ "screen_width" => 1440 }).screen_class).to eq("desktop")
    expect(normalize({ "screen_width" => "1920" }).screen_class).to eq("desktop")
  end

  it "screen_class nil se screen_width assente o non un intero positivo" do
    expect(normalize({}).screen_class).to be_nil
    expect(normalize({ "screen_width" => 0 }).screen_class).to be_nil
    expect(normalize({ "screen_width" => "abc" }).screen_class).to be_nil
  end

  it "environment assente → production" do
    expect(normalize({}).environment).to eq("production")
    expect(normalize({ "environment" => "staging" }).environment).to eq("staging")
  end

  it "genera event_id se assente" do
    expect(normalize({}).event_id).to be_present
    expect(normalize({ "event_id" => "abc" }).event_id).to eq("abc")
  end

  it "name default 'pageview'; un nome custom identifica un evento (troncato)" do
    expect(normalize({}).name).to eq("pageview")
    expect(normalize({ "name" => "  Signup  " }).name).to eq("Signup")
    expect(normalize({ "name" => "a" * 200 }).name.length).to eq(120)
  end

  it "clampa occurred_at oltre 1h nel futuro e converte gli epoch in millisecondi" do
    freeze_time do
      corrotto = normalize({ "occurred_at" => 2.hours.from_now.iso8601 })
      expect(corrotto.occurred_at).to eq(Time.current)

      ms = normalize({ "occurred_at" => Time.current.to_i * 1000 })
      expect(ms.occurred_at).to be_within(1.second).of(Time.current)
    end
  end

  it "payload non-Hash → Normalized vuoto (hostname/path blank)" do
    n = normalize("spazzatura")
    expect(n.hostname).to eq("")
    expect(n.path).to eq("")
  end
end
