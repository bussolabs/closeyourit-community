# frozen_string_literal: true

require "rails_helper"

# A fresh install took no backup, so `closeyourit doctor` greeted the new owner with a red cross
# (CYRA-1081). The first backup runs before the password is printed and never aborts the install:
# the password is already gone from .env, so a stop there would lose it.
RSpec.describe "installer/install.sh first backup" do
  let(:script) { Rails.root.join("installer/install.sh").read }

  it "takes a backup before printing the administrator password" do
    backup = script.index(%r{^\s*/usr/local/bin/closeyourit backup\b})
    password = script.index('say "  Password: $ADMIN_PASSWORD"')

    expect(backup).not_to be_nil
    expect(backup).to be < password
  end

  it "keeps going when that backup fails" do
    expect(script).to match(%r{^\s*/usr/local/bin/closeyourit backup\b[^\n]*\|\|})
  end
end
