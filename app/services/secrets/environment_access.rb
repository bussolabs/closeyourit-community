# frozen_string_literal: true

module Secrets
  # Confine ambienti sui secret di un progetto, per un account (CYRA-78). Unica fonte di verità: la
  # stessa risposta la danno il canale web (matrice, reveal, scritture) e il canale CLI, che prima
  # portavano la logica inline e divergevano — il web non filtrava niente.
  #
  # Precedenza, dalla più specifica alla più generale:
  #   1. override per-progetto  → Connections::AccountSecretAccess (allow-list non vuota su QUESTO progetto)
  #   2. allow-list org-wide    → Connections::Membership#secret_environment_codes
  #   3. nessuna restrizione    → tutti gli ambienti del progetto
  #
  # Non è un ApplicationService: è una policy interrogabile più volte sullo stesso attore/progetto
  # (memoizza le due letture), non un'azione con un esito.
  class EnvironmentAccess
    # Reports evaluate many projects at once; load both policy levels without per-row queries.
    def self.for_projects(account:, projects:)
      projects = projects.to_a
      return {} if projects.empty?

      overrides = Connections::AccountSecretAccess.where(account_id: account&.id, project_id: projects.map(&:id))
        .pluck(:project_id, :environment_codes).to_h
      memberships = Connections::Membership.where(account_id: account&.id, organization_id: projects.map(&:organization_id).uniq)
        .pluck(:organization_id, :secret_environment_codes).to_h

      projects.to_h do |project|
        codes = overrides[project.id].presence || memberships[project.organization_id] || []
        policy = new(account:, project:, restriction_codes: codes)
        [ project.id, policy ]
      end
    end

    def initialize(account:, project:, restriction_codes: nil)
      @account = account
      @project = project
      @restriction_codes = restriction_codes
    end

    # Vero quando esiste una allow-list attiva (a qualsiasi livello): serve ai rami che non possono
    # essere confinati a un solo ambiente — es. la sync GitHub, che spinge tutti gli slot mappati.
    def restricted? = restriction_codes.present?

    # Vero se l'account può toccare i secret dell'ambiente `code`. Il confronto è sui code
    # normalizzati: uno spazio o una maiuscola non aggirano il confine. Ambiente assente (nil) →
    # negato quando la restrizione è attiva (fail-closed, come per i file-segreto senza ambiente).
    def allowed?(code)
      return true unless restricted?

      restriction_codes.include?(normalize(code))
    end

    # I code degli ambienti DEL PROGETTO su cui l'account può operare. Senza restrizione sono tutti;
    # con restrizione è l'intersezione — un code in allow-list ma non dichiarato dal progetto non
    # compare, così chi legge la lista vede solo ambienti che esistono davvero qui.
    def allowed_codes
      return project_codes unless restricted?

      project_codes & restriction_codes
    end

    # La allow-list VIGENTE così com'è scritta, senza intersecarla col progetto (vuota = nessun
    # limite). Serve dove il confine si applica a righe che possono vivere fuori dagli ambienti
    # dichiarati da questo progetto — i file-segreto delegati da un altro progetto dell'org.
    # Per decidere su un ambiente si usa sempre #allowed?, non questa lista.
    def restriction_codes
      @restriction_codes ||= per_project_codes.presence || organization_wide_codes
    end

    private

    def normalize(code) = code.to_s.strip.downcase

    def project_codes
      @project_codes ||= @project.environments.pluck(:code)
    end

    # L'override per-progetto vince, ma solo se dichiara almeno un ambiente (una riga vuota non è un
    # divieto totale — vedi Connections::AccountSecretAccess).
    def per_project_codes
      return [] if @account.nil?

      Connections::AccountSecretAccess
        .where(account_id: @account.id, project_id: @project.id)
        .pick(:environment_codes) || []
    end

    def organization_wide_codes
      membership&.secret_environment_codes || []
    end

    # La membership si cerca sull'org DEL PROGETTO (non su Current): la policy risponde uguale dentro
    # una richiesta web, in un job e in console.
    def membership
      return @membership if defined?(@membership)

      @membership = @account && Connections::Membership.find_by(account_id: @account.id,
                                                                organization_id: @project.organization_id)
    end
  end
end
