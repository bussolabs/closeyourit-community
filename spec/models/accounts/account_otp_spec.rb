# frozen_string_literal: true

require "rails_helper"

RSpec.describe Accounts::Account, "2FA TOTP (CYRA-170)", type: :model do
  let(:account) { create(:account) }

  describe "#otp_enabled?" do
    it "è falso di default" do
      expect(account).not_to be_otp_enabled
    end
  end

  describe "#provision_otp_secret!" do
    it "genera un seme quando manca" do
      expect { account.provision_otp_secret! }
        .to change { account.otp_secret.present? }.from(false).to(true)
    end

    it "riusa il seme già presente (QR stabile tra i refresh del setup)" do
      first = account.provision_otp_secret!
      expect(account.provision_otp_secret!).to eq(first)
    end
  end

  describe "#verify_otp" do
    before { account.provision_otp_secret! }

    it "accetta il codice corrente dell'app" do
      expect(account.verify_otp(ROTP::TOTP.new(account.otp_secret).now)).to be(true)
    end

    it "rifiuta un codice errato, vuoto o nil" do
      expect(account.verify_otp("000000")).to be(false)
      expect(account.verify_otp("")).to be(false)
      expect(account.verify_otp(nil)).to be(false)
    end

    it "rifiuta quando il 2FA non è provisionato (nessun seme)" do
      expect(create(:account).verify_otp("123456")).to be(false)
    end

    # FIX-8: anti-replay. Lo stesso codice non deve essere riutilizzabile nella sua finestra (~90s).
    it "rifiuta il RIUSO dello stesso codice (replay)" do
      code = ROTP::TOTP.new(account.otp_secret).now
      expect(account.verify_otp(code)).to be(true)
      expect(account.verify_otp(code)).to be(false)
    end

    it "registra l'istante dell'ultimo codice consumato (otp_last_step_at)" do
      expect { account.verify_otp(ROTP::TOTP.new(account.otp_secret).now) }
        .to change { account.reload.otp_last_step_at }.from(nil)
    end

    # FIX-E: consumo ATOMICO — un'istanza concorrente (seconda richiesta) collo STESSO codice è rifiutata
    # dal guard SQL condizionato, anche se il filtro `after:` in memoria fosse stale.
    it "rifiuta un'istanza concorrente che riusa lo stesso codice (guard atomico)" do
      code = ROTP::TOTP.new(account.otp_secret).now
      expect(account.verify_otp(code)).to be(true)

      concurrent = Accounts::Account.find(account.id)
      expect(concurrent.verify_otp(code)).to be(false)
    end
  end

  describe "#enable_otp!" do
    it "attiva il 2FA e ritorna 10 codici di recupero in chiaro" do
      codes = account.enable_otp!
      expect(account.reload).to be_otp_enabled
      expect(codes.size).to eq(Accounts::Constants::OTP_RECOVERY_CODES)
      expect(account.otp_recovery_codes.count).to eq(Accounts::Constants::OTP_RECOVERY_CODES)
    end

    it "provisiona il seme se non c'era" do
      expect { account.enable_otp! }.to change { account.reload.otp_secret.present? }.to(true)
    end

    # FIX-6: entropia dei codici di recupero. hex(16) = 128 bit (32 hex char), non più hex(5) = 40 bit.
    it "genera codici di recupero da 128 bit (32 caratteri esadecimali)" do
      expect(account.enable_otp!).to all(match(/\A[0-9a-f]{32}\z/))
    end
  end

  describe "#disable_otp!" do
    it "azzera seme, stato e codici di recupero" do
      account.enable_otp!
      account.disable_otp!
      account.reload
      expect(account).not_to be_otp_enabled
      expect(account.otp_secret).to be_nil
      expect(account.otp_recovery_codes.count).to eq(0)
    end
  end

  describe "#verify_recovery_code" do
    let!(:codes) { account.enable_otp! }

    it "accetta un codice valido una sola volta (monouso)" do
      code = codes.first
      expect(account.verify_recovery_code(code)).to be(true)
      expect(account.verify_recovery_code(code)).to be(false)
    end

    # FIX-7: consumo atomico (UPDATE condizionato su unused) — consuma esattamente la riga combaciante.
    it "consuma esattamente una riga (update condizionato su unused)" do
      digest = described_class.digest_recovery_code(codes.first)
      expect { account.verify_recovery_code(codes.first) }
        .to change { account.otp_recovery_codes.unused.where(code_digest: digest).count }.from(1).to(0)
    end

    it "è tollerante a maiuscole/trattini/spazi" do
      expect(account.verify_recovery_code("  #{codes.last.upcase}  ")).to be(true)
    end

    it "rifiuta un codice sconosciuto" do
      expect(account.verify_recovery_code("nope")).to be(false)
    end
  end

  describe ".digest_recovery_code" do
    it "normalizza prima di digerire (stesso digest per varianti equivalenti)" do
      expect(described_class.digest_recovery_code("AB-cd"))
        .to eq(described_class.digest_recovery_code("abcd"))
    end

    it "è nil per input vuoto" do
      expect(described_class.digest_recovery_code("   ")).to be_nil
    end
  end

  describe "cifratura del seme (encrypts :otp_secret)" do
    it "il seme non è in chiaro nel DB ma è leggibile decifrato" do
      account.update!(otp_secret: "JBSWY3DPEHPK3PXP")
      raw = described_class.connection.select_value(
        described_class.sanitize_sql([ "SELECT otp_secret FROM accounts WHERE id = ?", account.id ])
      )
      expect(raw).not_to include("JBSWY3DPEHPK3PXP")
      expect(account.reload.otp_secret).to eq("JBSWY3DPEHPK3PXP")
    end
  end
end
