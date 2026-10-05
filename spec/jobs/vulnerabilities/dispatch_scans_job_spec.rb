# frozen_string_literal: true

require "rails_helper"

RSpec.describe Vulnerabilities::DispatchScansJob do
  it "accoda un job per ogni progetto con un repository collegato" do
    connected = create(:github_repository).project
    create(:project) # senza repository: non scansionabile

    expect { described_class.perform_now }
      .to have_enqueued_job(Vulnerabilities::ScanProjectJob).with(connected.id).exactly(:once)
  end

  it "salta i repository con la sincronizzazione disattivata" do
    create(:github_repository, sync_enabled: false)

    expect { described_class.perform_now }.not_to have_enqueued_job(Vulnerabilities::ScanProjectJob)
  end

  it "gira sulla coda di manutenzione, non su quelle sensibili alla latenza" do
    expect(described_class.new.queue_name).to eq("maintenance")
  end
end
