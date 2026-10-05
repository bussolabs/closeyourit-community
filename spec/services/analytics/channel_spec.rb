# frozen_string_literal: true

require "rails_helper"

RSpec.describe Analytics::Channel do
  def classify(referrer_host: nil, utm_medium: nil, utm_source: nil)
    described_class.classify(referrer_host: referrer_host, utm_medium: utm_medium, utm_source: utm_source)
  end

  it "Direct senza referrer né utm" do
    expect(classify).to eq("Direct")
  end

  it "Paid da utm_medium a pagamento (cpc/ppc/display)" do
    expect(classify(utm_medium: "cpc")).to eq("Paid")
    expect(classify(utm_medium: "display", referrer_host: "www.google.com")).to eq("Paid")
  end

  it "Email da utm_medium email o source newsletter" do
    expect(classify(utm_medium: "email")).to eq("Email")
    expect(classify(utm_source: "newsletter")).to eq("Email")
  end

  it "Organic Social da host social o utm_medium social" do
    expect(classify(referrer_host: "l.facebook.com")).to eq("Organic Social")
    expect(classify(utm_medium: "social")).to eq("Organic Social")
  end

  it "AI Assistants da host AI" do
    expect(classify(referrer_host: "chatgpt.com")).to eq("AI Assistants")
    expect(classify(referrer_host: "www.perplexity.ai")).to eq("AI Assistants")
  end

  it "Organic Search da motore di ricerca" do
    expect(classify(referrer_host: "www.google.com")).to eq("Organic Search")
    expect(classify(referrer_host: "duckduckgo.com")).to eq("Organic Search")
  end

  it "Referral da referrer generico" do
    expect(classify(referrer_host: "news.ycombinator.com")).to eq("Referral")
  end

  it "priorità: paid batte social; social batte search" do
    expect(classify(referrer_host: "l.facebook.com", utm_medium: "cpc")).to eq("Paid")
    expect(classify(referrer_host: "www.google.com", utm_medium: "social")).to eq("Organic Social")
  end
end
