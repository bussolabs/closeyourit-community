# frozen_string_literal: true

require "rails_helper"

# CYRA-282/CYRA-667 — il job e' sottile di proposito: chiama il servizio e scrive una riga di log solo
# se c'e' qualcosa da dire. La guardia `positive?` esiste perche' un giro a vuoto ogni minuto
# riempirebbe i log di righe che dicono «zero», e chi legge smetterebbe di guardarli.
RSpec.describe Agents::DetectFailingHostsJob do
  it "restituisce quante macchine ha segnalato" do
    allow(Agents::Attempts::DetectFailingHosts).to receive(:call).and_return(Result.ok(3))

    expect(described_class.perform_now).to eq(3)
  end

  it "quando ne segnala almeno una lo scrive nei log" do
    allow(Agents::Attempts::DetectFailingHosts).to receive(:call).and_return(Result.ok(2))
    allow(Rails.logger).to receive(:info)

    described_class.perform_now

    expect(Rails.logger).to have_received(:info).with(/DetectFailingHostsJob: 2 macchine in errore segnalate/)
  end

  it "quando non c'e' niente da dire non sporca i log" do
    allow(Agents::Attempts::DetectFailingHosts).to receive(:call).and_return(Result.ok(0))
    allow(Rails.logger).to receive(:info)

    expect(described_class.perform_now).to eq(0)

    expect(Rails.logger).not_to have_received(:info).with(/DetectFailingHostsJob/)
  end
end
