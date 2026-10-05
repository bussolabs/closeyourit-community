# frozen_string_literal: true

require "rails_helper"
RSpec.describe Website::AccessRequest, type: :model do
  subject(:request) { described_class.new(name: " Ada ", email: " ADA@Example.COM ", team: " Team ", context: " Context ", locale: "it") }
  it "normalizza i campi" do
    request.validate
    expect(request.attributes.values_at("name", "email", "team", "context")).to eq([ "Ada", "ada@example.com", "Team", "Context" ])
  end
  it "richiede dati validi" do
    request.assign_attributes(name: "", email: "bad", team: "", context: "", locale: "fr")
    expect(request).not_to be_valid
    expect(request.errors.attribute_names).to include(:name, :email, :team, :context, :locale)
  end
end
