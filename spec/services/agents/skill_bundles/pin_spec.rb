# frozen_string_literal: true

require "rails_helper"

RSpec.describe Agents::SkillBundles::Pin do
  let(:organization) { create(:organization) }
  let(:pin) { { repo: "bussolabs/closeyourit-skills", ref: "v0.1.0", version: "0.1.0", digest: "a1b2c3d" } }

  describe ".call" do
    it "crea il singleton quando l'org non ha ancora un bundle e ritorna Result.ok" do
      result = described_class.call(organization:, **pin)

      expect(result).to be_ok
      expect(result.value).to be_persisted
      expect(organization.reload.skill_bundle).to eq(result.value)
      expect(result.value).to have_attributes(
        repo: "bussolabs/closeyourit-skills", ref: "v0.1.0", version: "0.1.0", digest: "a1b2c3d"
      )
    end

    it "aggiorna lo stesso record quando il bundle esiste già (upsert idempotente, resta un solo record)" do
      first = described_class.call(organization:, **pin).value

      result = described_class.call(
        organization:, repo: "bussolabs/closeyourit-skills", ref: "v0.2.0", version: "0.2.0", digest: "ffffff0"
      )

      expect(result).to be_ok
      expect(result.value.id).to eq(first.id)
      expect(organization.reload.skill_bundle.version).to eq("0.2.0")
      expect(Agents::SkillBundle.where(organization:).count).to eq(1)
    end

    it "normalizza il digest in minuscolo (verifica content-addressed case-insensitive)" do
      result = described_class.call(organization:, **pin.merge(digest: "A1B2C3D"))

      expect(result).to be_ok
      expect(result.value.digest).to eq("a1b2c3d")
    end

    it "ritorna Result.err R422-AGENT-006 e non persiste quando il repo non è owner/name" do
      result = described_class.call(organization:, **pin.merge(repo: "non-un-repo"))

      expect(result).to be_err
      expect(result.error.code).to eq("R422-AGENT-006")
      expect(result.error.details).to have_key(:repo)
      expect(organization.reload.skill_bundle).to be_nil
    end

    it "ritorna Result.err R422-AGENT-006 quando il digest non è esadecimale valido" do
      result = described_class.call(organization:, **pin.merge(digest: "zzz"))

      expect(result).to be_err
      expect(result.error.code).to eq("R422-AGENT-006")
    end

    it "gestisce la race sul primo pin: RecordNotUnique dall'INSERT concorrente non dà 500 ma aggiorna il singleton" do
      # Vincitore della race, già committato da una richiesta concorrente sullo stesso org.
      winner = create(:agent_skill_bundle, organization:, ref: "v0.0.9", version: "0.0.9", digest: "0000000")
      # Questa richiesta non vede ancora il bundle (check-then-insert): prende il ramo build+insert e
      # l'unique index a valle rifiuta l'INSERT con RecordNotUnique; solo dopo il reload trova il vincitore.
      loser = Agents::SkillBundle.new(organization:)
      allow(organization).to receive(:skill_bundle).and_return(nil, winner)
      allow(organization).to receive(:build_skill_bundle).and_return(loser)
      allow(loser).to receive(:save!)
        .and_raise(ActiveRecord::RecordNotUnique.new("duplicate key value violates unique constraint"))

      result = described_class.call(organization:, **pin)

      expect(result).to be_ok
      expect(result.value).to eq(winner)
      expect(winner.reload.version).to eq("0.1.0")
      expect(Agents::SkillBundle.where(organization:).count).to eq(1)
    end

    context "monotonico per versione (anti-downgrade CYAU-68)" do
      before { create(:agent_skill_bundle, organization:, ref: "v0.2.0", version: "0.2.0", digest: "bbbbbbb") }

      it "rifiuta un downgrade con Result.err R409-AGENT-002 e NON regredisce il pin già presente" do
        result = described_class.call(organization:, **pin.merge(ref: "v0.1.0", version: "0.1.0"))

        expect(result).to be_err
        expect(result.error.code).to eq("R409-AGENT-002")
        expect(result.error.status).to eq(:conflict)
        expect(organization.reload.skill_bundle.version).to eq("0.2.0")
      end

      it "accetta la stessa versione (idempotenza: non è un downgrade)" do
        result = described_class.call(organization:, **pin.merge(ref: "v0.2.0", version: "0.2.0", digest: "ccccccc"))

        expect(result).to be_ok
        expect(organization.reload.skill_bundle).to have_attributes(version: "0.2.0", digest: "ccccccc")
      end

      it "accetta una versione superiore" do
        result = described_class.call(organization:, **pin.merge(ref: "v0.3.0", version: "0.3.0", digest: "ddddddd"))

        expect(result).to be_ok
        expect(organization.reload.skill_bundle.version).to eq("0.3.0")
      end

      it "con force: true bypassa il check e applica il downgrade (rollback intenzionale)" do
        result = described_class.call(organization:, **pin.merge(ref: "v0.1.0", version: "0.1.0"), force: true)

        expect(result).to be_ok
        expect(organization.reload.skill_bundle.version).to eq("0.1.0")
      end

      it "serializza sotto lock di riga: rivaluta il guard sul valore ricaricato, non sulla lettura sporca" do
        # Il pin corrente è 0.2.0. Simula un update concorrente committato (→ 0.5.0) DOPO la prima lettura
        # ma prima che questa richiesta acquisisca il lock: with_lock deve ricaricare la riga e il guard
        # vedere 0.5.0, così un pin 0.3.0 — che contro la lettura sporca 0.2.0 sarebbe passato — è respinto.
        current = organization.skill_bundle
        allow(organization).to receive(:skill_bundle).and_return(current)
        allow(current).to receive(:with_lock).and_wrap_original do |original, &block|
          Agents::SkillBundle.where(id: current.id).update_all(version: "0.5.0")
          original.call(&block)
        end

        result = described_class.call(organization:, **pin.merge(ref: "v0.3.0", version: "0.3.0", digest: "ddddddd"))

        expect(result).to be_err
        expect(result.error.code).to eq("R409-AGENT-002")
        expect(organization.reload.skill_bundle.version).to eq("0.5.0")
      end
    end

    context "versione non-semver (confronto impossibile → fail-open, nessun crash)" do
      it "applica un pin con versione in ARRIVO non-semver senza sollevare (non la blocca)" do
        create(:agent_skill_bundle, organization:, ref: "v0.2.0", version: "0.2.0", digest: "bbbbbbb")

        expect { described_class.call(organization:, **pin.merge(ref: "latest", version: "latest", digest: "eeeeeee")) }
          .not_to raise_error
        expect(organization.reload.skill_bundle.version).to eq("latest")
      end

      it "applica un pin quando la versione GIÀ pinnata è non-semver (nessun confronto, nessun crash)" do
        create(:agent_skill_bundle, organization:, ref: "nightly", version: "nightly", digest: "bbbbbbb")

        result = described_class.call(organization:, **pin.merge(ref: "v0.1.0", version: "0.1.0"))

        expect(result).to be_ok
        expect(organization.reload.skill_bundle.version).to eq("0.1.0")
      end
    end
  end
end
