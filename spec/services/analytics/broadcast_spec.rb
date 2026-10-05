# frozen_string_literal: true

require "rails_helper"

# Broadcast realtime della dashboard analytics. Su nuovo pageview emette un page-refresh Turbo
# (action="refresh") sullo stream per-progetto; ogni viewer ri-fetcha la propria show e morpha.
# have_broadcasted_to su stream String legge il broadcast Turbo grezzo (niente .from_channel).
RSpec.describe Analytics::Broadcast, type: :service do
  let(:project) { create(:project) }
  let(:stream) { Realtime::Streams.analytics(project) }

  describe ".refresh" do
    it "emette un page-refresh Turbo (action=refresh) sullo stream del progetto" do
      expect { described_class.refresh(project) }
        .to have_broadcasted_to(stream).with(a_string_including('action="refresh"'))
    end

    it "un solo broadcast per chiamata" do
      expect { described_class.refresh(project) }.to have_broadcasted_to(stream).once
    end

    it "non broadcasta sullo stream di un ALTRO progetto (isolamento tenant)" do
      other = Realtime::Streams.analytics(create(:project))
      expect { described_class.refresh(project) }.not_to have_broadcasted_to(other)
    end

    it "throttla i refresh ravvicinati sullo stesso progetto (una finestra = un broadcast)" do
      allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new)
      expect do
        described_class.refresh(project)
        described_class.refresh(project)
      end.to have_broadcasted_to(stream).once
    end
  end
end
