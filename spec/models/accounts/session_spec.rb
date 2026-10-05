# frozen_string_literal: true

require "rails_helper"

RSpec.describe Accounts::Session, type: :model do
  it "produce una sessione valida" do
    expect(build(:session)).to be_valid
  end

  it "appartiene a un account" do
    session = create(:session)
    expect(session.account).to be_a(Accounts::Account)
  end

  it "viene distrutta insieme all'account (dependent: :destroy)" do
    session = create(:session)
    expect { session.account.destroy }.to change(Accounts::Session, :count).by(-1)
  end

  describe "scadenza e idle (CYRA-170)" do
    describe "#expired?" do
      it "è vero quando expires_at è nel passato" do
        expect(build(:session, expires_at: 1.minute.ago)).to be_expired
      end

      it "è falso quando expires_at è nel futuro" do
        expect(build(:session, expires_at: 1.hour.from_now)).not_to be_expired
      end

      it "è falso quando expires_at è nil (dato incompleto → nessun logout accidentale)" do
        expect(build(:session, expires_at: nil)).not_to be_expired
      end
    end

    describe "#idle?" do
      it "è vero quando last_active_at è oltre la soglia di inattività" do
        stale = (Accounts::Constants::SESSION_IDLE_TIMEOUT + 1.minute).ago
        expect(build(:session, last_active_at: stale)).to be_idle
      end

      it "è falso quando l'attività è recente" do
        expect(build(:session, last_active_at: 1.minute.ago)).not_to be_idle
      end

      it "è falso quando last_active_at è nil" do
        expect(build(:session, last_active_at: nil)).not_to be_idle
      end
    end

    describe ".active" do
      it "include solo le sessioni non scadute e non idle" do
        live = create(:session)
        create(:session, :expired)
        create(:session, :idle)

        expect(Accounts::Session.active).to contain_exactly(live)
      end
    end
  end
end
