# frozen_string_literal: true

require "rails_helper"

RSpec.describe Servers::Links::Detach do
  it "rimuove il collegamento" do
    link = create(:environment_host)
    result = nil
    expect { result = described_class.call(link:) }.to change(Connections::EnvironmentHost, :count).by(-1)
    expect(result).to be_ok
  end
end
