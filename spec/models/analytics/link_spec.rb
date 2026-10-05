# frozen_string_literal: true

require "rails_helper"

RSpec.describe Analytics::Link, type: :model do
  it "factory valida e genera uno slug imprevedibile alla creazione" do
    link = create(:analytics_link)
    expect(link).to be_valid
    expect(link.slug).to be_present
    expect(link.slug.length).to be >= 16
  end

  it "slug unico" do
    existing = create(:analytics_link)
    expect(build(:analytics_link, slug: existing.slug)).not_to be_valid
  end

  it "password opzionale: senza → non protetto; con → protetto e autenticabile" do
    plain = create(:analytics_link)
    expect(plain.password_protected?).to be(false)

    protected_link = create(:analytics_link, :with_password)
    expect(protected_link.password_protected?).to be(true)
    expect(protected_link.authenticate("segreto123")).to be_truthy
    expect(protected_link.authenticate("sbagliata")).to be(false)
  end

  it "scope active esclude i link disabilitati" do
    on = create(:analytics_link)
    create(:analytics_link, :disabled)
    expect(described_class.active).to contain_exactly(on)
  end

  it "la cancellazione del progetto elimina i link (dependent + FK cascade)" do
    link = create(:analytics_link)
    expect { link.project.destroy! }.to change(described_class, :count).by(-1)
  end
end
