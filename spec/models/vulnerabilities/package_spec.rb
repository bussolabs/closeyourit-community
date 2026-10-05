# frozen_string_literal: true

require "rails_helper"

RSpec.describe Vulnerabilities::Package, type: :model do
  it "factory valida" do
    expect(build(:vulnerability_package)).to be_valid
  end

  it "richiede nome, versione ed ecosistema" do
    expect(build(:vulnerability_package, name: nil)).not_to be_valid
    expect(build(:vulnerability_package, version: nil)).not_to be_valid
    expect(build(:vulnerability_package, ecosystem: nil)).not_to be_valid
  end

  it "la stessa coppia nome+versione non si ripete nello stesso manifest" do
    package = create(:vulnerability_package, name: "rails", version: "7.0.0")
    duplicate = build(:vulnerability_package, manifest: package.manifest, name: "rails", version: "7.0.0")
    expect(duplicate).not_to be_valid

    # Due versioni dello stesso pacchetto convivono: è normale in un lockfile npm.
    other_version = build(:vulnerability_package, manifest: package.manifest, name: "rails", version: "7.1.0")
    expect(other_version).to be_valid
  end

  it "#coordinates e #osv_key descrivono il pacchetto per la query" do
    package = build(:vulnerability_package, name: "lodash", version: "4.17.15",
                                            ecosystem: Vulnerabilities::Ecosystem::NPM)
    expect(package.coordinates).to eq("lodash@4.17.15")
    expect(package.osv_key).to eq([ "npm", "lodash", "4.17.15" ])
  end

  it "scope direct isola le dipendenze dichiarate dal progetto" do
    direct = create(:vulnerability_package, :direct)
    create(:vulnerability_package, manifest: direct.manifest)

    expect(described_class.direct).to contain_exactly(direct)
  end
end
