# frozen_string_literal: true

require "rails_helper"

# CYRA-728 — la regola che decide QUANDO serve una conferma esplicita. Vive in un service e non nel
# controller perché la stessa risposta deve valere per il browser e per la riga di comando: due
# implementazioni gemelle sarebbero due politiche che prima o poi divergono.
RSpec.describe Authorization::DangerousAction do
  describe ".confirmation_required?" do
    it "una chiave pericolosa su una richiesta che scrive pretende conferma" do
      expect(described_class.confirmation_required?(key: "projects.delete", request_method: "DELETE")).to be(true)
    end

    it "una chiave NON pericolosa non pretende niente" do
      expect(described_class.confirmation_required?(key: "projects.edit", request_method: "DELETE")).to be(false)
    end

    it "una chiave sconosciuta non pretende niente (il Resolver la nega comunque)" do
      expect(described_class.confirmation_required?(key: "chiave.inventata", request_method: "POST")).to be(false)
    end

    it "leggere non è eseguire: GET e HEAD non chiedono conferma nemmeno su chiave pericolosa" do
      expect(described_class.confirmation_required?(key: "secrets.read", request_method: "GET")).to be(false)
      expect(described_class.confirmation_required?(key: "secrets.read", request_method: "HEAD")).to be(false)
    end

    it "vale per tutti i verbi che scrivono" do
      %w[POST PATCH PUT DELETE].each do |verbo|
        expect(described_class.confirmation_required?(key: "members.manage", request_method: verbo)).to be(true)
      end
    end
  end

  describe ".confirmed?" do
    it "riconosce le forme affermative che i due canali mandano" do
      %w[1 true yes on TRUE Yes].each do |valore|
        expect(described_class.confirmed?(valore)).to be(true)
      end
    end

    it "vale anche la conferma più forte: il nome ricopiato a mano" do
      expect(described_class.confirmed?("fleet")).to be(true)
    end

    it "assente o negata esplicitamente non è una conferma" do
      [ nil, "", "  ", "0", "false", "no", "off", "NO" ].each do |valore|
        expect(described_class.confirmed?(valore)).to be(false)
      end
    end
  end

  describe "il catalogo" do
    it "ha almeno una chiave pericolosa per ogni area che distrugge dati" do
      pericolose = Authorization::Catalog.all.select { |voce| voce[:dangerous] }.map { |voce| voce[:key] }
      expect(pericolose).to include("projects.delete", "permissions.manage", "members.manage", "organization.manage")
    end
  end
end
