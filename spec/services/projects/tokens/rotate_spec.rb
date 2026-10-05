require "rails_helper"

RSpec.describe Projects::Tokens::Rotate, type: :service do
  let(:project) { create(:project) }
  let!(:old_token) { create(:project_token, project:, name: "Old") }
  let(:host) { "bugs.example.com" }

  subject(:result) { described_class.call(token: old_token, host:) }

  it "ritorna Result.ok con il nuovo token emesso e quello revocato" do
    expect(result).to be_ok
    expect(result.value[:new]).to include(:token, :secret, :dsn)
    expect(result.value[:revoked]).to eq(old_token)
  end

  it "emette un nuovo token attivo e revoca il vecchio" do
    new_token = result.value[:new][:token]

    expect(new_token).to be_persisted
    expect(new_token).not_to be_revoked
    expect(old_token.reload).to be_revoked
  end

  it "il nuovo token eredita name e scopes del vecchio se non specificati" do
    new_token = result.value[:new][:token]
    expect(new_token.name).to eq("Old")
    expect(new_token.scopes).to eq(old_token.scopes)
  end

  # CYRA-716 — ruotare non deve trasformare in silenzio una credenziale a termine in una perpetua.
  describe "scadenza (CYRA-716)" do
    it "il nuovo token eredita la DURATA del vecchio, non la sua data" do
      a_termine = create(:project_token, project:, expires_at: 90.days.from_now)

      travel 10.days do
        nuovo = described_class.call(token: a_termine, host:).value[:new][:token]

        expect(nuovo.expires_at).to be_within(1.minute).of(90.days.from_now)
      end
    end

    it "ruotare un token GIÀ scaduto riparte dalla stessa durata invece di fallire" do
      scaduto = create(:project_token, :expired, project:, expires_at: 30.days.ago)
      scaduto.update_column(:created_at, 60.days.ago)

      nuovo = described_class.call(token: scaduto, host:).value[:new][:token]

      # La durata è in secondi, non in giorni di calendario: col cambio dell'ora in mezzo i due
      # differiscono di un'ora.
      expect(nuovo.expires_at).to be_within(1.minute).of(Time.current + 30.days.to_i)
    end

    it "un token senza scadenza resta senza scadenza dopo la rotazione" do
      nuovo = result.value[:new][:token]
      expect(nuovo.expires_at).to be_nil
    end
  end

  it "lascia un solo token attivo sul progetto dopo la rotazione" do
    result
    expect(project.tokens.active.count).to eq(1)
  end

  it "ritorna Result.err R422-TOKEN-003 e NON revoca il vecchio se l'emissione fallisce" do
    allow(Projects::Tokens::Issue).to receive(:call)
      .and_return(Result.err(AppError.new("boom", code: "R422-TOKEN-001")))

    expect(result).to be_err
    expect(result.error.code).to eq("R422-TOKEN-003")
    expect(old_token.reload).not_to be_revoked
  end
end
