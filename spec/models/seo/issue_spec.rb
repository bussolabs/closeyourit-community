# frozen_string_literal: true

require "rails_helper"

RSpec.describe Seo::Issue, type: :model do
  it "factory valida" do
    expect(build(:seo_issue)).to be_valid
  end

  it "nasce aperto" do
    expect(create(:seo_issue)).to be_status_open
  end

  it "accetta solo chiavi di controllo che esistono davvero" do
    expect(build(:seo_issue, check_key: "controllo_inventato")).not_to be_valid
    expect(build(:seo_issue, check_key: nil)).not_to be_valid
  end

  it "lo stesso controllo sulla stessa pagina esiste una volta sola" do
    issue = create(:seo_issue)
    duplicate = build(:seo_issue, site: issue.site, page: issue.page, check_key: issue.check_key)
    expect(duplicate).not_to be_valid
  end

  it "anche i rilievi d'insieme si deduplicano, benché non abbiano una pagina" do
    issue = create(:seo_issue, :site_scoped)
    duplicate = build(:seo_issue, :site_scoped, site: issue.site)

    # In PostgreSQL due NULL non collidono: senza `nulls_not_distinct` sull'indice questo passerebbe
    # e il rilievo si duplicherebbe a ogni giro.
    expect(duplicate).not_to be_valid
    expect { duplicate.save!(validate: false) }.to raise_error(ActiveRecord::RecordNotUnique)
  end

  it "lo stesso controllo su pagine diverse resta un rilievo per pagina" do
    issue = create(:seo_issue)
    other_page = create(:seo_page, site: issue.site)
    expect(build(:seo_issue, site: issue.site, page: other_page, check_key: issue.check_key)).to be_valid
  end

  describe "#touch_seen!" do
    it "riconferma un rilievo aperto aggiornando prova e gravità" do
      issue = create(:seo_issue, severity: :medium, last_seen_at: 2.days.ago)
      now = Time.current

      issue.touch_seen!(now, { "url" => "https://example.com/altra" }, :high)

      expect(issue.reload.last_seen_at).to be_within(1.second).of(now)
      expect(issue.evidence["url"]).to eq("https://example.com/altra")
      expect(issue).to be_severity_high
    end

    it "un rilievo ignorato resta ignorato quando il problema si ripresenta" do
      issue = create(:seo_issue, :ignored, severity: :low)

      issue.touch_seen!(Time.current, { "url" => "https://example.com/" }, :critical)

      # Una decisione presa non si rimette in lista da sola: né lo stato né la gravità
      # ricominciano a gridare.
      expect(issue.reload).to be_status_ignored
      expect(issue).to be_severity_low
    end
  end

  it "ordina mettendo davanti ciò che fa più male" do
    site = create(:seo_site)
    low = create(:seo_issue, site:, severity: :low, check_key: "title_too_long")
    critical = create(:seo_issue, site:, severity: :critical, check_key: "noindex")

    expect(site.issues.by_severity.first).to eq(critical)
    expect(site.issues.by_severity.last).to eq(low)
  end

  it "promuovibile solo ciò che è aperto e grave" do
    site = create(:seo_site)
    critical = create(:seo_issue, site:, severity: :critical, check_key: "noindex")
    create(:seo_issue, site:, severity: :low, check_key: "title_too_long")
    create(:seo_issue, :ignored, site:, severity: :high, check_key: "missing_h1")

    expect(site.issues.promotable).to contain_exactly(critical)
  end

  it "conosce il proprio controllo e il progetto a cui appartiene" do
    issue = create(:seo_issue, check_key: "missing_h1")

    expect(issue.check).to eq(Seo::Check.new("missing_h1"))
    expect(issue.area).to eq("structure")
    expect(issue.project).to eq(issue.site.project)
  end

  it "sa ancora di cosa parlava anche se la pagina è sparita" do
    issue = create(:seo_issue)
    url = issue.page.url
    issue.page.destroy!

    expect(issue.reload.url).to eq(url)
  end

  it "#promoted? dipende dal ticket collegato" do
    expect(build(:seo_issue)).not_to be_promoted
    expect(create(:seo_issue, :promoted)).to be_promoted
  end
end
