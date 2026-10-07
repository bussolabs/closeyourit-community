# frozen_string_literal: true

require "rails_helper"

RSpec.describe Dev::Personas do
  it "ritorna [] fuori da development (es. in test)" do
    expect(described_class.all).to eq([])
  end

  it "in development carica le personas dal YAML" do
    allow(Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new("development"))

    personas = described_class.all
    expect(personas).to be_present
    expect(personas.first).to include(:email, :password, :label, :role)
    expect(personas.map { |p| p[:email] }).to include("god@example.com")
  end

  it "in development ma senza file YAML → [] (guard file mancante)" do
    allow(Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new("development"))
    allow(File).to receive(:exist?).with(described_class::PATH).and_return(false)

    expect(described_class.all).to eq([])
  end
end
