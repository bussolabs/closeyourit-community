# frozen_string_literal: true

require "rails_helper"

RSpec.describe Connections::EnvironmentHost, type: :model do
  it "collega un host a un environment dichiarato di un progetto uptime-capable" do
    expect(build(:environment_host)).to be_valid
  end

  it "rifiuta la stessa tripla [progetto, environment, host] due volte" do
    link = create(:environment_host)
    dup = build(:environment_host, project: link.project, environment: link.environment, host: link.host)
    expect(dup).not_to be_valid
    # message: :host_already_linked personalizza il testo, il detail key resta :taken.
    expect(dup.errors.of_kind?(:host_id, :taken)).to be(true)
    expect(dup.errors[:host_id].to_sentence).to eq(I18n.t("errors.messages.host_already_linked"))
  end

  it "accetta lo stesso host su un environment DIVERSO dello stesso progetto (N per env)" do
    link = create(:environment_host)
    other_env = create(:environment, organization: link.project.organization)
    link.project.environments << other_env
    expect(build(:environment_host, project: link.project, environment: other_env, host: link.host)).to be_valid
  end

  it "accetta più host sullo stesso environment" do
    link = create(:environment_host)
    other_host = create(:server_host, organization: link.project.organization)
    expect(build(:environment_host, project: link.project, environment: link.environment, host: other_host)).to be_valid
  end

  it "rifiuta un environment non dichiarato dal progetto" do
    project = create(:project)
    undeclared = create(:environment, organization: project.organization)
    link = build(:environment_host, project:, environment: undeclared)
    expect(link).not_to be_valid
    expect(link.errors.details[:environment]).to include(a_hash_including(error: :invalid))
  end

  it "rifiuta il link su un progetto senza piattaforma uptime-capable" do
    link = build(:environment_host)
    link.project.project_platforms.uptime_capable.destroy_all
    expect(link).not_to be_valid
    expect(link.errors.details[:project]).to include(a_hash_including(error: :uptime_unsupported))
  end

  it "rifiuta un host di un'altra org (integrità tenant)" do
    foreign_host = create(:server_host, organization: create(:organization))
    link = build(:environment_host, host: foreign_host)
    expect(link).not_to be_valid
    expect(link.errors.details[:host]).to include(a_hash_including(error: :cross_tenant))
  end

  it "rifiuta il link di un host revocato" do
    link = build(:environment_host)
    link.host = create(:server_host, :revoked, organization: link.project.organization)
    expect(link).not_to be_valid
    expect(link.errors.details[:host]).to include(a_hash_including(error: :revoked_host))
  end

  it "resta valido se l'host viene revocato DOPO il collegamento" do
    link = create(:environment_host)
    link.host.update!(revoked_at: Time.current)
    expect(link.reload).to be_valid
  end

  it "guard: non solleva quando project/environment/host sono assenti" do
    expect { described_class.new.valid? }.not_to raise_error
  end

  describe "capability servers per-ambiente (enforcement, on: :create)" do
    # Progetto uptime-capable (garantito dall'after(:build) della factory) con env dichiarato;
    # capability governata dal default dell'ambiente e/o dall'override sulla riga join.
    def link_for(env_traits: [], override: {})
      project = create(:project)
      env = create(:environment, *env_traits, organization: project.organization)
      create(:project_environment, project:, environment: env, **override)
      host = create(:server_host, organization: project.organization)
      build(:environment_host, project:, environment: env, host:)
    end

    it "valido quando i server sono abilitati di default sull'ambiente (override nil)" do
      expect(link_for).to be_valid
    end

    it "invalido quando i server sono disabilitati di default sull'ambiente (ereditato)" do
      link = link_for(env_traits: [ :servers_off ])
      expect(link).not_to be_valid
      expect(link.errors).to be_added(:base, :servers_disabled)
    end

    it "invalido quando un override del progetto forza i server OFF (default ON)" do
      link = link_for(override: { servers_enabled: false })
      expect(link).not_to be_valid
      expect(link.errors).to be_added(:base, :servers_disabled)
    end

    it "valido quando un override del progetto forza i server ON nonostante il default OFF" do
      expect(link_for(env_traits: [ :servers_off ], override: { servers_enabled: true })).to be_valid
    end

    it "non invalida un link esistente quando i server vengono disabilitati dopo (on: :create)" do
      project = create(:project)
      env = create(:environment, organization: project.organization)
      join = create(:project_environment, project:, environment: env)
      host = create(:server_host, organization: project.organization)
      link = build(:environment_host, project:, environment: env, host:)
      link.save!
      join.update!(servers_enabled: false)
      expect(link.reload).to be_valid
    end
  end

  describe ".declared" do
    it "esclude il link il cui environment è stato s-dichiarato dal progetto" do
      link = create(:environment_host)
      expect(described_class.declared).to include(link)

      Connections::ProjectEnvironment.where(project: link.project, environment: link.environment).delete_all
      expect(described_class.declared).not_to include(link)
    end
  end
end
