# frozen_string_literal: true

require "rails_helper"

RSpec.describe Home::Deferral do
  describe "validazioni" do
    it "è valido con account, organizzazione, chiave e scadenza" do
      expect(build(:home_deferral)).to be_valid
    end

    it "rifiuta una chiave vuota" do
      deferral = build(:home_deferral, card_key: "  ")

      expect(deferral).not_to be_valid
      expect(deferral.errors[:card_key]).to be_present
    end

    it "rifiuta una scadenza mancante" do
      deferral = build(:home_deferral, until_at: nil)

      expect(deferral).not_to be_valid
      expect(deferral.errors[:until_at]).to be_present
    end

    it "toglie gli spazi attorno alla chiave" do
      deferral = create(:home_deferral, card_key: "  agent_plan:abc  ")

      expect(deferral.card_key).to eq("agent_plan:abc")
    end

    it "non permette due rimandi dello stesso account sulla stessa card" do
      esistente = create(:home_deferral)

      expect do
        create(:home_deferral, account: esistente.account, card_key: esistente.card_key)
      end.to raise_error(ActiveRecord::RecordNotUnique)
    end

    it "permette a due persone diverse di rimandare la stessa card" do
      esistente = create(:home_deferral)

      expect do
        create(:home_deferral, card_key: esistente.card_key)
      end.to change(described_class, :count).by(1)
    end
  end

  describe "l'organizzazione non si cambia dopo la creazione" do
    # Rails solleva invece di ignorare in silenzio (raise_on_assign_to_attr_readonly): meglio così,
    # uno spostamento cross-tenant deve rompere subito, non riuscire a metà.
    it "rifiuta di spostare il rimando in un'altra organizzazione" do
      deferral = create(:home_deferral)
      originale = deferral.organization_id

      expect { deferral.update(organization_id: create(:organization).id) }
        .to raise_error(ActiveRecord::ReadonlyAttributeError, /organization_id/)

      expect(deferral.reload.organization_id).to eq(originale)
    end
  end

  describe "scope" do
    it "considera vivo solo un rimando non ancora scaduto" do
      vivo = create(:home_deferral)
      scaduto = create(:home_deferral, :expired)

      expect(described_class.live).to include(vivo)
      expect(described_class.live).not_to include(scaduto)
      expect(described_class.expired).to contain_exactly(scaduto)
    end
  end

  describe ".live_keys_for" do
    let(:account) { create(:account) }
    let(:organization) { create(:organization) }

    it "torna le sole chiavi vive di quell'account in quell'organizzazione" do
      viva = create(:home_deferral, account:, organization:)
      create(:home_deferral, :expired, account:, organization:)
      di_un_altro = create(:home_deferral, organization:)

      chiavi = described_class.live_keys_for(account, organization:)

      expect(chiavi).to contain_exactly(viva.card_key)
      expect(chiavi).not_to include(di_un_altro.card_key)
    end

    # Un rimando fatto in un'altra organizzazione non c'entra niente con questa coda: contarlo
    # farebbe leggere «1 rimandata» sopra una coda che non ne ha nessuna.
    it "ignora i rimandi che questo account ha fatto in un'altra organizzazione" do
      altrove = create(:home_deferral, account:, organization: create(:organization))

      chiavi = described_class.live_keys_for(account, organization:)

      expect(chiavi).to be_empty
      expect(chiavi).not_to include(altrove.card_key)
    end

    it "torna un insieme vuoto per chi non ha rimandato niente" do
      expect(described_class.live_keys_for(create(:account), organization:)).to be_empty
    end
  end

  describe "cascata" do
    it "sparisce con l'account" do
      deferral = create(:home_deferral)

      expect { deferral.account.destroy }.to change(described_class, :count).by(-1)
    end
  end
end
