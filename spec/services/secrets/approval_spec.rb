# frozen_string_literal: true

require "rails_helper"

RSpec.describe Secrets::Approval, type: :service do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let(:environment) { create(:environment, organization:) }

  describe ".required?" do
    context "ambiente non dichiarato dal progetto (nessuna riga join)" do
      it "non è protetto anche con il master attivo" do
        project.update!(secret_approval_enabled: true)

        expect(described_class.required?(project:, environment:)).to be(false)
      end
    end

    context "ambiente dichiarato dal progetto" do
      # Matrice master (secret_approval_enabled) × capability risolta (approval_required): protetto
      # SOLO quando ENTRAMBI sono true. Le altre 3 combinazioni restano non protette.
      it "master OFF, capability OFF → non protetto" do
        project.update!(secret_approval_enabled: false)
        create(:project_environment, project:, environment:, approval_required: false)

        expect(described_class.required?(project:, environment:)).to be(false)
      end

      it "master ON, capability OFF → non protetto (manca la capability sull'ambiente)" do
        project.update!(secret_approval_enabled: true)
        create(:project_environment, project:, environment:, approval_required: false)

        expect(described_class.required?(project:, environment:)).to be(false)
      end

      it "master OFF, capability ON → non protetto (il progetto non ha attivato l'opt-in)" do
        project.update!(secret_approval_enabled: false)
        create(:project_environment, project:, environment:, approval_required: true)

        expect(described_class.required?(project:, environment:)).to be(false)
      end

      it "master ON, capability ON → protetto" do
        project.update!(secret_approval_enabled: true)
        create(:project_environment, project:, environment:, approval_required: true)

        expect(described_class.required?(project:, environment:)).to be(true)
      end

      it "master ON, capability ereditata ON dal default dell'ambiente (override nil)" do
        environment.update!(approval_required: true)
        project.update!(secret_approval_enabled: true)
        create(:project_environment, project:, environment:, approval_required: nil)

        expect(described_class.required?(project:, environment:)).to be(true)
      end

      it "master ON, override esplicito OFF vince sul default ON dell'ambiente" do
        environment.update!(approval_required: true)
        project.update!(secret_approval_enabled: true)
        create(:project_environment, project:, environment:, approval_required: false)

        expect(described_class.required?(project:, environment:)).to be(false)
      end
    end
  end
end
