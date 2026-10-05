# frozen_string_literal: true

require "rails_helper"

# CYRA-667 — la potatura ha una regola precisa e vale la pena inchiodarla: si buttano solo gli advisory
# che non colpiscono piu' nessuno E che sono vecchi. I finding non si toccano mai: sono la memoria di
# cosa e' stato trovato e quando, quella che permette di dire «questa falla e' rimasta aperta tre mesi».
RSpec.describe Vulnerabilities::PruneJob, type: :job do
  let(:soglia) { Vulnerabilities::Constants::ADVISORY_REFRESH_AFTER }

  it "gira sulla coda :batch dei lavori lunghi" do
    expect(described_class.new.queue_name).to eq("batch")
  end

  it "butta l'advisory orfano e vecchio" do
    orfano = create(:vulnerability_advisory, refreshed_at: (soglia + 1.day).ago)

    described_class.perform_now

    expect(Vulnerabilities::Advisory.exists?(orfano.id)).to be(false)
  end

  it "tiene l'advisory orfano ma ancora fresco" do
    fresco = create(:vulnerability_advisory, refreshed_at: (soglia - 1.day).ago)

    described_class.perform_now

    expect(Vulnerabilities::Advisory.exists?(fresco.id)).to be(true)
  end

  it "tiene l'advisory vecchio che colpisce ancora qualcuno, e non tocca il finding" do
    vecchio = create(:vulnerability_advisory, refreshed_at: (soglia + 1.day).ago)
    finding = create(:vulnerability_finding, advisory: vecchio)

    described_class.perform_now

    expect(Vulnerabilities::Advisory.exists?(vecchio.id)).to be(true)
    expect(Vulnerabilities::Finding.exists?(finding.id)).to be(true)
  end
end
