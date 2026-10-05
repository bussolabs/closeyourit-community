# frozen_string_literal: true

require "rails_helper"

RSpec.describe App::Host do
  around do |example|
    names = %w[MAIL_HOST APP_HOSTS APP_BASE_URL]
    saved = ENV.to_h.slice(*names)
    names.each { |name| ENV.delete(name) }
    example.run
  ensure
    names.each { |name| ENV.delete(name) }
    saved.each { |name, value| ENV[name] = value }
  end

  it "uses the first of the hosts the install answers on" do
    ENV["APP_HOSTS"] = "bugs.example.com, example.com"

    expect(described_class.base_url).to eq("https://bugs.example.com")
  end

  it "prefers the mail host, then an explicit base URL" do
    ENV["APP_HOSTS"] = "a.example.com"
    ENV["MAIL_HOST"] = "b.example.com"
    expect(described_class.base_url).to eq("https://b.example.com")

    ENV["APP_BASE_URL"] = "http://localhost:3011"
    expect(described_class.base_url).to eq("http://localhost:3011")
  end

  it "never falls back to closeyour.it" do
    expect(described_class.base_url).to eq("https://localhost")
  end
end
