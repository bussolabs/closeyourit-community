# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Job del cockpit SEO", type: :job do
  describe Seo::DispatchAuditsJob do
    it "accoda un giro solo per i siti scaduti" do
      scaduto = create(:seo_site, :due)
      create(:seo_site, :audited)
      create(:seo_site, :due, :disabled)

      expect { described_class.perform_now }
        .to have_enqueued_job(Seo::AuditSiteJob).with(scaduto.id).exactly(:once)
    end
  end

  describe Seo::AuditSiteJob do
    it "visita il sito" do
      site = create(:seo_site)
      allow(Seo::AuditSite).to receive(:call)

      described_class.perform_now(site.id)

      expect(Seo::AuditSite).to have_received(:call).with(site: site)
    end

    it "un sito sparito o in pausa non fa niente e non solleva" do
      in_pausa = create(:seo_site, :disabled)
      allow(Seo::AuditSite).to receive(:call)

      described_class.perform_now(in_pausa.id)
      described_class.perform_now(SecureRandom.uuid)

      expect(Seo::AuditSite).not_to have_received(:call)
    end

    it "gira sulla coda seo, che è servita da un worker" do
      # Una coda che nessun pool serve accumula job per sempre senza un solo errore: è già
      # successo in produzione, e questo test è il freno.
      expect(described_class.new.queue_name).to eq("seo")
      served = YAML.load_file(Rails.root.join("config/queue.yml"), aliases: true)
                   .fetch("default").fetch("workers").flat_map { |worker| worker["queues"] }
      expect(served).to include("seo")
    end
  end

  describe Seo::PruneJob do
    it "pota le pagine che non si vedono da mesi e i giri antichi, ma non i rilievi" do
      site = create(:seo_site)
      vecchia = create(:seo_page, site:, last_seen_at: 100.days.ago)
      recente = create(:seo_page, site:, last_seen_at: 1.day.ago)
      rilievo = create(:seo_issue, site:, page: nil, check_key: "duplicate_title")
      audit_antico = create(:seo_audit, site:, started_at: 200.days.ago)
      audit_recente = create(:seo_audit, site:, started_at: 2.days.ago)

      described_class.perform_now

      expect(Seo::Page.exists?(vecchia.id)).to be(false)
      expect(Seo::Page.exists?(recente.id)).to be(true)
      expect(Seo::Audit.exists?(audit_antico.id)).to be(false)
      expect(Seo::Audit.exists?(audit_recente.id)).to be(true)
      # I rilievi sono la memoria di quanto è rimasto aperto un problema: non si potano mai.
      expect(Seo::Issue.exists?(rilievo.id)).to be(true)
    end
  end
end
