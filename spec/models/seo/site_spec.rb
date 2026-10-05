# frozen_string_literal: true

require "rails_helper"

RSpec.describe Seo::Site, type: :model do
  it "factory valida" do
    expect(build(:seo_site)).to be_valid
  end

  it "toglie la barra finale dall'indirizzo: due URL uguali non devono sembrare diverse" do
    site = build(:seo_site, base_url: "  https://example.com/  ")
    site.valid?
    expect(site.base_url).to eq("https://example.com")
  end

  it "pretende un indirizzo http o https" do
    expect(build(:seo_site, base_url: "ftp://example.com")).not_to be_valid
    expect(build(:seo_site, base_url: "example.com")).not_to be_valid
    expect(build(:seo_site, base_url: nil)).not_to be_valid
  end

  it "rifiuta gli indirizzi che puntano dentro casa" do
    aggregate_failures do
      expect(build(:seo_site, base_url: "http://127.0.0.1:3000")).not_to be_valid
      expect(build(:seo_site, base_url: "http://10.0.0.9")).not_to be_valid
      expect(build(:seo_site, base_url: "http://169.254.169.254")).not_to be_valid
      expect(build(:seo_site, base_url: "http://localhost:3011")).not_to be_valid
      expect(build(:seo_site, base_url: "http://db.internal")).not_to be_valid
    end
  end

  it "tiene il numero di pagine dentro un tetto" do
    expect(build(:seo_site, max_pages: 0)).not_to be_valid
    expect(build(:seo_site, max_pages: described_class::MAX_PAGES_CEILING + 1)).not_to be_valid
    expect(build(:seo_site, max_pages: 50)).to be_valid
  end

  it "un solo sito per progetto e ambiente" do
    site = create(:seo_site)
    duplicate = build(:seo_site, project: site.project, environment: site.environment)
    expect(duplicate).not_to be_valid
  end

  it "l'ambiente dev'essere dichiarato dal progetto" do
    site = build(:seo_site)
    site.environment = create(:environment, organization: site.project.organization)
    expect(site).not_to be_valid
    expect(site.errors[:environment_id]).to be_present
  end

  it "non nasce su un progetto senza piattaforma web" do
    project = create(:project)
    environment = create(:environment, organization: project.organization)
    project.environments << environment

    site = described_class.new(project:, environment:, base_url: "https://example.com")
    expect(site).not_to be_valid
    expect(site.errors[:project_id]).to be_present
  end

  it "la capability serve ad ammettere, non a bloccare per sempre chi è già dentro" do
    site = create(:seo_site)
    site.project.project_platforms.destroy_all

    # Ogni giro salva il sito per aggiornare le date: se la capability rivalidasse anche in update,
    # il cockpit si fermerebbe in silenzio (è successo con i monitor uptime).
    expect(site.update(last_audited_at: Time.current)).to be(true)
  end

  describe "cadenza" do
    it "l'intervallo dipende dalla frequenza scelta" do
      expect(build(:seo_site).interval).to eq(1.day)
      expect(build(:seo_site, :weekly).interval).to eq(7.days)
    end

    it "calcola la prossima scadenza da un istante dato" do
      now = Time.zone.parse("2026-08-14 10:00:00")
      expect(build(:seo_site).next_audit_after(now)).to eq(now + 1.day)
    end
  end

  describe ".due" do
    it "prende i siti mai visitati e quelli scaduti, non gli altri" do
      never = create(:seo_site)
      expired = create(:seo_site, :due)
      future = create(:seo_site, :audited)
      disabled = create(:seo_site, :due, :disabled)

      due = described_class.due
      expect(due).to include(never, expired)
      expect(due).not_to include(future, disabled)
    end
  end

  it "sa contare i propri rilievi aperti senza contare quelli chiusi" do
    site = create(:seo_site)
    create(:seo_issue, site:, check_key: "missing_h1")
    create(:seo_issue, :resolved, site:, check_key: "noindex", page: nil)

    expect(site.open_issues_count).to eq(1)
  end
end
