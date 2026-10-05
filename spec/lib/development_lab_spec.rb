# frozen_string_literal: true

require "spec_helper"
require "uri"
require_relative "../../app/lib/development_lab"

RSpec.describe DevelopmentLab do
  let(:organization) { Struct.new(:slug).new("demo") }

  it "allows only exact development lab HTTP targets for the demo organization" do
    expect(described_class.address(URI("http://127.0.0.1:31311/up"), organization:, development: true)).to eq("127.0.0.1")
    %w[http://127.0.0.1:3011/up http://localhost:31311/up http://127.0.0.1:31311/admin http://127.0.0.1:31311/up?x=1 https://127.0.0.1:31311/up http://user@127.0.0.1:31311/up].each do |url|
      expect(described_class.address(URI(url), organization:, development: true)).to be_nil
    end
  end

  it "never exempts production or another organization" do
    uri = URI("http://127.0.0.1:31311/up")
    expect(described_class.address(uri, organization:, development: false)).to be_nil
    organization.slug = "customer"
    expect(described_class.address(uri, organization:, development: true)).to be_nil
  end
end
