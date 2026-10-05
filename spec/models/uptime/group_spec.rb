# frozen_string_literal: true

require "rails_helper"

RSpec.describe Uptime::Group, type: :model do
  describe "associazioni" do
    it "l'organizzazione è obbligatoria" do
      expect(build(:uptime_group, organization: nil)).not_to be_valid
    end

    it "created_by è opzionale" do
      expect(build(:uptime_group, created_by: nil)).to be_valid
    end

    it "espone i monitor associati" do
      group = create(:uptime_group)
      monitor = create(:uptime_monitor, group: group,
                       project: create(:project, organization: group.organization))
      expect(group.monitors).to include(monitor)
    end
  end

  describe "validazioni" do
    it "richiede il nome" do
      expect(build(:uptime_group, name: nil)).not_to be_valid
    end

    it "è invalida con nome vuoto" do
      expect(build(:uptime_group, name: "")).not_to be_valid
    end

    it "è invalida con nome di soli spazi" do
      expect(build(:uptime_group, name: "   ")).not_to be_valid
    end

    it "rifiuta uno slug duplicato nella stessa organizzazione (safety net)" do
      org = create(:organization)
      create(:uptime_group, organization: org, name: "Alfa") # slug "alfa"
      duplicato = build(:uptime_group, organization: org, name: "Altro", slug: "alfa")
      expect(duplicato).not_to be_valid
      expect(duplicato.errors[:slug]).to be_present
    end

    it "consente lo stesso slug in organizzazioni diverse" do
      create(:uptime_group, organization: create(:organization), name: "Api")
      altra = build(:uptime_group, organization: create(:organization), name: "Api")
      expect(altra).to be_valid
    end
  end

  describe "slug" do
    it "genera lo slug dal nome alla creazione" do
      expect(create(:uptime_group, name: "Servizi Critici").slug).to eq("servizi-critici")
    end

    it "non riscrive lo slug al rename (URL pubblico stabile)" do
      group = create(:uptime_group, name: "Api Pubbliche")
      originale = group.slug
      group.update!(name: "Api Interne")
      expect(group.slug).to eq(originale)
    end

    it "auto-suffissa lo slug su collisione nella stessa organizzazione" do
      org = create(:organization)
      primo = create(:uptime_group, organization: org, name: "Core")
      secondo = create(:uptime_group, organization: org, name: "core")
      expect(primo.slug).to eq("core")
      expect(secondo.slug).to eq("core-2")
    end

    it "usa 'group' come base se il nome non produce slug" do
      expect(create(:uptime_group, name: "///").slug).to eq("group")
    end
  end

  describe "normalizzazione nome" do
    it "rimuove gli spazi ai bordi" do
      expect(create(:uptime_group, name: "  Reti  ").name).to eq("Reti")
    end
  end

  describe "scope" do
    it ".ordered ordina per nome" do
      org = create(:organization)
      beta = create(:uptime_group, organization: org, name: "Beta")
      alfa = create(:uptime_group, organization: org, name: "Alfa")
      expect(org.uptime_groups.ordered.to_a).to eq([ alfa, beta ])
    end

    it ".public_status include solo i gruppi pubblicati" do
      org = create(:organization)
      pubblico = create(:uptime_group, :published, organization: org)
      privato = create(:uptime_group, organization: org)
      expect(org.uptime_groups.public_status).to include(pubblico)
      expect(org.uptime_groups.public_status).not_to include(privato)
    end
  end

  describe "#public?" do
    it "è true quando la status page è pubblicata" do
      expect(build(:uptime_group, :published).public?).to be true
    end

    it "è false quando non è pubblicata" do
      expect(build(:uptime_group, public_status_enabled: false).public?).to be false
    end
  end

  describe "cancellazione" do
    it "nullifica i monitor associati (i monitor sopravvivono senza gruppo)" do
      group = create(:uptime_group)
      monitor = create(:uptime_monitor, group: group,
                       project: create(:project, organization: group.organization))
      group.destroy
      expect(monitor.reload.group_id).to be_nil
    end
  end
end
