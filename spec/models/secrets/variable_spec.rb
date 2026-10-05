require "rails_helper"

RSpec.describe Secrets::Variable, type: :model do
  # Helper: progetto con UN environment dichiarato, pronto per costruire variabili valide.
  def project_with_environment
    project = create(:project)
    env = create(:environment, organization: project.organization)
    project.environments << env
    [ project, env ]
  end

  describe "factory" do
    it "produce una variabile valida" do
      expect(build(:secret_variable)).to be_valid
    end
  end

  describe "associazioni" do
    it "appartiene a un progetto" do
      expect(build(:secret_variable, project: nil)).not_to be_valid
    end

    it "created_by è opzionale" do
      expect(build(:secret_variable, created_by: nil)).to be_valid
    end
  end

  describe "validazioni sul nome" do
    it "richiede name" do
      expect(build(:secret_variable, name: nil)).not_to be_valid
    end

    it "normalizza name in UPPER_SNAKE senza spazi" do
      variable = build(:secret_variable, name: "  db_url  ")
      variable.valid?
      expect(variable.name).to eq("DB_URL")
    end

    it "accetta un nome UPPER_SNAKE valido" do
      expect(build(:secret_variable, name: "DATABASE_URL")).to be_valid
    end

    it "rifiuta un nome con trattini" do
      expect(build(:secret_variable, name: "DB-URL")).not_to be_valid
    end

    it "rifiuta un nome che inizia con una cifra" do
      expect(build(:secret_variable, name: "1FOO")).not_to be_valid
    end

    it "rifiuta il prefisso riservato GITHUB_ (vincolo GitHub Actions)" do
      variable = build(:secret_variable, name: "GITHUB_TOKEN")
      expect(variable).not_to be_valid
      expect(variable.errors[:name]).to be_present
    end

    it "rifiuta i nomi dei bundle derivati" do
      %w[SECRETS_JSON KAMAL_SECRETS_JSON].each do |name|
        variable = build(:secret_variable, name:)
        expect(variable).not_to be_valid
        expect(variable.errors[:name]).to be_present
      end
    end
  end

  describe "validazioni sul valore" do
    it "accetta una stringa vuota impostata esplicitamente" do
      expect(build(:secret_variable, value: "")).to be_valid
    end

    it "rifiuta un valore null" do
      variable = build(:secret_variable, value: nil)

      expect(variable).not_to be_valid
      expect(variable.errors[:value]).to be_present
    end
  end

  describe "unicità nome per [progetto, ambiente]" do
    it "rifiuta un nome duplicato nello stesso progetto+ambiente" do
      existing = create(:secret_variable, name: "API_KEY")
      dup = build(:secret_variable, name: "API_KEY", project: existing.project, environment: existing.environment)
      expect(dup).not_to be_valid
    end

    it "ammette lo stesso nome in un ambiente diverso dello stesso progetto" do
      project, env_a = project_with_environment
      env_b = create(:environment, organization: project.organization)
      project.environments << env_b
      create(:secret_variable, name: "API_KEY", project:, environment: env_a, organization: project.organization)

      expect(build(:secret_variable, name: "API_KEY", project:, environment: env_b, organization: project.organization)).to be_valid
    end

    it "ammette lo stesso nome in un progetto diverso" do
      existing = create(:secret_variable, name: "API_KEY")
      expect(build(:secret_variable, name: "API_KEY")).to be_valid
      expect(existing.name).to eq("API_KEY")
    end
  end

  describe "binding all'ambiente (subset dichiarato dal progetto)" do
    it "è valido se l'ambiente è dichiarato dal progetto" do
      project, env = project_with_environment
      expect(build(:secret_variable, project:, environment: env, organization: project.organization)).to be_valid
    end

    it "è invalido se l'ambiente NON è dichiarato dal progetto" do
      project = create(:project)
      undeclared = create(:environment, organization: project.organization)
      expect(build(:secret_variable, project:, environment: undeclared, organization: project.organization)).not_to be_valid
    end

    it "è invalido se l'ambiente è di un'altra org" do
      project = create(:project)
      other_env = create(:environment, organization: create(:organization))
      expect(build(:secret_variable, project:, environment: other_env, organization: project.organization)).not_to be_valid
    end
  end

  describe "integrità tenant" do
    it "è invalido se organization non combacia con quella del progetto" do
      project, env = project_with_environment
      variable = build(:secret_variable, project:, environment: env, organization: create(:organization))
      expect(variable).not_to be_valid
      expect(variable.errors[:organization_id]).to be_present
    end
  end

  describe "cifratura del valore (ActiveRecord::Encryption)" do
    it "il valore si ritrova in chiaro dopo reload" do
      variable = create(:secret_variable, value: "super-secret")
      expect(variable.reload.value).to eq("super-secret")
    end

    it "in DB la colonna value è ciphertext, non il plaintext" do
      variable = create(:secret_variable, value: "super-secret")
      raw = described_class.connection.select_value(
        described_class.sanitize_sql_array([ "SELECT value FROM secrets_variables WHERE id = ?", variable.id ])
      )
      expect(raw).not_to include("super-secret")
    end
  end

  describe "immutabilità dello scope (attr_readonly)" do
    it "vieta la riassegnazione di project_id dopo la creazione" do
      variable = create(:secret_variable)
      other = create(:project)
      expect { variable.update(project_id: other.id) }.to raise_error(ActiveRecord::ReadonlyAttributeError)
      expect(variable.reload.project_id).not_to eq(other.id)
    end
  end

  describe ".ordered" do
    it "ordina per nome" do
      project, env = project_with_environment
      z = create(:secret_variable, name: "ZED", project:, environment: env, organization: project.organization)
      a = create(:secret_variable, name: "ALPHA", project:, environment: env, organization: project.organization)
      expect(project.secret_variables.ordered.to_a).to eq([ a, z ])
    end
  end

  describe "capability secrets per-ambiente (enforcement, on: :create)" do
    # Progetto con env dichiarato; capability governata dal default dell'ambiente e/o dall'override join.
    def variable_for(env_traits: [], override: {})
      project = create(:project)
      env = create(:environment, *env_traits, organization: project.organization)
      create(:project_environment, project:, environment: env, **override)
      build(:secret_variable, project:, environment: env, organization: project.organization)
    end

    it "valido quando i secret sono abilitati di default sull'ambiente (override nil)" do
      expect(variable_for).to be_valid
    end

    it "invalido quando i secret sono disabilitati di default sull'ambiente (ereditato)" do
      variable = variable_for(env_traits: [ :secrets_off ])
      expect(variable).not_to be_valid
      expect(variable.errors).to be_added(:base, :secrets_disabled)
    end

    it "invalido quando un override del progetto forza i secret OFF (default ON)" do
      variable = variable_for(override: { secrets_enabled: false })
      expect(variable).not_to be_valid
      expect(variable.errors).to be_added(:base, :secrets_disabled)
    end

    it "valido quando un override del progetto forza i secret ON nonostante il default OFF" do
      expect(variable_for(env_traits: [ :secrets_off ], override: { secrets_enabled: true })).to be_valid
    end

    it "consente l'update di un secret esistente anche con i secret disabilitati dopo (on: :create)" do
      project = create(:project)
      env = create(:environment, organization: project.organization)
      join = create(:project_environment, project:, environment: env)
      variable = create(:secret_variable, project:, environment: env, organization: project.organization, value: "v1")
      join.update!(secrets_enabled: false)
      expect(variable.update(value: "v2")).to be(true)
      expect(variable.reload.value).to eq("v2")
    end
  end

  # Rotazione "morbida" dei secret (CYRA-138, Fase 4 pezzo A1): la scadenza è SOLO un avviso — il
  # segreto resta sempre leggibile (Secrets::Bundle invariato). rotated_at è responsabilità di
  # Secrets::Variables::Set (vedi spec/services/secrets/variables/set_spec.rb); qui si testa solo il
  # calcolo puro dato [rotation_interval_days, rotated_at].
  describe "#rotate_by" do
    it "è nil senza policy di rotazione (rotation_interval_days assente)" do
      variable = build(:secret_variable, rotation_interval_days: nil, rotated_at: Time.current)
      expect(variable.rotate_by).to be_nil
    end

    it "è nil senza rotated_at (variabile mai passata da Set, es. fixture diretta)" do
      variable = build(:secret_variable, rotation_interval_days: 30, rotated_at: nil)
      expect(variable.rotate_by).to be_nil
    end

    it "è rotated_at + rotation_interval_days giorni" do
      rotated_at = Time.zone.local(2026, 1, 1, 12, 0, 0)
      variable = build(:secret_variable, rotation_interval_days: 30, rotated_at:)
      expect(variable.rotate_by).to eq(rotated_at + 30.days)
    end
  end

  describe "#rotation_status" do
    it ":none senza alcuna policy di rotazione" do
      variable = build(:secret_variable, rotation_interval_days: nil, rotated_at: Time.current)
      expect(variable.rotation_status).to eq(:none)
    end

    it ":none con policy ma senza rotated_at" do
      variable = build(:secret_variable, rotation_interval_days: 30, rotated_at: nil)
      expect(variable.rotation_status).to eq(:none)
    end

    it ":ok quando rotate_by è ben oltre la soglia di preavviso" do
      travel_to Time.zone.local(2026, 1, 1, 12, 0, 0) do
        variable = build(:secret_variable, rotation_interval_days: 90, rotated_at: Time.current)
        expect(variable.rotation_status).to eq(:ok)
      end
    end

    it ":due_soon esattamente alla soglia di preavviso" do
      travel_to Time.zone.local(2026, 1, 1, 12, 0, 0) do
        variable = build(:secret_variable, rotation_interval_days: 14, rotated_at: Time.current)
        expect(variable.rotate_by).to eq(Time.current + Secrets::Variable::ROTATION_DUE_SOON_THRESHOLD)
        expect(variable.rotation_status).to eq(:due_soon)
      end
    end

    it ":due_soon appena DENTRO la soglia (un secondo prima del limite)" do
      travel_to Time.zone.local(2026, 1, 1, 12, 0, 0) do
        variable = build(:secret_variable, rotation_interval_days: 14, rotated_at: Time.current - 1.second)
        expect(variable.rotation_status).to eq(:due_soon)
      end
    end

    it ":ok appena FUORI la soglia (un secondo dopo il limite)" do
      travel_to Time.zone.local(2026, 1, 1, 12, 0, 0) do
        variable = build(:secret_variable, rotation_interval_days: 14, rotated_at: Time.current + 1.second)
        expect(variable.rotation_status).to eq(:ok)
      end
    end

    it ":due_soon quando rotate_by è esattamente ora (boundary con :overdue, non ancora scaduto)" do
      travel_to Time.zone.local(2026, 1, 1, 12, 0, 0) do
        variable = build(:secret_variable, rotation_interval_days: 1, rotated_at: Time.current - 1.day)
        expect(variable.rotate_by).to eq(Time.current)
        expect(variable.rotation_status).to eq(:due_soon)
      end
    end

    it ":overdue quando rotate_by è nel passato" do
      travel_to Time.zone.local(2026, 1, 1, 12, 0, 0) do
        variable = build(:secret_variable, rotation_interval_days: 1, rotated_at: Time.current - 1.day - 1.second)
        expect(variable.rotation_status).to eq(:overdue)
      end
    end
  end

  describe ".with_rotation_policy" do
    it "include solo le variabili con rotation_interval_days presente" do
      project, env = project_with_environment
      with_policy = create(:secret_variable, project:, environment: env, organization: project.organization,
                            name: "WITH_POLICY", rotation_interval_days: 30, rotated_at: Time.current)
      without_policy = create(:secret_variable, project:, environment: env, organization: project.organization,
                               name: "WITHOUT_POLICY", rotation_interval_days: nil)

      expect(described_class.with_rotation_policy).to include(with_policy)
      expect(described_class.with_rotation_policy).not_to include(without_policy)
    end
  end

  describe ".due_for_rotation" do
    it "include le variabili :due_soon e :overdue" do
      travel_to Time.zone.local(2026, 1, 1, 12, 0, 0) do
        project, env = project_with_environment
        due_soon = create(:secret_variable, project:, environment: env, organization: project.organization,
                           name: "DUE_SOON", rotation_interval_days: 14, rotated_at: Time.current)
        overdue = create(:secret_variable, project:, environment: env, organization: project.organization,
                          name: "OVERDUE", rotation_interval_days: 1, rotated_at: Time.current - 2.days)

        expect(described_class.due_for_rotation).to contain_exactly(due_soon, overdue)
      end
    end

    it "esclude le variabili :ok e :none" do
      travel_to Time.zone.local(2026, 1, 1, 12, 0, 0) do
        project, env = project_with_environment
        create(:secret_variable, project:, environment: env, organization: project.organization,
               name: "OK_VAR", rotation_interval_days: 90, rotated_at: Time.current)
        create(:secret_variable, project:, environment: env, organization: project.organization,
               name: "NONE_VAR", rotation_interval_days: nil)

        expect(described_class.due_for_rotation).to be_empty
      end
    end
  end

  describe "validazione di rotation_interval_days" do
    it "ammette nil (nessuna policy)" do
      expect(build(:secret_variable, rotation_interval_days: nil)).to be_valid
    end

    it "ammette un intero positivo" do
      expect(build(:secret_variable, rotation_interval_days: 30, rotated_at: Time.current)).to be_valid
    end

    it "rifiuta zero" do
      variable = build(:secret_variable, rotation_interval_days: 0)
      expect(variable).not_to be_valid
      expect(variable.errors[:rotation_interval_days]).to be_present
    end

    it "rifiuta un intero negativo" do
      variable = build(:secret_variable, rotation_interval_days: -5)
      expect(variable).not_to be_valid
      expect(variable.errors[:rotation_interval_days]).to be_present
    end
  end
end
