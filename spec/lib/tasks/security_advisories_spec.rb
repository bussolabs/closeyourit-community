# frozen_string_literal: true

require "rails_helper"
require "rake"

# CYRA-1160 — the tool that signs the list of insecure versions with the key taken from the vault.
RSpec.describe "bin/rails security_advisories:sign", :silence_output do
  let(:dir) { Pathname(Dir.mktmpdir) }
  let(:input) { dir.join("unsigned.json") }
  let(:output) { dir.join("signed.json") }

  before do
    load Rails.root.join("lib/tasks/security_advisories.rake").to_s unless Rake::Task.task_defined?("security_advisories:sign")
    input.write({ advisories: [ { id: "CYI-1", fixed_in: "1.4.3", summary: "Session fixation" } ] }.to_json)
    trust_advisory_key!
  end

  after { FileUtils.rm_rf(dir) }

  # `execute`, not `invoke`: the Rails environment is already loaded by the suite.
  def sign(key: advisory_signing_key)
    stub_const("ENV", ENV.to_h.merge("ADVISORIES_SIGNING_KEY" => Base64.strict_encode64(key.to_bytes)))
    Rake::Task["security_advisories:sign"].execute(Rake::TaskArguments.new(%i[input output], [ input.to_s, output.to_s ]))
  end

  it "writes a list an install verifies, dated at signing time" do
    travel_to(Time.zone.parse("2026-11-04 10:00:00")) { sign }

    list = Instance::Advisories.verify(output.read)
    expect(list.issued_at).to eq(Time.zone.parse("2026-11-04 10:00:00"))
    expect(list.entries.map(&:fixed_in)).to eq(%w[1.4.3])
  end

  it "writes nothing when the key is not one the app trusts" do
    expect { sign(key: RbNaCl::SigningKey.generate) }.to raise_error(SystemExit)

    expect(output).not_to exist
  end

  it "never keeps the private key in what it writes" do
    sign

    expect(output.read).not_to include(Base64.strict_encode64(advisory_signing_key.to_bytes))
  end
end
